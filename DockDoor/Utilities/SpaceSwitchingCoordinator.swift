import AppKit
import ApplicationServices
import Defaults

final class SpaceSwitchingCoordinator {
    private var panel: SpaceSwitcherPanelCoordinator?
    private var state: SpaceSwitcherState?
    private var refreshTask: Task<Void, Never>?
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

    @MainActor
    func handleActivation(isShiftPressed: Bool) {
        if let state {
            if isShiftPressed {
                state.cycleBackward()
            } else {
                state.cycleForward()
            }
            return
        }

        let model = SpaceSwitcherEngine.buildModel()
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

        let screen = Self.targetScreen()
        // A new panel every session: an NSPanel that was on screen when Mission
        // Control opened can come back with a zero frame and never show again.
        self.panel?.close()
        let panel = SpaceSwitcherPanelCoordinator()
        self.panel = panel
        panel.show(state: state, on: screen)

        scheduleThumbnailRefresh(for: state, on: screen)
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
        refreshTask?.cancel()
        refreshTask = nil
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

    /// Off-space window images come from the cache and can be stale; refresh the
    /// most-recent few per space after the panel is already on screen.
    @MainActor
    private func scheduleThumbnailRefresh(for state: SpaceSwitcherState, on screen: NSScreen) {
        guard WindowUtil.shouldCaptureWindowImages() else { return }
        let session = sessionID
        let model = state.model

        // Cap thumbnails near their largest possible rendered size: a tile can
        // be nearly card-width, and on Retina that is points × scale physical
        // pixels — a fixed 800 cap would upscale (blur) on cards wider than
        // ~400 points.
        let cardWidth = min(Defaults[.spaceSwitcherCardWidth], state.maxCardWidth)
        let downsampleCap = max(800, cardWidth * screen.backingScaleFactor)

        // Refresh every window the panel shows, deduped and capped. Cached
        // images can be arbitrarily old (a tab change is a title-only AX event
        // that never recaptures), so current-space windows are not exempt.
        // Priority: missing thumbnails (cold cache renders icon boxes), then
        // current-space windows (composited live, so captures are cheap and
        // accurate — and their content just changed under the user), then
        // off-space ones (whose captures return the last-drawn frame anyway).
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
        let captureList = Array(
            windowsByID.values
                .sorted { priority[$0.id, default: 2] < priority[$1.id, default: 2] }
                .prefix(24)
        )

        refreshTask = Task(priority: .low) { [weak self] in
            var refreshed: [CGWindowID: CGImage] = [:]
            for window in captureList {
                guard !Task.isCancelled else { return }
                if let image = try? await WindowUtil.captureWindowImage(
                    windowID: window.id,
                    pid: window.pid,
                    windowTitle: window.title,
                    forceRefresh: true
                ) {
                    // A corrupt backing store captures as a 1-2px sliver (seen
                    // with Chrome windows whose AX bridge has died); keep the
                    // last good thumbnail instead, matching the cache's policy.
                    guard image.width >= WindowUtil.minUsableImageDimension,
                          image.height >= WindowUtil.minUsableImageDimension
                    else { continue }
                    // Full-resolution copy into the shared cache so dock
                    // previews and the next open seed from it. The cache is
                    // keyed by the display app's pid, which can differ from
                    // the CGS owner for helper-owned windows; windows with no
                    // cache entry have nothing to update.
                    if let cachePid = window.info?.app.processIdentifier {
                        WindowUtil.storeRefreshedWindowImage(image, windowID: window.id, pid: cachePid)
                    }
                    // High-quality pre-downsample: thumbnails render at a small
                    // fraction of capture size, and GPU minification aliases
                    // text badly; a single CG resample keeps it legible.
                    refreshed[window.id] = Self.downsample(image, maxDimension: downsampleCap)
                }
            }
            guard !Task.isCancelled, !refreshed.isEmpty else { return }

            await MainActor.run { [weak self] in
                guard let self, sessionID == session, let state = self.state else { return }
                var updatedMap = state.model.windowsBySpace
                for (spaceID, windows) in updatedMap {
                    updatedMap[spaceID] = windows.map { window in
                        guard let image = refreshed[window.id] else { return window }
                        return SpaceSwitcherEngine.SpaceWindow(
                            id: window.id,
                            pid: window.pid,
                            frame: window.frame,
                            title: window.title,
                            appName: window.appName,
                            icon: window.icon,
                            image: image,
                            isSticky: window.isSticky,
                            info: window.info
                        )
                    }
                }
                state.model = SpaceSwitcherEngine.Model(
                    displays: state.model.displays,
                    windowsBySpace: updatedMap
                )
            }
        }
    }
}
