import AppKit
import ApplicationServices
import Defaults

final class SpaceSwitchingCoordinator {
    private var panel: SpaceSwitcherPanelCoordinator?
    private var state: SpaceSwitcherState?
    private var sessionID = UUID()
    /// Windows this session moved, pinned to their target space until CGS
    /// starts reporting their assignment again (it returns [] right after a
    /// move, which would otherwise drop them from every card).
    private var recentMoves: [CGWindowID: CGSSpaceID] = [:]

    /// Fired whenever a session ends (or an activation no-ops), so the owning
    /// KeybindHelper can clear its tap-thread session flag on every exit path,
    /// including card clicks that never route back through the event tap.
    var onSessionEnd: (() -> Void)?

    private var learningObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    private var restoreObserver: NSObjectProtocol?

    init() {
        // The one space-change observer, serving both lifecycles:
        // - keep the open session's current-space markers fresh if the user
        //   switches spaces natively (trackpad swipe, other tools);
        // - learn window→space attributions from normal space usage so
        //   previews are complete without ever having opened the switcher
        //   on a space (debounced until the switch settles).
        learningObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleActiveSpaceChanged()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                Task { @MainActor in SpaceSwitcherEngine.learnVisibleWindows() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in SpaceSwitcherEngine.learnVisibleWindows() }
        }

        // Display added/removed (or resolution changed): the session's model
        // rows and the panel's screen are stale, and macOS migrates spaces to
        // new IDs — cancel any open session and relearn once things settle.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleScreenParametersChanged()
            }
        }

        // Display layout memory is about to move windows between spaces: an
        // open session's buckets would be wrong, and its recentMoves stale.
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

    /// Display topology changed: the open session (if any) is stale, and the
    /// persisted learned map may reference migrated space IDs.
    @MainActor
    private func handleScreenParametersChanged() {
        DebugLogger.log("SpaceSwitcher", details: "screen parameters changed; cancelling session and rescheduling learning")
        if isSessionActive {
            cancel()
        }
        // Space migration takes a moment; learn (and prune dead space IDs from
        // the persisted map) once the new topology is stable.
        relearnTask?.cancel()
        relearnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            SpaceSwitcherEngine.learnVisibleWindows()
        }
    }

    /// Debounced post-reconfiguration learning pass.
    private var relearnTask: Task<Void, Never>?

    /// Refresh the open session's current-space markers (no-op with no session).
    @MainActor
    private func handleActiveSpaceChanged() {
        guard let state else { return }
        state.model = SpaceSwitcherEngine.Model(
            displays: WindowSpaces.displaySpacesSnapshot(order: Defaults[.spaceSwitcherDisplayOrder]),
            windowsBySpace: state.model.windowsBySpace
        )
    }

    @MainActor
    var isSessionActive: Bool {
        state != nil
    }

    /// Read from the event tap thread for click-outside dismissal; NSPanel frame
    /// reads off-main match the existing pattern in KeybindHelper's mouse handler.
    var visiblePanelFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Thumbnails being captured ahead of a session — started when the
    /// chord's modifier goes down, so by the time the trigger key arrives
    /// most pictures are already fresh. Keeps feeding the open panel.
    @MainActor
    private final class PreviewPrewarm {
        let model: SpaceSwitcherEngine.Model
        let order: [SpaceSwitcherEngine.SpaceWindow]
        let startedAt = Date()
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
    /// The trigger key arrived and the panel is waiting for previews.
    private var activationPending = false
    /// The modifier came up during that wait: a quick tap — commit as soon
    /// as the session exists instead of showing the panel.
    private var commitOnActivation = false
    /// A prewarm older than this is rebuilt at activation: windows may have
    /// come and gone while the modifier was held.
    private static let prewarmModelLifetime: TimeInterval = 2

    /// The chord's modifier went down: build the model and start capturing
    /// thumbnails in the background, most useful first — unless a pass from
    /// the last minute is already cached. Once started, a pass runs to
    /// completion; it is never thrown away for a chord that turns out to be
    /// something else, so the cost stays bounded.
    @MainActor
    func prewarmPreviews(force: Bool = false) {
        guard Defaults[.enableSpaceSwitcher] else { return }
        if !force, let prewarm, Date().timeIntervalSince(prewarm.startedAt) < Self.prewarmCacheLifetime { return }
        prewarm?.task?.cancel()

        let model = SpaceSwitcherEngine.buildModel()
        let order = Self.thumbnailCaptureOrder(for: model)
        let prewarm = PreviewPrewarm(model: model, order: order)
        self.prewarm = prewarm
        DebugLogger.log("SpaceSwitcher", details: "prewarm started for \(order.count) windows")
        guard WindowUtil.shouldCaptureWindowImages(), !order.isEmpty else {
            prewarm.isComplete = true
            return
        }
        let cap = Self.downsampleCap(cardWidth: Defaults[.spaceSwitcherCardWidth], on: NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main ?? NSScreen.screens[0])
        prewarm.task = Task.detached(priority: .userInitiated) { [weak self, weak prewarm] in
            for window in order {
                guard !Task.isCancelled else { return }
                let fresh = Self.captureThumbnail(window, cap: cap)
                await MainActor.run { [weak self, weak prewarm] in
                    guard let self, let prewarm, self.prewarm === prewarm else { return }
                    prewarm.visited += 1
                    if let fresh, window.image.map({ Self.thumbnailsDiffer($0, fresh) }) ?? true {
                        prewarm.images[window.id] = fresh
                        if let state {
                            state.model = state.model.replacingImages([window.id: fresh])
                        }
                    }
                }
            }
            await MainActor.run { [weak prewarm] in prewarm?.isComplete = true }
        }
    }

    /// The chord's modifier came up with no session open yet. A cached
    /// prewarm stays for the next press; a pending activation becomes a
    /// quick tap.
    @MainActor
    func modifierReleasedBeforeSession() {
        if activationPending {
            commitOnActivation = true
        }
    }

    @MainActor
    func handleActivation(isShiftPressed: Bool) async {
        // A second trigger press while the first is still waiting for
        // previews: let it finish, then cycle.
        while activationPending {
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
        if let state {
            if isShiftPressed {
                state.cycleBackward()
            } else {
                state.cycleForward()
            }
            return
        }

        activationPending = true
        defer {
            activationPending = false
            commitOnActivation = false
        }

        // Fresh previews before the panel shows, like the dock: wait for a
        // prewarm in progress up to the configured delay. Held for a moment
        // first, or pressed within a minute of the last one, it is usually
        // done already; pressed as a quick chord, it just started.
        if prewarm == nil {
            prewarmPreviews()
        }
        if let prewarm, !prewarm.isComplete, !commitOnActivation {
            let deadline = Date().addingTimeInterval(Defaults[.spaceSwitcherPreviewDelay])
            while !prewarm.isComplete, !commitOnActivation, Date() < deadline {
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }
        guard let prewarm else {
            onSessionEnd?()
            return
        }

        let prewarmAge = Date().timeIntervalSince(prewarm.startedAt)
        var model = prewarm.model
        if prewarmAge > Self.prewarmModelLifetime {
            model = SpaceSwitcherEngine.buildModel()
        }
        model = model.replacingImages(prewarm.images)
        DebugLogger.log("SpaceSwitcher", details: "activation: prewarm \(Int(prewarmAge * 1000)) ms old, \(prewarm.visited)/\(prewarm.order.count) captured, \(prewarm.images.count) changed")
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
        sessionID = UUID()

        // First press advances off the current space, mirroring cmd+tab
        if Defaults[.spaceSwitcherStartOnSecondSpace] {
            state.advance(backward: isShiftPressed)
        }

        if commitOnActivation, !Defaults[.spaceSwitcherStayOpenOnRelease] {
            // Quick tap: the modifier was already up before previews were
            // ready, so switch without ever showing the panel.
            DebugLogger.log("SpaceSwitcher", details: "activation: modifier released during preview wait; committing directly")
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
        // Captures still running keep landing in the panel via the prewarm
        // task; a cached pass that has gone stale is redone behind the panel.
        if prewarm.isComplete, prewarmAge > Self.prewarmStaleAge {
            prewarmPreviews(force: true)
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
            cancel()
            return
        }
        commit(space)
    }

    @MainActor
    func cancel() {
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
            recentMoves[windowID] = space.id
            state.model = SpaceSwitcherEngine.buildModel(attributionOverrides: recentMoves)
        }
    }

    @MainActor
    private func endSession() {
        sessionID = UUID()
        recentMoves = [:]
        panel?.hide()
        panel?.close()
        panel = nil
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
            recentMoves[windowID] = space.id
            state.model = SpaceSwitcherEngine.buildModel(attributionOverrides: recentMoves)
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

    /// Cap thumbnails near their largest possible rendered size: a tile can
    /// be nearly card-width, and on Retina that is points × scale physical
    /// pixels — a fixed 800 cap would upscale (blur) on cards wider than
    /// ~400 points.
    private static func downsampleCap(cardWidth: CGFloat, on screen: NSScreen) -> CGFloat {
        max(800, cardWidth * screen.backingScaleFactor)
    }

    /// Fresh capture of one window: full-resolution copy into the shared
    /// cache (dock previews and the next open seed from it), downsampled
    /// copy for the tile. nil when capture fails or returns a corrupt sliver
    /// (seen with Chrome windows whose AX bridge has died).
    private static func captureThumbnail(_ window: SpaceSwitcherEngine.SpaceWindow, cap: CGFloat) -> CGImage? {
        var windowID = UInt32(window.id)
        let quality: CGSWindowCaptureOptions = Defaults[.windowImageCaptureQuality] == .best ? .bestResolution : .nominalResolution
        guard let images = CGSHWCaptureWindowList(CGSMainConnectionID(), &windowID, 1, [.ignoreGlobalClipShape, quality]) as? [CGImage],
              let image = images.first,
              image.width >= WindowUtil.minUsableImageDimension, image.height >= WindowUtil.minUsableImageDimension
        else { return nil }
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
    /// Compared on a 32×18 grayscale reduction, well under a millisecond.
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
