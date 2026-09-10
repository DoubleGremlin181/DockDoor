import AppKit
import ApplicationServices
import Defaults

final class SpaceSwitchingCoordinator {
    private var panel: SpaceSwitcherPanelCoordinator?
    private var state: SpaceSwitcherState?
    /// Fired whenever a session ends (or an activation no-ops), so the owning
    /// KeybindHelper can clear its tap-thread session flag on every exit path,
    /// including card clicks that never route back through the event tap.
    var onSessionEnd: (() -> Void)?
    /// Fired on the main thread once a session's state exists, so the owning
    /// KeybindHelper's tap-thread flag is re-asserted even when a previous
    /// session's end callback landed after the new chord was seen.
    var onSessionBegin: (() -> Void)?

    private var topologySubscription: UUID?
    private var restoreObserver: NSObjectProtocol?

    init() {
        // Learning from normal space usage is shared with display layout
        // memory; whichever feature starts first turns it on.
        // Learning feeds the Space Switcher's previews and display layout
        // memory; neither needs it while the feature is off.
        Task { @MainActor in
            if Defaults[.enableSpaceSwitcher] {
                SpaceSwitcherEngine.startLearning()
            }
            for await enabled in Defaults.updates(.enableSpaceSwitcher) where enabled {
                SpaceSwitcherEngine.startLearning()
            }
        }

        topologySubscription = SpaceTopology.shared.subscribe { [weak self] event in
            Task { @MainActor [weak self] in
                switch event {
                case .activeSpaceChanged:
                    // Keep an open session's current-space markers fresh if
                    // the user switches natively (trackpad swipe, other tools).
                    self?.handleActiveSpaceChanged()
                case .displaysChanged, .screenParametersChanged:
                    // Display added/removed or resolution changed: the
                    // session's rows and the panel's screen are stale.
                    self?.handleScreenParametersChanged()
                case .displaysWillChange, .willSleep, .didWake:
                    break
                }
            }
        }

        // Display layout memory is about to move windows between spaces: an
        // open session's buckets would be wrong.
        restoreObserver = NotificationCenter.default.addObserver(
            forName: DisplayLayoutMemory.restoreWillBegin,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, isSessionActive else { return }
                DebugLogger.log("SpaceSwitcher", details: "display layout restore starting; cancelling session")
                cancel()
            }
        }
    }

    @MainActor
    private func handleScreenParametersChanged() {
        guard isSessionActive else { return }
        DebugLogger.log("SpaceSwitcher", details: "screen parameters changed; cancelling session")
        cancel()
    }

    /// Refresh the open session's current-space markers (no-op with no session).
    @MainActor
    private func handleActiveSpaceChanged() {
        guard let state else { return }
        // The table was just invalidated by the event; one cheap read.
        state.model = SpaceSwitcherEngine.Model(
            displays: WindowSpaces.displaySpacesSnapshot(order: Defaults[.spaceSwitcherDisplayOrder], maxAge: 0.5),
            windowsBySpace: state.model.windowsBySpace
        )
    }

    @MainActor
    var isSessionActive: Bool {
        state != nil
    }

    private let tapPanelFrameLock = NSLock()
    private var currentTapPanelFrame: CGRect?

    /// The visible panel's frame in Quartz (top-left origin) coordinates, for
    /// the event tap thread's click-outside test. Published from the main
    /// thread when the panel shows and cleared when the session ends, so the
    /// tap never touches the NSPanel itself (the tap runs on its own thread).
    var tapPanelFrame: CGRect? {
        tapPanelFrameLock.lock()
        defer { tapPanelFrameLock.unlock() }
        return currentTapPanelFrame
    }

    @MainActor
    private func publishTapPanelFrame() {
        var frame: CGRect?
        if let panel, panel.isVisible, let primaryMaxY = NSScreen.screens.first?.frame.maxY {
            frame = panel.frame.flippedToQuartz(primaryScreenMaxY: primaryMaxY)
        }
        tapPanelFrameLock.lock()
        currentTapPanelFrame = frame
        tapPanelFrameLock.unlock()
    }

    /// Thumbnails being captured ahead of a session — started when the
    /// chord's modifier goes down, so by the time the trigger key arrives
    /// most pictures are already fresh. Keeps feeding the open panel. Holds
    /// up to 24 downsampled tiles (a few tens of MB worst case) for a minute.
    @MainActor
    private final class PreviewPrewarm {
        let model: SpaceSwitcherEngine.Model
        let order: [SpaceSwitcherEngine.SpaceWindow]
        let startedAt = Date()
        /// Every capture, uniformly downsampled — the next open seeds from these
        var images: [CGWindowID: CGImage] = [:]
        var visited = 0
        var isComplete = false
        var task: Task<Void, Never>?

        init(model: SpaceSwitcherEngine.Model, order: [SpaceSwitcherEngine.SpaceWindow]) {
            self.model = model
            self.order = order
        }
    }

    private var prewarm: PreviewPrewarm?
    /// A finished prewarm is kept and reused for this long, so a modifier
    /// that is also used for ordinary chords costs at most one model build
    /// and one capture pass per minute.
    private static let prewarmCacheLifetime: TimeInterval = 60
    /// A cached prewarm older than this still opens the panel instantly, but
    /// a fresh pass then runs behind it and swaps only tiles that changed.
    private static let prewarmStaleAge: TimeInterval = 5
    /// A prewarm's window buckets older than this are rebuilt at activation:
    /// windows may have come and gone while the modifier was held.
    private static let prewarmModelLifetime: TimeInterval = 2

    /// The trigger key arrived and the panel is waiting for previews.
    private var activationPending = false
    /// Commit as soon as the session exists instead of showing the panel:
    /// the modifier came up during the wait (quick tap) or Return was pressed.
    private var commitOnActivation = false
    /// Escape or a click outside arrived during the wait: never show.
    private var activationCancelled = false
    /// Trigger presses that arrived during the wait, folded into the session.
    private var pendingCycles = 0

    /// The chord's modifier went down: build the model and start capturing
    /// thumbnails in the background, most useful first — unless a pass from
    /// the last minute is already cached. Once started, a pass runs to
    /// completion; it is never thrown away for a chord that turns out to be
    /// something else, so the cost stays bounded.
    @MainActor
    func prewarmPreviews(force: Bool = false, model: SpaceSwitcherEngine.Model? = nil) {
        guard Defaults[.enableSpaceSwitcher] else { return }
        if !force, let prewarm, Date().timeIntervalSince(prewarm.startedAt) < Self.prewarmCacheLifetime { return }
        prewarm?.task?.cancel()

        let model = model ?? SpaceSwitcherEngine.buildModel()
        let order = Self.thumbnailCaptureOrder(for: model)
        let prewarm = PreviewPrewarm(model: model, order: order)
        self.prewarm = prewarm
        DebugLogger.log("SpaceSwitcher", details: "prewarm started for \(order.count) windows")
        guard WindowUtil.shouldCaptureWindowImages(), !order.isEmpty else {
            prewarm.isComplete = true
            return
        }
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let cap = max(800, Defaults[.spaceSwitcherCardWidth] * scale)
        prewarm.task = Task.detached(priority: .userInitiated) { [weak self, weak prewarm] in
            for window in order {
                guard !Task.isCancelled else { return }
                let fresh = Self.captureThumbnail(window, cap: cap)
                // Compared here, off the main actor: two CG draws per window.
                let changed = fresh.map { fresh in window.image.map { Self.thumbnailsDiffer($0, fresh) } ?? true } ?? false
                await MainActor.run { [weak self, weak prewarm] in
                    guard let self, let prewarm, self.prewarm === prewarm else { return }
                    prewarm.visited += 1
                    guard let fresh else { return }
                    // Every capture feeds the next open; only a visible change
                    // is swapped into a panel that is already showing.
                    prewarm.images[window.id] = fresh
                    if changed, let state {
                        state.model = state.model.replacingImages([window.id: fresh])
                    }
                }
            }
            await MainActor.run { [weak prewarm] in prewarm?.isComplete = true }
        }
    }

    /// The chord's modifier came up with no session open yet. A cached
    /// prewarm stays for the next press; a pending activation becomes a
    /// quick tap (unless the switcher stays open on release).
    @MainActor
    func modifierReleasedBeforeSession() {
        if activationPending, !Defaults[.spaceSwitcherStayOpenOnRelease] {
            commitOnActivation = true
        }
    }

    @MainActor
    func handleActivation(isShiftPressed: Bool) async {
        if let state {
            if isShiftPressed {
                state.cycleBackward()
            } else {
                state.cycleForward()
            }
            return
        }
        if activationPending {
            // A second trigger press while the first is still waiting for
            // previews: fold it into that session rather than racing it.
            pendingCycles += isShiftPressed ? -1 : 1
            return
        }
        // Unstructured on purpose: the caller runs in KeybindHelper's
        // held-key task, which every keyDown and a Shift release cancel; a
        // cancelled Task.sleep returns at once and would spin the wait.
        await Task { @MainActor [weak self] in
            await self?.startSession(isShiftPressed: isShiftPressed)
        }.value
    }

    @MainActor
    private func startSession(isShiftPressed: Bool) async {
        activationPending = true
        activationCancelled = false
        pendingCycles = 0
        defer {
            activationPending = false
            commitOnActivation = false
            activationCancelled = false
            pendingCycles = 0
        }

        // Fresh previews before the panel shows, like the dock: wait for a
        // prewarm in progress up to the configured delay. Held for a moment
        // first, or pressed within a minute of the last one, it is usually
        // done already; pressed as a quick chord, it just started.
        if prewarm == nil {
            prewarmPreviews()
        }
        if let prewarm, !prewarm.isComplete {
            let deadline = Date().addingTimeInterval(Defaults[.spaceSwitcherPreviewDelay])
            while !prewarm.isComplete, !commitOnActivation, !activationCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }
        guard let prewarm, !activationCancelled else {
            onSessionEnd?()
            return
        }

        // Window buckets from the prewarm when recent; the current-space
        // markers always fresh (the user may have switched natively since).
        let prewarmAge = Date().timeIntervalSince(prewarm.startedAt)
        var model = prewarmAge > Self.prewarmModelLifetime
            ? SpaceSwitcherEngine.buildModel()
            : SpaceSwitcherEngine.Model(
                displays: WindowSpaces.displaySpacesSnapshot(order: Defaults[.spaceSwitcherDisplayOrder]),
                windowsBySpace: prewarm.model.windowsBySpace
            )
        model = model.replacingImages(prewarm.images)
        DebugLogger.log("SpaceSwitcher", details: "activation: prewarm \(Int(prewarmAge * 1000)) ms old, \(prewarm.visited)/\(prewarm.order.count) captured")
        guard model.allSpaces.count > 1 else {
            onSessionEnd?()
            return
        }

        let state = SpaceSwitcherState(model: model)
        state.onCommit = { [weak self] space in
            Task { @MainActor [weak self] in self?.commit(space) }
        }
        state.onMoveWindowDrop = { [weak self] windowID, space in
            Task { @MainActor [weak self] in self?.moveWindow(windowID, to: space) }
        }
        self.state = state
        onSessionBegin?()

        // First press advances off the current space, mirroring cmd+tab
        if Defaults[.spaceSwitcherStartOnSecondSpace] {
            state.advance(backward: isShiftPressed)
        }
        if pendingCycles != 0 {
            state.cycle(by: pendingCycles)
        }

        if commitOnActivation {
            // Quick tap (or Return): the modifier was already up before
            // previews were ready, so switch without showing the panel.
            DebugLogger.log("SpaceSwitcher", details: "activation: committed during the preview wait")
            commitSelection()
            return
        }

        let screen = Self.targetScreen()
        // A new panel every session: an NSPanel that was on screen when Mission
        // Control opened can come back with a zero frame and never show again.
        self.panel?.close()
        let panel = SpaceSwitcherPanelCoordinator()
        self.panel = panel
        panel.show(state: state, on: screen)
        publishTapPanelFrame()
        // Captures still running keep landing in the panel via the prewarm
        // task; a cached pass that has gone stale is redone behind the panel.
        if prewarm.isComplete, prewarmAge > Self.prewarmStaleAge {
            prewarmPreviews(force: true, model: model)
        }
    }

    /// Screen the panel opens on, per the Placement setting; falls back to the
    /// screen under the mouse.
    @MainActor
    static func targetScreen() -> NSScreen {
        SwitcherScreenPlacement.resolve(
            strategy: Defaults[.spaceSwitcherPlacementStrategy],
            pinnedIdentifier: Defaults[.spaceSwitcherPinnedScreenIdentifier],
            resolveLastActiveWindow: true
        ) ?? SwitcherScreenPlacement.mouseScreen()
    }

    @MainActor
    func navigate(_ direction: ArrowDirection) {
        state?.navigate(direction)
    }

    @MainActor
    func commitSelection() {
        guard let state, let space = state.selectedSpace else {
            if activationPending {
                commitOnActivation = true // Return during the preview wait
            } else {
                cancel()
            }
            return
        }
        commit(space)
    }

    @MainActor
    func cancel() {
        if activationPending {
            activationCancelled = true // Escape or click-outside during the wait
        }
        endSession()
    }

    @MainActor
    private func commit(_ space: SpaceInfo) {
        let model = state?.model
        let cursorBefore = CGEvent(source: nil)?.location
        endSession()
        guard let model else { return }
        if WindowSpaces.isMissionControlActive() {
            DebugLogger.log("SpaceSwitcher", details: "commit skipped: Mission Control active")
            return
        }
        SpaceSwitcherEngine.switchTo(space: space, in: model)

        // Warp only when the commit crosses displays; same-display switches
        // should leave the cursor where the user had it.
        if Defaults[.spaceSwitcherWarpCursor],
           let cursorBefore,
           let screen = WindowSpaces.screen(forDisplayIdentifier: space.displayIdentifier)
        {
            let screenCG = screen.cgFrame
            if !screenCG.contains(cursorBefore) {
                CGWarpMouseCursorPosition(CGPoint(x: screenCG.midX, y: screenCG.midY))
            }
        }
    }

    @MainActor
    func moveWindow(_ windowID: CGWindowID, to space: SpaceInfo) {
        guard !space.isFullscreen else { return }
        let moved = WindowSpaces.move(windowID: windowID, toManagedSpace: space.id)
        DebugLogger.log("SpaceSwitcher", details: "drag-move wid=\(windowID) to space \(space.id): \(moved)")
        if moved, let state {
            state.model = SpaceSwitcherEngine.buildModel()
        }
    }

    @MainActor
    private func endSession() {
        panel?.hide()
        panel?.close()
        panel = nil
        publishTapPanelFrame()
        state = nil
        onSessionEnd?()
    }

    @MainActor
    func moveFrontmostWindowToSelectedSpace() {
        guard let state, let space = state.selectedSpace, !space.isFullscreen else {
            DebugLogger.log("SpaceSwitcher", details: "move: no session/selection or fullscreen target")
            return
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            DebugLogger.log("SpaceSwitcher", details: "move: no frontmost app")
            return
        }

        let appAX = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focused: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focused)
        guard axResult == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else {
            DebugLogger.log("SpaceSwitcher", details: "move: no focused window for \(frontApp.localizedName ?? "?") ax=\(axResult.rawValue)")
            return
        }

        var windowID: CGWindowID = 0
        _AXUIElementGetWindow(focused as! AXUIElement, &windowID)
        guard windowID != 0 else {
            DebugLogger.log("SpaceSwitcher", details: "move: could not resolve window id")
            return
        }

        let moved = WindowSpaces.move(windowID: windowID, toManagedSpace: space.id)
        DebugLogger.log("SpaceSwitcher", details: "move wid=\(windowID) app=\(frontApp.localizedName ?? "?") to space \(space.id): \(moved)")
        if moved {
            state.model = SpaceSwitcherEngine.buildModel()
        }
    }

    private static func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = maxDimension / max(width, height)
        guard scale < 1 else { return image }

        let newWidth = Int(width * scale)
        let newHeight = Int(height * scale)
        guard newWidth > 0, newHeight > 0 else { return image }
        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? image
    }

    /// Every window the panel shows, deduped and capped, most useful first:
    /// missing thumbnails (cold cache renders icon boxes), then current-space
    /// windows (composited live, so captures are cheap and accurate — and
    /// their content just changed under the user), then off-space ones
    /// (whose captures return the last-drawn frame anyway).
    private static func thumbnailCaptureOrder(for model: SpaceSwitcherEngine.Model) -> [SpaceSwitcherEngine.SpaceWindow] {
        let currentSpaceIDs = Set(model.allSpaces.filter(\.isCurrent).map(\.id))
        var priority: [CGWindowID: Int] = [:]
        var windowsByID: [CGWindowID: SpaceSwitcherEngine.SpaceWindow] = [:]
        for (spaceID, windows) in model.windowsBySpace {
            for window in windows {
                windowsByID[window.id] = window
                let rank = window.image == nil ? 0 : (currentSpaceIDs.contains(spaceID) ? 1 : 2)
                priority[window.id] = min(priority[window.id, default: rank], rank)
            }
        }
        return Array(windowsByID.values.sorted { priority[$0.id, default: 2] < priority[$1.id, default: 2] }.prefix(24))
    }

    /// Fresh capture of one window: full-resolution copy into the shared
    /// cache (dock previews and the next open seed from it), downsampled
    /// copy for the tile. nil when capture fails, returns a corrupt sliver
    /// (seen with Chrome windows whose AX bridge has died), or is cropped by a
    /// Space transition in progress, so the last good tile survives.
    private static func captureThumbnail(_ window: SpaceSwitcherEngine.SpaceWindow, cap: CGFloat) -> CGImage? {
        var windowID = UInt32(window.id)
        let quality: CGSWindowCaptureOptions = Defaults[.windowImageCaptureQuality] == .best ? .bestResolution : .nominalResolution
        guard let images = CGSHWCaptureWindowList(CGSMainConnectionID(), &windowID, 1, [.ignoreGlobalClipShape, quality]) as? [CGImage],
              let image = images.first,
              image.width >= WindowUtil.minUsableImageDimension, image.height >= WindowUtil.minUsableImageDimension
        else { return nil }
        let entry = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: AnyObject]])?.first
        let bounds = entry.flatMap { CGRect(cgWindowBounds: $0[kCGWindowBounds as String]) }
        if WindowUtil.isClippedBySpaceTransition(image, bounds: bounds, windowID: window.id) {
            DebugLogger.log("SpaceSwitcher", details: "capture clipped by Space transition, keeping previous tile: window \(window.id)")
            return nil
        }
        // The cache is keyed by the display app's pid, which can differ from
        // the CGS owner for helper-owned windows; windows with no cache entry
        // have nothing to update.
        if let cachePid = window.info?.app.processIdentifier {
            WindowUtil.storeRefreshedWindowImage(image, windowID: window.id, pid: cachePid)
        }
        return downsample(image, maxDimension: cap)
    }

    /// True when swapping `old` for `new` would visibly change the tile:
    /// a different shape, or content that differs beyond capture noise.
    /// Compared on a 32×18 grayscale reduction. Internal for testing.
    static func thumbnailsDiffer(_ old: CGImage, _ new: CGImage) -> Bool {
        let oldAspect = CGFloat(old.width) / CGFloat(max(1, old.height))
        let newAspect = CGFloat(new.width) / CGFloat(max(1, new.height))
        if abs(oldAspect - newAspect) > 0.02 * max(oldAspect, newAspect) { return true }
        guard let a = grayReduction(old), let b = grayReduction(new) else { return true }
        var total = 0
        for index in 0 ..< a.count {
            total += abs(Int(a[index]) - Int(b[index]))
        }
        return Double(total) / Double(a.count) > 3
    }

    private static func grayReduction(_ image: CGImage) -> [UInt8]? {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
