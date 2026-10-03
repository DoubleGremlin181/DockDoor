import AppKit

/// A Space move that crosses displays shifts the window in the window server
/// only. AppKit apps notice and put the window back where it last sat on that
/// display; others (Chrome) never do and keep acting on the frame they had on
/// the old display, so a zoom or a third-party "fill" sends the window back
/// there. Setting the frame through Accessibility makes the app adopt it.
///
/// Known limit: AppKit remembers the frame a window had when it last changed
/// screens, and `zoom:` on a window sitting at its screen's standard frame
/// un-zooms to that remembered frame. A window that was zoomed when moved
/// therefore goes back to the old display on the next Zoom in apps that never
/// re-place it themselves (Chrome). No Accessibility set clears that record;
/// `_zoomFill:` (Window > Fill) is unaffected.
enum WindowFrameSync {
    /// Long enough for an app that follows the move on its own to have done so
    private static let grace: UInt64 = 350_000_000
    /// An app that is busy (just woken) answers late; spread the attempts out
    private static let retryDelays: [UInt64] = [0, 400_000_000, 1_200_000_000, 3_000_000_000]
    /// CGWindowList trails an Accessibility set by up to ~120 ms
    private static let serverCatchUp: UInt64 = 60_000_000
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
        var displayID: CGDirectDisplayID? = nil
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
    /// new one is fitted in; nil keeps the shift. `target` is the display the
    /// move was aimed at; without it the display holding the shifted frame's
    /// origin decides (the window server anchors an oversize window there,
    /// so most of it can hang over the neighbour), then its largest overlap.
    static func arrival(before: CGRect, server: CGRect, areas: [DisplayArea], target: DisplayArea? = nil) -> CGRect? {
        func area(of frame: CGRect) -> DisplayArea? {
            areas.max { a, b in overlap(a.bounds, frame) < overlap(b.bounds, frame) }.flatMap { overlap($0.bounds, frame) > 0 ? $0 : nil }
        }
        let landed = target ?? areas.first { $0.bounds.contains(server.origin) } ?? area(of: server)
        guard let source = area(of: before), let target = landed, source != target else { return nil }
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
            let bounds = CGDisplayBounds(displayID)
            let usable = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            return DisplayArea(bounds: bounds, usable: usable.isEmpty ? bounds : usable, displayID: displayID)
        }
    }

    @MainActor
    private static func area(ofSpace spaceID: CGSSpaceID, in areas: [DisplayArea]) -> DisplayArea? {
        let topology = SpaceTopology.shared
        guard let identifier = topology.spaces(maxAge: 1).displayIdentifier(forSpace: spaceID),
              let displayID = topology.displays().displayID(forCGSIdentifier: identifier)
        else { return nil }
        return areas.first { $0.displayID == displayID }
    }

    private static func display(of frame: CGRect, in displays: [CGRect]) -> CGRect? {
        displays.first { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Following a move

    /// One live follow per window: a later move supersedes an earlier one,
    /// whose planned frame would otherwise be asserted on the wrong display.
    private actor Registry {
        private var generations: [CGWindowID: UInt64] = [:]
        private var counter: UInt64 = 0

        func begin(_ windowID: CGWindowID) -> UInt64 {
            counter += 1
            generations[windowID] = counter
            return counter
        }

        func isCurrent(_ windowID: CGWindowID, _ generation: UInt64) -> Bool {
            generations[windowID] == generation
        }

        func end(_ windowID: CGWindowID, _ generation: UInt64) {
            if generations[windowID] == generation { generations[windowID] = nil }
        }
    }

    private static let registry = Registry()

    /// Brings the app's idea of a window's frame in line with the window
    /// server after a Space move across displays. `planned` (CG global) is
    /// where the caller wants the window; without one, `before` (its frame
    /// ahead of the move) decides via `arrival`. `target` is the Space the
    /// window was moved to: it names the destination display, and a window
    /// no longer on it (a later move, a display that left) is left alone.
    /// Returns whether app and window server agree in the end; a window that
    /// does not is retried by the watcher.
    @discardableResult
    static func follow(_ windowID: CGWindowID, planned: CGRect? = nil, before: CGRect? = nil, target: CGSSpaceID? = nil) async -> Bool {
        let generation = await registry.begin(windowID)
        let outcome = await run(windowID, planned: planned, before: before, target: target, generation: generation)
        await registry.end(windowID, generation)
        if outcome == .unsettled {
            await MainActor.run { Watcher.shared.noteUnsettled(windowID) }
        }
        return outcome == .settled
    }

    private enum Outcome {
        case settled
        case unsettled
        /// Superseded, gone, or no longer on the target Space: not ours to fix
        case abandoned
    }

    private static func run(_ windowID: CGWindowID, planned: CGRect?, before: CGRect?, target: CGSSpaceID?, generation: UInt64) async -> Outcome {
        try? await Task.sleep(nanoseconds: grace)
        guard await registry.isCurrent(windowID, generation) else { return .abandoned }
        // NSScreen-backed tables: read them on the main actor, once.
        let (areas, targetArea) = await MainActor.run { () -> ([DisplayArea], DisplayArea?) in
            let areas = displayAreas()
            return (areas, target.flatMap { area(ofSpace: $0, in: areas) })
        }
        let displays = areas.map(\.bounds)
        var planned = planned
        if let frame = planned, let targetArea, display(of: frame, in: displays) != targetArea.bounds {
            // A plan for a display the window is not going to would carry it there.
            DebugLogger.log("WindowFrameSync", details: "window \(windowID): planned frame \(frame) is not on the display of Space \(target.map(String.init) ?? "?"); ignoring it")
            planned = nil
        }
        if planned == nil, let before, let server = serverFrame(of: windowID) {
            planned = arrival(before: before, server: server, areas: areas, target: targetArea)
        }
        var element: AXUIElement?
        for delay in retryDelays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard await registry.isCurrent(windowID, generation) else {
                DebugLogger.log("WindowFrameSync", details: "window \(windowID): a later move took over")
                return .abandoned
            }
            if let target {
                let spaces = windowID.cgsSpaces()
                if !spaces.isEmpty, !spaces.contains(target) {
                    DebugLogger.log("WindowFrameSync", details: "window \(windowID) is no longer on Space \(target); leaving it")
                    return .abandoned
                }
            }
            guard let server = serverFrame(of: windowID) else { return .abandoned }
            if element == nil {
                element = await axElement(for: windowID)
            }
            // No answer yet: the app is busy, and a set would go unheard too.
            guard let element, let app = await appFrame(of: element) else { continue }
            guard case let .assert(frame) = verdict(app: app, server: server, planned: planned) else { return .settled }

            DebugLogger.log("WindowFrameSync", details: "window \(windowID): app has \(app), window server \(server); setting \(frame)")
            await setFrame(of: element, to: frame)
            if await confirmSettled(windowID, element: element, target: frame, displays: displays) {
                return .settled
            }
            // Repeating the window server's own frame to an app that reports
            // its frame with an offset would walk the window.
            if planned == nil { break }
        }
        DebugLogger.log("WindowFrameSync", details: "window \(windowID) still disagrees with the window server about its frame")
        return .unsettled
    }

    private static func confirmSettled(_ windowID: CGWindowID, element: AXUIElement, target: CGRect, displays: [CGRect]) async -> Bool {
        for attempt in 0 ..< 5 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: serverCatchUp) }
            guard let server = serverFrame(of: windowID), let app = await appFrame(of: element) else { return false }
            if settled(app: app, server: server, target: target, displays: displays) { return true }
        }
        return false
    }

    // MARK: - Repairing windows already astray

    /// Repairs cached windows whose app and window server disagree about the
    /// display: moved by a version without `follow`, or whose app never
    /// answered it. The frame is fitted like an arrival, so a window that
    /// filled the display its app believes in fills the one it is on.
    static func heal() async {
        let areas = await MainActor.run { displayAreas() }
        guard areas.count > 1 else { return }
        for info in WindowUtil.cachedWindowsUnfiltered() where !info.isWindowlessApp {
            guard !AXResponsiveness.isUnresponsive(info.app.processIdentifier) else { continue }
            await repair(info.id, element: info.axElement, areas: areas)
        }
    }

    /// Returns whether the window needs no further attention.
    @discardableResult
    private static func repair(_ windowID: CGWindowID, element: AXUIElement, areas: [DisplayArea]) async -> Bool {
        guard let server = serverFrame(of: windowID) else { return true }
        guard let app = await appFrame(of: element) else { return false }
        guard strayed(app: app, server: server, displays: areas.map(\.bounds)) else { return true }
        let frame = arrival(before: app, server: server, areas: areas) ?? server
        DebugLogger.log("WindowFrameSync", details: "window \(windowID) astray: app has \(app), window server \(server); setting \(frame)")
        await setFrame(of: element, to: frame)
        return true
    }

    /// Runs `heal` at launch and once display changes settle, and retries
    /// windows whose follow gave up once Spaces change (their app may have
    /// thawed by then). Independent of Display Layout Memory: every Space
    /// move across displays needs it.
    @MainActor
    final class Watcher {
        static let shared = Watcher()
        private static let launchDelay: UInt64 = 3_000_000_000
        private static let settle: UInt64 = 5_000_000_000
        private static let spaceChangeDelay: UInt64 = 1_000_000_000

        private var subscription: UUID?
        private var unsettled: Set<CGWindowID> = []
        private var healTask: Task<Void, Never>?
        private var retryTask: Task<Void, Never>?

        private init() {}

        func start() {
            guard subscription == nil else { return }
            subscription = SpaceTopology.shared.subscribe { [weak self] event in self?.handle(event) }
            scheduleHeal(after: Self.launchDelay)
        }

        func noteUnsettled(_ windowID: CGWindowID) {
            unsettled.insert(windowID)
        }

        private func handle(_ event: SpaceTopology.Event) {
            switch event {
            case .displaysChanged, .screenParametersChanged, .didWake:
                scheduleHeal(after: Self.settle)
            case .activeSpaceChanged:
                guard !unsettled.isEmpty, retryTask == nil else { return }
                retryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: Self.spaceChangeDelay)
                    await self?.retryUnsettled()
                    self?.retryTask = nil
                }
            case .displaysWillChange, .willSleep:
                break
            }
        }

        private func scheduleHeal(after delay: UInt64) {
            healTask?.cancel()
            healTask = Task {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await WindowFrameSync.heal()
            }
        }

        private func retryUnsettled() async {
            let areas = displayAreas()
            for windowID in unsettled {
                guard let element = await axElement(for: windowID) else {
                    unsettled.remove(windowID)
                    continue
                }
                if await repair(windowID, element: element, areas: areas) {
                    unsettled.remove(windowID)
                }
            }
        }
    }

    // MARK: - Window server and Accessibility

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
