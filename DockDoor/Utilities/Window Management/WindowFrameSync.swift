import AppKit

/// A Space move that crosses displays shifts the window in the window server
/// only. AppKit apps notice and put the window back where it last sat on that
/// display; others (Chrome) never do and keep acting on the frame they had on
/// the old display, so a zoom or a third-party "fill" sends the window back
/// there. Setting the frame through Accessibility makes the app adopt it.
enum WindowFrameSync {
    /// Long enough for an app that follows the move on its own to have done so
    private static let grace: UInt64 = 350_000_000
    /// An app that is busy (just woken) answers late; spread the attempts out
    private static let retryDelays: [UInt64] = [0, 400_000_000, 1_200_000_000, 3_000_000_000]
    private static let tolerance: CGFloat = 2

    enum Verdict: Equatable {
        case leave
        case assert(CGRect)
    }

    struct DisplayArea: Equatable {
        /// CG global coordinates
        let bounds: CGRect
        /// Minus menu bar and Dock
        let usable: CGRect
    }

    /// Without a planned frame an app that followed the move is left alone:
    /// it restored its own remembered placement.
    static func verdict(app: CGRect, server: CGRect, planned: CGRect?) -> Verdict {
        let agrees = matches(app, server)
        guard let planned else { return agrees ? .leave : .assert(server) }
        return agrees && matches(server, planned) ? .leave : .assert(planned)
    }

    /// An app can clamp a frame it is given onto the display it thinks the
    /// window is on; agreeing there is not success.
    static func settled(app: CGRect, server: CGRect, target: CGRect, displays: [CGRect]) -> Bool {
        matches(app, server) && display(of: server, in: displays) == display(of: target, in: displays)
    }

    /// The app places its window on one display and the window server on
    /// another: what a Space move across displays leaves behind when nothing
    /// told the app. A mere offset on the same display is not it.
    static func strayed(app: CGRect, server: CGRect, displays: [CGRect]) -> Bool {
        guard let appDisplay = display(of: app, in: displays), let serverDisplay = display(of: server, in: displays) else { return false }
        return appDisplay != serverDisplay
    }

    /// Where a window that changed display should end up, given its frame
    /// before the move and where the window server shifted it (same size).
    /// One that filled its old display fills the new one; one too big for the
    /// new one is fitted in; nil keeps the shift.
    static func arrival(before: CGRect, server: CGRect, areas: [DisplayArea]) -> CGRect? {
        func area(of frame: CGRect) -> DisplayArea? {
            areas.max { a, b in overlap(a.bounds, frame) < overlap(b.bounds, frame) }.flatMap { overlap($0.bounds, frame) > 0 ? $0 : nil }
        }
        guard let source = area(of: before), let target = area(of: server), source != target else { return nil }
        if DisplayLayoutReconciler.fills(before, source.usable) { return target.usable }
        if target.usable.insetBy(dx: -tolerance, dy: -tolerance).contains(server) { return nil }
        var fitted = server
        fitted.size.width = min(server.width, target.usable.width)
        fitted.size.height = min(server.height, target.usable.height)
        fitted.origin.x = min(max(server.minX, target.usable.minX), target.usable.maxX - fitted.width)
        fitted.origin.y = min(max(server.minY, target.usable.minY), target.usable.maxY - fitted.height)
        return fitted
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    @MainActor
    private static func displayAreas() -> [DisplayArea] {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            let visible = screen.visibleFrame
            return DisplayArea(
                bounds: CGDisplayBounds(displayID),
                usable: CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            )
        }
    }

    private static func display(of frame: CGRect, in displays: [CGRect]) -> CGRect? {
        displays.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// Brings the app's idea of a window's frame in line with the window
    /// server after a Space move across displays. `planned` (CG global) is
    /// where the caller wants the window; without one, `before` (its frame
    /// ahead of the move) decides via `arrival`. Returns whether app and
    /// window server agree in the end.
    @discardableResult
    static func follow(_ windowID: CGWindowID, planned: CGRect? = nil, before: CGRect? = nil) async -> Bool {
        try? await Task.sleep(nanoseconds: grace)
        var planned = planned
        if planned == nil, let before, let server = serverFrame(of: windowID) {
            planned = await arrival(before: before, server: server, areas: MainActor.run { displayAreas() })
        }
        var element: AXUIElement?
        for delay in retryDelays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let server = serverFrame(of: windowID) else { return false }
            if element == nil {
                element = await axElement(for: windowID)
            }
            // No answer yet: the app is busy, and a set would go unheard too.
            guard let element, let app = await appFrame(of: element) else { continue }
            guard case let .assert(frame) = verdict(app: app, server: server, planned: planned) else { return true }

            DebugLogger.log("WindowFrameSync", details: "window \(windowID): app has \(app), window server \(server); setting \(frame)")
            await setFrame(of: element, to: frame)
            let displays = SpaceTopology.shared.displays().probes.map(\.bounds)
            if let server = serverFrame(of: windowID), let app = await appFrame(of: element),
               settled(app: app, server: server, target: frame, displays: displays)
            {
                return true
            }
            // Repeating the window server's own frame to an app that reports
            // its frame with an offset would walk the window.
            if planned == nil { break }
        }
        DebugLogger.log("WindowFrameSync", details: "window \(windowID) still disagrees with the window server about its frame")
        return false
    }

    /// Repairs windows that are already astray: moved by a version without
    /// `follow`, or whose app never answered it.
    static func heal() async {
        let displays = SpaceTopology.shared.displays().probes.map(\.bounds)
        guard displays.count > 1 else { return }
        for info in WindowUtil.cachedWindowsUnfiltered() where !info.isWindowlessApp {
            guard !AXResponsiveness.isUnresponsive(info.app.processIdentifier),
                  let server = serverFrame(of: info.id),
                  let app = await appFrame(of: info.axElement),
                  strayed(app: app, server: server, displays: displays)
            else { continue }
            DebugLogger.log("WindowFrameSync", details: "window \(info.id) astray: app has \(app), window server \(server); setting the latter")
            await setFrame(of: info.axElement, to: server)
        }
    }

    /// DockDoor's cache, else the app's window list, else a brute-force scan
    /// (windows on other Spaces are not listed).
    private static func axElement(for windowID: CGWindowID) async -> AXUIElement? {
        if let info = WindowUtil.cachedWindowsUnfiltered().first(where: { $0.id == windowID }) {
            return info.axElement
        }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: AnyObject]],
              let pid = (list.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> AXUIElement? in
            let app = AXUIElementCreateApplication(pid_t(pid))
            if let listed = (try? app.windows())?.first(where: { (try? $0.cgWindowId()) == windowID }) {
                return listed
            }
            return AXUIElement.windowsByBruteForce(pid_t(pid)).first { (try? $0.cgWindowId()) == windowID }
        }.value
    }

    static func serverFrame(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: AnyObject]] else { return nil }
        return CGRect(cgWindowBounds: list.first?[kCGWindowBounds as String])
    }

    // Off the main actor: an unresponsive app holds each call for the AX timeout.

    private static func appFrame(of element: AXUIElement) async -> CGRect? {
        await Task.detached(priority: .userInitiated) { () -> CGRect? in
            guard let position = try? element.position(), let size = try? element.size() else { return nil }
            return CGRect(origin: position, size: size)
        }.value
    }

    private static func setFrame(of element: AXUIElement, to frame: CGRect) async {
        guard let position = AXValue.from(point: frame.origin), let size = AXValue.from(size: frame.size) else { return }
        // Position twice: apps clamp the first move to the old display's
        // bounds until the size fits, then accept the final position.
        await Task.detached(priority: .userInitiated) {
            try? element.setAttribute(kAXPositionAttribute, position)
            try? element.setAttribute(kAXSizeAttribute, size)
            try? element.setAttribute(kAXPositionAttribute, position)
        }.value
    }
}
