import AppKit
import Carbon
import Carbon.HIToolbox.Events
import Defaults

private class KeybindHelperUserInfo {
    let instance: KeybindHelper
    init(instance: KeybindHelper) {
        self.instance = instance
    }
}

struct UserKeyBind: Codable, Equatable, Defaults.Serializable {
    var keyCode: UInt16
    var modifierFlags: Int
}

private class WindowSwitchingCoordinator {
    private var isProcessingSwitcher = false
    private var uiRenderingTask: Task<Void, Never>?
    private var windowRefreshTask: Task<Void, Never>?
    private var currentSessionId = UUID()
    /// When true, initialization should complete but immediately select the window instead of showing UI
    private var shouldSelectImmediately = false

    private static var lastUpdateAllWindowsTime: Date?
    private static let updateAllWindowsThrottleInterval: TimeInterval = 5.0

    @MainActor
    func handleWindowSwitching(
        previewCoordinator: SharedPreviewWindowCoordinator,
        isModifierPressed: Bool,
        isShiftPressed: Bool,
        mode: SwitcherInvocationMode = .allWindows
    ) async {
        guard !isProcessingSwitcher else { return }
        isProcessingSwitcher = true
        defer { isProcessingSwitcher = false }

        let coordinator = previewCoordinator.windowSwitcherCoordinator

        if coordinator.isKeybindSessionActive {
            coordinator.hasMovedSinceOpen = false
            coordinator.initialHoverLocation = nil

            if isShiftPressed {
                coordinator.cycleBackward()
            } else {
                coordinator.cycleForward()
            }
        } else if isModifierPressed {
            await initializeWindowSwitching(
                previewCoordinator: previewCoordinator,
                mode: mode
            )
        }
    }

    @MainActor
    private func initializeWindowSwitching(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode = .allWindows
    ) async {
        // Reset the immediate-select flag at start of initialization
        shouldSelectImmediately = false
        windowRefreshTask?.cancel()

        currentSessionId = UUID()
        let sessionId = currentSessionId
        let targetScreen = getTargetScreenForSwitcher()
        let currentMouseLocation = DockObserver.getMousePosition()
        let dockPosition = DockUtils.getDockPosition()

        var windows = buildSwitcherWindows(mode: mode)
        if windows.isEmpty {
            // The switcher normally opens from cache. If the cache has nothing usable,
            // do one discovery pass before giving up so late-observed GUI apps can appear.
            WindowSwitchingCoordinator.lastUpdateAllWindowsTime = Date()
            await WindowUtil.updateAllWindowsInCurrentSpace()
            guard sessionId == currentSessionId else { return }
            windows = buildSwitcherWindows(mode: mode)
        }
        guard !windows.isEmpty else { return }

        let coordinator = previewCoordinator.windowSwitcherCoordinator
        coordinator.initializeForWindowSwitcher(with: windows, dockPosition: dockPosition, bestGuessMonitor: targetScreen)
        coordinator.activateKeybindSession()

        // If modifier was released during initialization, immediately select and exit
        if shouldSelectImmediately {
            if let selectedWindow = coordinator.getCurrentWindow() {
                selectedWindow.bringToFront()
                selectedWindow.warpMouseToCenterIfNeeded()
                if selectedWindow.isWindowlessApp, Defaults[.openNewWindowForWindowlessApps] {
                    WindowUtil.activateAndOpenNewWindow(app: selectedWindow.app)
                }
            }
            coordinator.deactivateKeybindSession()
            previewCoordinator.hideWindow()
            shouldSelectImmediately = false
            return
        }

        uiRenderingTask?.cancel()
        uiRenderingTask = Task { @MainActor in
            if !Defaults[.instantWindowSwitcher] {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await renderWindowSwitcherUI(
                previewCoordinator: previewCoordinator,
                mode: mode,
                dockPosition: dockPosition,
                currentMouseLocation: currentMouseLocation,
                targetScreen: targetScreen,
                sessionId: sessionId
            )
        }
    }

    @MainActor
    private func buildSwitcherWindows(mode: SwitcherInvocationMode) -> [WindowInfo] {
        var windows = WindowUtil.getAllWindowsOfAllApps()
        let windowsForWindowlessDetection = windows

        let filterBySpace = (mode == .currentSpaceOnly || mode == .activeAppCurrentSpace)
            || (mode == .allWindows && Defaults[.showWindowsFromCurrentSpaceOnlyInSwitcher])
        if filterBySpace {
            windows = WindowUtil.filterWindowsByCurrentSpace(windows)
        }

        if mode == .allWindows, Defaults[.showWindowsFromCurrentMonitorOnlyInSwitcher] {
            windows = WindowUtil.filterWindowsByCurrentMonitor(windows)
        }

        let filterByApp = isActiveAppMode(mode)
        if filterByApp {
            windows = WindowUtil.getWindowsForFrontmostApp(from: windows)
        }

        if !Defaults[.includeHiddenWindowsInSwitcher] {
            windows = windows.filter { !$0.isHidden && !$0.isMinimized }
        }

        windows = WindowUtil.sortWindowsForSwitcher(windows)

        if !filterByApp {
            windows = WindowUtil.groupWindowsByApp(windows)
        }

        if !filterByApp, Defaults[.showWindowlessAppsInSwitcher] {
            windows.append(contentsOf: WindowUtil.getWindowlessRunningApps(existingWindows: windowsForWindowlessDetection))
        }

        return windows
    }

    private func isActiveAppMode(_ mode: SwitcherInvocationMode) -> Bool {
        (mode == .activeAppOnly || mode == .activeAppCurrentSpace)
            || (mode == .allWindows && Defaults[.limitSwitcherToFrontmostApp])
    }

    @MainActor
    private func scheduleWindowRefresh(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode,
        dockPosition: DockPosition,
        targetScreen: NSScreen,
        sessionId: UUID
    ) {
        let now = Date()
        if let lastUpdate = WindowSwitchingCoordinator.lastUpdateAllWindowsTime,
           now.timeIntervalSince(lastUpdate) < WindowSwitchingCoordinator.updateAllWindowsThrottleInterval
        {
            return
        }
        WindowSwitchingCoordinator.lastUpdateAllWindowsTime = now

        windowRefreshTask?.cancel()
        windowRefreshTask = Task.detached(priority: .low) { [weak self, weak previewCoordinator, mode, dockPosition, targetScreen, sessionId] in
            await WindowUtil.updateAllWindowsInCurrentSpace()
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, let previewCoordinator else { return }
                guard sessionId == self.currentSessionId else { return }

                let coordinator = previewCoordinator.windowSwitcherCoordinator
                guard coordinator.isKeybindSessionActive else { return }

                let freshWindows = self.buildSwitcherWindows(mode: mode)
                guard !freshWindows.isEmpty else { return }

                self.applyRefreshedSwitcherWindows(
                    freshWindows,
                    coordinator: coordinator,
                    dockPosition: dockPosition,
                    bestGuessMonitor: targetScreen
                )
            }
        }
    }

    @MainActor
    private func applyRefreshedSwitcherWindows(
        _ freshWindows: [WindowInfo],
        coordinator: PreviewStateCoordinator,
        dockPosition: DockPosition,
        bestGuessMonitor: NSScreen
    ) {
        let selectedWindow = coordinator.getCurrentWindow()
        let previousWindowCount = coordinator.windows.count

        // Replace the global switcher list rather than using the single-app merge path.
        // Windowless entries can share window ID 0, so preserving the full rebuilt list is safer.
        coordinator.setWindows(freshWindows, dockPosition: dockPosition, bestGuessMonitor: bestGuessMonitor)

        if let selectedWindow,
           let newIndex = coordinator.windows.firstIndex(where: { isSameSwitcherWindow($0, selectedWindow) })
        {
            coordinator.setIndex(to: newIndex)
        }

        if coordinator.windows.count != previousWindowCount {
            coordinator.onFrameRefreshNeeded?()
        }
    }

    private func isSameSwitcherWindow(_ first: WindowInfo, _ second: WindowInfo) -> Bool {
        // Window ID alone is not enough here because placeholder/windowless entries use 0.
        first.id == second.id &&
            first.app.processIdentifier == second.app.processIdentifier
    }

    @MainActor
    private func renderWindowSwitcherUI(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode,
        dockPosition: DockPosition,
        currentMouseLocation: CGPoint,
        targetScreen: NSScreen,
        sessionId: UUID
    ) async {
        guard sessionId == currentSessionId else { return }
        let coordinator = previewCoordinator.windowSwitcherCoordinator
        guard coordinator.isKeybindSessionActive else { return }

        if previewCoordinator.isVisible, coordinator.windowSwitcherActive {
            return
        }
        let showWindowLambda = { (mouseLocation: NSPoint?, mouseScreen: NSScreen?) in
            let windows = coordinator.windows
            guard !windows.isEmpty else { return }
            previewCoordinator.showWindow(
                appName: "Window Switcher",
                windows: windows,
                mouseLocation: mouseLocation,
                mouseScreen: mouseScreen,
                dockItemElement: nil,
                overrideDelay: true,
                centeredHoverWindowState: .windowSwitcher,
                onWindowTap: {
                    self.cancelSwitching(previewCoordinator: previewCoordinator)
                    Task { @MainActor in
                        previewCoordinator.hideWindow()
                    }
                },
                initialIndex: coordinator.currIndex
            )
        }

        switch Defaults[.windowSwitcherPlacementStrategy] {
        case .pinnedToScreen:
            let screenCenter = NSPoint(x: targetScreen.frame.midX, y: targetScreen.frame.midY)
            showWindowLambda(screenCenter, targetScreen)
        case .screenWithLastActiveWindow:
            showWindowLambda(nil, nil)
        case .screenWithMouse:
            let mouseScreen = NSScreen.screenFromQuartzPoint(currentMouseLocation)
            let convertedMouseLocation = DockObserver.nsPointFromCGPoint(currentMouseLocation, forScreen: mouseScreen)
            showWindowLambda(convertedMouseLocation, mouseScreen)
        }

        if Defaults[.focusSearchOnWindowSwitcherOpen], Defaults[.enableWindowSwitcherSearch] {
            previewCoordinator.focusSearchWindow()
        }

        // Refresh only once the switcher is actually on screen, so quick press-release
        // invocations that never render skip the discovery pass entirely.
        scheduleWindowRefresh(
            previewCoordinator: previewCoordinator,
            mode: mode,
            dockPosition: dockPosition,
            targetScreen: targetScreen,
            sessionId: sessionId
        )
    }

    private func getTargetScreenForSwitcher() -> NSScreen {
        // .screenWithLastActiveWindow is deferred: showWindow resolves it via
        // its nil-location path, so only the pinned screen is resolved here.
        SwitcherScreenPlacement.resolve(
            strategy: Defaults[.windowSwitcherPlacementStrategy],
            pinnedIdentifier: Defaults[.pinnedScreenIdentifier],
            resolveLastActiveWindow: false
        ) ?? SwitcherScreenPlacement.mouseScreen()
    }

    @MainActor
    func selectCurrentWindow(previewCoordinator: SharedPreviewWindowCoordinator) -> WindowInfo? {
        let coordinator = previewCoordinator.windowSwitcherCoordinator
        guard coordinator.isKeybindSessionActive else { return nil }

        let selectedWindow = coordinator.getCurrentWindow()
        currentSessionId = UUID()
        coordinator.deactivateKeybindSession()
        uiRenderingTask?.cancel()
        windowRefreshTask?.cancel()
        return selectedWindow
    }

    func isActive(previewCoordinator: SharedPreviewWindowCoordinator) -> Bool {
        previewCoordinator.windowSwitcherCoordinator.isKeybindSessionActive
    }

    @MainActor
    func cancelSwitching(previewCoordinator: SharedPreviewWindowCoordinator) {
        currentSessionId = UUID()
        shouldSelectImmediately = false
        previewCoordinator.windowSwitcherCoordinator.deactivateKeybindSession()
        uiRenderingTask?.cancel()
        windowRefreshTask?.cancel()
    }

    /// Signals that the modifier was released during initialization.
    /// If initialization is still in progress, it will complete but immediately select the window.
    /// If initialization already completed, this just cancels the UI rendering task.
    @MainActor
    func cancelPendingRender() {
        currentSessionId = UUID()
        shouldSelectImmediately = true
        uiRenderingTask?.cancel()
        windowRefreshTask?.cancel()
    }
}

class KeybindHelper {
    private let previewCoordinator: SharedPreviewWindowCoordinator
    private let windowSwitchingCoordinator = WindowSwitchingCoordinator()
    private let spaceSwitchingCoordinator = SpaceSwitchingCoordinator()

    private var isSpaceModifierKeyPressed: Bool = false
    private var hasProcessedSpaceModifierRelease: Bool = false
    /// Tap-thread mirror of the space switcher session, parallel to `switcherSessionActive`.
    private var spaceSwitcherSessionActive: Bool = false

    private var isSwitcherModifierKeyPressed: Bool = false
    private var isShiftKeyPressedGeneral: Bool = false
    private var hasProcessedModifierRelease: Bool = false
    private var preventSwitcherHideOnRelease: Bool = false
    private var heldKeyRepeatTask: Task<Void, Never>?

    /// Track the invocation mode for alternate keybinds
    private var currentInvocationMode: SwitcherInvocationMode = .allWindows

    // Track Command key state to detect key-up fallback for lingering previews
    private var isCommandKeyCurrentlyDown: Bool = false
    private var lastCmdTabObservedActive: Bool = false
    private var cmdTabActionPerformed: Bool = false
    /// Set on event tap thread when switcher keybind fires, so other keyDown handlers
    /// can detect the switcher is active without reading MainActor-only state.
    private var switcherSessionActive: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorTimer: Timer?
    private var unmanagedEventTapUserInfo: Unmanaged<KeybindHelperUserInfo>?

    init(previewCoordinator: SharedPreviewWindowCoordinator) {
        self.previewCoordinator = previewCoordinator
        spaceSwitchingCoordinator.onSessionEnd = { [weak self] in
            self?.spaceSwitcherSessionActive = false
        }
        setupEventTap()
        startMonitoring()
    }

    func reset() {
        cleanup()
        resetState()
        setupEventTap()
        startMonitoring()
    }

    private func cleanup() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        heldKeyRepeatTask?.cancel()
        heldKeyRepeatTask = nil
        removeEventTap()
    }

    /// Cancels any running held-key repeat task to prevent main thread blocking
    func cancelHeldKeyRepeatTask() {
        heldKeyRepeatTask?.cancel()
        heldKeyRepeatTask = nil
    }

    private func resetState() {
        isSwitcherModifierKeyPressed = false
        isShiftKeyPressedGeneral = false
        preventSwitcherHideOnRelease = false
        currentInvocationMode = .allWindows
        isSpaceModifierKeyPressed = false
        hasProcessedSpaceModifierRelease = false
        spaceSwitcherSessionActive = false
        Task { @MainActor [weak self] in
            guard let self, spaceSwitchingCoordinator.isSessionActive else { return }
            spaceSwitchingCoordinator.cancel()
        }
        cancelHeldKeyRepeatTask()
    }

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.checkEventTapStatus()
        }
    }

    private func checkEventTapStatus() {
        guard let eventTap, CGEvent.tapIsEnabled(tap: eventTap) else {
            reset()
            return
        }
    }

    private static let eventCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        return Unmanaged<KeybindHelperUserInfo>.fromOpaque(refcon).takeUnretainedValue().instance.handleEvent(proxy: proxy, type: type, event: event)
    }

    private func setupEventTap() {
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)

        let userInfo = KeybindHelperUserInfo(instance: self)
        unmanagedEventTapUserInfo = Unmanaged.passRetained(userInfo)

        guard let newEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: KeybindHelper.eventCallback,
            userInfo: unmanagedEventTapUserInfo?.toOpaque()
        ) else {
            unmanagedEventTapUserInfo?.release()
            unmanagedEventTapUserInfo = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                print("Retrying KeybindHelper event tap setup...")
                self?.setupEventTap()
            }
            return
        }

        eventTap = newEventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newEventTap, 0)

        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: newEventTap, enable: true)
        }
    }

    private func removeEventTap() {
        if let eventTap, let runLoopSource {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            unmanagedEventTapUserInfo?.release()
            unmanagedEventTapUserInfo = nil
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if let passthrough = reEnableIfNeeded(tap: eventTap, type: type, event: event) {
            return passthrough
        }

        switch type {
        case .flagsChanged:
            let keyBoardShortcutSaved: UserKeyBind = Defaults[.UserKeybind]
            let (currentSwitcherModifierIsPressed, currentShiftState) = updateModifierStatesFromFlags(event: event, keyBoardShortcutSaved: keyBoardShortcutSaved)

            // Track Command up/down explicitly for Cmd+Tab fallback behavior
            let cmdNowDown = event.flags.contains(.maskCommand)
            if isCommandKeyCurrentlyDown, !cmdNowDown {
                DockObserver.activeInstance?.teardownCmdTabObserver()

                if Defaults[.enableCmdTabEnhancements], lastCmdTabObservedActive {
                    let actionAlreadyHandled = cmdTabActionPerformed
                    let wasVisible = previewCoordinator.isVisible
                    Task { @MainActor in
                        if actionAlreadyHandled {
                            self.previewCoordinator.hideWindow()
                        } else if wasVisible, self.previewCoordinator.windowSwitcherCoordinator.currIndex >= 0 {
                            self.previewCoordinator.selectAndBringToFrontCurrentWindow()
                        } else {
                            self.previewCoordinator.hideWindow()
                        }
                        self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                    }
                }
                lastCmdTabObservedActive = false
                cmdTabActionPerformed = false
            }
            isCommandKeyCurrentlyDown = cmdNowDown

            var effectiveSwitcherModifierIsPressed = currentSwitcherModifierIsPressed
            if switcherSessionActive {
                if Self.chordModifiersHeld(keyBoardShortcutSaved.modifierFlags, flags: event.flags) {
                    effectiveSwitcherModifierIsPressed = true
                } else {
                    switcherSessionActive = false
                }
            }

            Task { @MainActor [weak self] in
                self?.handleModifierEvent(currentSwitcherModifierIsPressed: effectiveSwitcherModifierIsPressed, currentShiftState: currentShiftState)
            }

            if Defaults[.enableSpaceSwitcher] {
                let spaceKeybind = Defaults[.spaceSwitcherKeybind]
                var spaceModifierIsPressed = spaceKeybind.modifierFlags != 0 &&
                    Self.modifierFlagsMatch(spaceKeybind.modifierFlags, flags: event.flags, ignoring: Self.backwardFlagToIgnore(for: spaceKeybind))
                if spaceSwitcherSessionActive {
                    if Self.chordModifiersHeld(spaceKeybind.modifierFlags, flags: event.flags) {
                        spaceModifierIsPressed = true
                    } else if !Defaults[.spaceSwitcherStayOpenOnRelease] {
                        spaceSwitcherSessionActive = false
                    }
                }

                Task { @MainActor [weak self] in
                    self?.handleSpaceModifierEvent(isPressed: spaceModifierIsPressed)
                }
            }

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // Settings is recording a shortcut: hand it the chord instead of acting on it.
            if ShortcutRecorder.shared.handleKeyDown(keyCode: keyCode, flags: flags) {
                return nil
            }

            let shouldRouteCmdTabToWindowSwitcher = isCmdTabWindowSwitcherKeybind(keyCode: keyCode, flags: flags)

            // Consume bare spacebar for a visible media preview so it doesn't also reach the focused app and double-toggle playback.
            if keyCode == Int64(kVK_Space),
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               !flags.hasSuperfluousModifiers(),
               MediaKeyboardShortcutCoordinator.shared.handleSpaceKeyDown()
            {
                return nil
            }

            let backwardKeyCode = Defaults[.switcherBackwardKeyCode]
            if Self.eventFlagForKeyCode(backwardKeyCode) == nil,
               keyCode == Int64(backwardKeyCode),
               previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
            {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    handleModifierEvent(
                        currentSwitcherModifierIsPressed: isSwitcherModifierKeyPressed,
                        currentShiftState: true
                    )
                }
                return nil
            }

            // Detect Cmd+Tab press to start on-demand polling for the switcher
            if Defaults[.enableCmdTabEnhancements],
               keyCode == Int64(kVK_Tab),
               flags.contains(.maskCommand)
            {
                if !shouldRouteCmdTabToWindowSwitcher {
                    DockObserver.activeInstance?.startCmdTabPolling()
                }
            }

            // If system Cmd+Tab switcher is active, optionally handle arrows when enhancements are enabled
            if DockObserver.isCmdTabSwitcherActive, shouldRouteCmdTabToWindowSwitcher {
                DockObserver.activeInstance?.teardownCmdTabObserver()
                lastCmdTabObservedActive = false
                cmdTabActionPerformed = false
            } else if DockObserver.isCmdTabSwitcherActive {
                lastCmdTabObservedActive = true
                if Defaults[.enableCmdTabEnhancements],
                   previewCoordinator.isVisible
                {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let hasSelection = previewCoordinator.windowSwitcherCoordinator.currIndex >= 0
                    let flags = event.flags
                    switch keyCode {
                    case Int64(kVK_Escape):
                        Task { @MainActor in
                            self.previewCoordinator.hideWindow()
                        }
                        // Pass Escape through so the Dock can dismiss the system switcher too
                        return Unmanaged.passUnretained(event)
                    case Int64(kVK_LeftArrow):
                        if hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.navigateWithArrowKey(direction: .left)
                            }
                            // Consume only when a selection is active (focused mode)
                            return nil
                        } else {
                            // Let system Cmd+Tab handle left/right until user focuses with Up
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_RightArrow):
                        if hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.navigateWithArrowKey(direction: .right)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_UpArrow):
                        return Unmanaged.passUnretained(event)
                    case Int64(kVK_DownArrow):
                        // If a preview is selected, first Down just deselects and is consumed.
                        // Subsequent Down (with no selection) is passed through to system Exposé.
                        if hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: -1)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_ANSI_H), Int64(kVK_ANSI_L):
                        if Defaults[.enableVimMotions], hasSelection {
                            let dir: ArrowDirection = keyCode == Int64(kVK_ANSI_H) ? .left : .right
                            Task { @MainActor in
                                self.previewCoordinator.navigateWithArrowKey(direction: dir)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_ANSI_J):
                        if Defaults[.enableVimMotions], hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: -1)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    default:
                        // Allow activation via customizable Cmd+key (when not yet focused) and
                        // Command-based actions when a preview is focused
                        if flags.contains(.maskCommand) {
                            // Backward cycle key (default: `)
                            if hasSelection, keyCode == Int64(Defaults[.cmdTabBackwardCycleKey]) {
                                Task { @MainActor in
                                    let currentIndex = self.previewCoordinator.windowSwitcherCoordinator.currIndex
                                    let windowCount = self.previewCoordinator.windowSwitcherCoordinator.windows.count
                                    let newIndex = currentIndex > 0 ? currentIndex - 1 : windowCount - 1
                                    self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: newIndex)
                                }
                                return nil
                            }

                            // Forward cycle key (default: A)
                            if keyCode == Int64(Defaults[.cmdTabCycleKey]) {
                                Task { @MainActor in
                                    let currentIndex = self.previewCoordinator.windowSwitcherCoordinator.currIndex
                                    let windowCount = self.previewCoordinator.windowSwitcherCoordinator.windows.count
                                    let isShift = flags.contains(.maskShift)

                                    if !hasSelection {
                                        // First activation: select first preview
                                        self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: 0)
                                        Defaults[.hasSeenCmdTabFocusHint] = true
                                    } else if isShift {
                                        // Cmd+Shift+A: cycle backward
                                        let newIndex = currentIndex > 0 ? currentIndex - 1 : windowCount - 1
                                        self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: newIndex)
                                    } else {
                                        // Cmd+A: cycle forward
                                        let newIndex = (currentIndex + 1) % windowCount
                                        self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: newIndex)
                                    }
                                }
                                return nil
                            }
                        }

                        if hasSelection, flags.contains(.maskCommand) {
                            // Check configurable Cmd+key shortcuts
                            if let action = getActionForCmdShortcut(keyCode: keyCode) {
                                cmdTabActionPerformed = true
                                Task { @MainActor in
                                    self.previewCoordinator.performActionOnCurrentWindow(action: action)
                                }
                                return nil
                            }
                        }
                    }
                }
                // Not enhancing or not in our cmdTab context — let the system handle it.
                return Unmanaged.passUnretained(event)
            }
            let (shouldConsume, actionTask) = determineActionForKeyDown(event: event)
            if let task = actionTask {
                heldKeyRepeatTask?.cancel()
                heldKeyRepeatTask = Task { @MainActor in
                    await task()
                }
            }
            if shouldConsume { return nil }

        case .leftMouseDown:
            if spaceSwitcherSessionActive {
                // Use the event's own location (CG, top-left origin) rather than
                // NSEvent.mouseLocation: for synthetic clicks the hardware cursor
                // may not have moved to the click point yet.
                let clickCG = event.location
                var insidePanel = false
                if let panelFrame = spaceSwitchingCoordinator.visiblePanelFrame,
                   let primaryMaxY = NSScreen.screens.first?.frame.maxY
                {
                    insidePanel = panelFrame.flippedToQuartz(primaryScreenMaxY: primaryMaxY).contains(clickCG)
                }
                if !insidePanel {
                    spaceSwitcherSessionActive = false
                    Task { @MainActor in
                        self.hasProcessedSpaceModifierRelease = true
                        self.spaceSwitchingCoordinator.cancel()
                    }
                }
            }

            let isWindowSwitcherActive = previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
            let isCmdTabActive = DockObserver.isCmdTabSwitcherActive

            if previewCoordinator.isVisible, isWindowSwitcherActive || isCmdTabActive {
                let clickLocation = NSEvent.mouseLocation
                let windowFrame = previewCoordinator.frame

                let searchFrame = SharedPreviewWindowCoordinator.activeInstance?.searchWindowFrame
                let isInSearchWindow = searchFrame?.contains(clickLocation) ?? false
                if windowFrame.contains(clickLocation) || isInSearchWindow {
                    let flags = event.flags
                    if flags.contains(.maskControl) {
                        var newFlags = flags
                        newFlags.remove(.maskControl)
                        event.flags = newFlags
                    }
                } else {
                    switcherSessionActive = false
                    Task { @MainActor in
                        if isWindowSwitcherActive {
                            self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                            self.preventSwitcherHideOnRelease = false
                            self.hasProcessedModifierRelease = true
                        }
                        if isCmdTabActive {
                            DockObserver.activeInstance?.teardownCmdTabObserver()
                        }
                        self.previewCoordinator.hideWindow()
                    }
                }
            }

        case .keyUp:
            let backwardKeyCode = Defaults[.switcherBackwardKeyCode]
            if Self.eventFlagForKeyCode(backwardKeyCode) == nil,
               event.getIntegerValueField(.keyboardEventKeycode) == Int64(backwardKeyCode)
            {
                Task { @MainActor [weak self] in
                    self?.isShiftKeyPressedGeneral = false
                    self?.cancelHeldKeyRepeatTask()
                }
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static func eventFlagForKeyCode(_ keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift: .maskShift
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Command, kVK_RightCommand: .maskCommand
        default: nil
        }
    }

    /// True when a DockDoor switcher (Window or Space) owns the Cmd+Tab chord in `flags`,
    /// so the system app switcher must not be observed or deferred to for this event.
    private func isCmdTabWindowSwitcherKeybind(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == Int64(kVK_Tab), flags.contains(.maskCommand) else { return false }
        if usesCmdTabWindowSwitcherKeybind(), Self.modifierFlagsMatch(Defaults[.UserKeybind].modifierFlags, flags: flags) {
            return true
        }
        let spaceKeybind = Defaults[.spaceSwitcherKeybind]
        if usesCmdTabSpaceSwitcherKeybind(), Self.modifierFlagsMatch(spaceKeybind.modifierFlags, flags: flags, ignoring: Self.backwardFlagToIgnore(for: spaceKeybind)) {
            return true
        }
        return false
    }

    /// The shared Backward Key, when it is a modifier that is *not* part of the
    /// bind's own chord, may be held during activation to cycle backward.
    /// Internal for testing.
    static func backwardFlagToIgnore(for bind: UserKeyBind) -> CGEventFlags? {
        guard let flag = eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode]) else { return nil }
        return (bind.modifierFlags & Int(flag.rawValue)) != 0 ? nil : flag
    }

    private func usesCmdTabWindowSwitcherKeybind() -> Bool {
        guard Defaults[.enableWindowSwitcher] else { return false }

        let keybind = Defaults[.UserKeybind]
        let usesCommand = (keybind.modifierFlags & Int(CGEventFlags.maskCommand.rawValue)) != 0
        guard usesCommand else { return false }

        return keybind.keyCode == UInt16(kVK_Tab) || Defaults[.alternateKeybindKey] == UInt16(kVK_Tab)
    }

    private func usesCmdTabSpaceSwitcherKeybind() -> Bool {
        guard Defaults[.enableSpaceSwitcher] else { return false }
        let keybind = Defaults[.spaceSwitcherKeybind]
        let usesCommand = (keybind.modifierFlags & Int(CGEventFlags.maskCommand.rawValue)) != 0
        return usesCommand && keybind.keyCode == UInt16(kVK_Tab)
    }

    /// Exact Alt/Ctrl/Cmd match, optionally ignoring one modifier (the shared
    /// Backward Key when it is itself a modifier). Internal for testing.
    static func modifierFlagsMatch(_ saved: Int, flags: CGEventFlags, ignoring: CGEventFlags? = nil) -> Bool {
        let wantsAlt = (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0
        let wantsCtrl = (saved & Int(CGEventFlags.maskControl.rawValue)) != 0
        let wantsCmd = (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0

        return (ignoring == .maskAlternate || wantsAlt == flags.contains(.maskAlternate)) &&
            (ignoring == .maskControl || wantsCtrl == flags.contains(.maskControl)) &&
            (ignoring == .maskCommand || wantsCmd == flags.contains(.maskCommand))
    }

    /// True when every Alt/Ctrl/Cmd modifier in the saved chord is still held
    /// (extra modifiers allowed), used to keep an active switcher session alive
    /// across flagsChanged events. Internal for testing.
    static func chordModifiersHeld(_ saved: Int, flags: CGEventFlags) -> Bool {
        ((saved & Int(CGEventFlags.maskAlternate.rawValue)) == 0 || flags.contains(.maskAlternate)) &&
            ((saved & Int(CGEventFlags.maskControl.rawValue)) == 0 || flags.contains(.maskControl)) &&
            ((saved & Int(CGEventFlags.maskCommand.rawValue)) == 0 || flags.contains(.maskCommand))
    }

    private func updateModifierStatesFromFlags(event: CGEvent, keyBoardShortcutSaved: UserKeyBind) -> (currentSwitcherModifierIsPressed: Bool, currentShiftState: Bool) {
        let saved = keyBoardShortcutSaved.modifierFlags
        let wantsAlt = (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0
        let wantsCtrl = (saved & Int(CGEventFlags.maskControl.rawValue)) != 0
        let wantsCmd = (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0

        let flags = event.flags
        let hasAlt = flags.contains(.maskAlternate)
        let hasCtrl = flags.contains(.maskControl)
        let hasCmd = flags.contains(.maskCommand)

        let backwardFlag = Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode])
        let altMatch = backwardFlag == .maskAlternate || (wantsAlt == hasAlt)
        let ctrlMatch = backwardFlag == .maskControl || (wantsCtrl == hasCtrl)
        let cmdMatch = backwardFlag == .maskCommand || (wantsCmd == hasCmd)
        let currentSwitcherModifierIsPressed = altMatch && ctrlMatch && cmdMatch

        let currentShiftState: Bool = if let flag = backwardFlag {
            flags.contains(flag)
        } else {
            isShiftKeyPressedGeneral
        }

        return (currentSwitcherModifierIsPressed, currentShiftState)
    }

    @MainActor
    private func handleModifierEvent(currentSwitcherModifierIsPressed: Bool, currentShiftState: Bool) {
        // If system Cmd+Tab switcher is active, do not engage DockDoor's own switcher logic
        if DockObserver.isCmdTabSwitcherActive {
            guard usesCmdTabWindowSwitcherKeybind() else { return }
            DockObserver.activeInstance?.teardownCmdTabObserver()
        }
        let oldSwitcherModifierState = isSwitcherModifierKeyPressed
        let oldShiftState = isShiftKeyPressedGeneral

        isSwitcherModifierKeyPressed = currentSwitcherModifierIsPressed
        isShiftKeyPressedGeneral = currentShiftState

        if preventSwitcherHideOnRelease, !previewCoordinator.isVisible {
            preventSwitcherHideOnRelease = false
        }

        if !oldSwitcherModifierState && currentSwitcherModifierIsPressed {
            hasProcessedModifierRelease = false
        }

        let isWindowSwitcherActive = previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
        let shouldSkipShiftOnlyBackward = Defaults[.requireShiftTabToGoBack] && isWindowSwitcherActive

        // Only allow Shift-only backward cycling when the window switcher is already active.
        if !oldShiftState, currentShiftState,
           previewCoordinator.isVisible,
           isWindowSwitcherActive,
           currentSwitcherModifierIsPressed || Defaults[.preventSwitcherHide]
        {
            if !shouldSkipShiftOnlyBackward {
                Task { @MainActor in
                    await self.windowSwitchingCoordinator.handleWindowSwitching(
                        previewCoordinator: self.previewCoordinator,
                        isModifierPressed: currentSwitcherModifierIsPressed,
                        isShiftPressed: true,
                        mode: self.currentInvocationMode
                    )
                }

                if isWindowSwitcherActive {
                    heldKeyRepeatTask?.cancel()
                    heldKeyRepeatTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)

                        while !Task.isCancelled,
                              self.isShiftKeyPressedGeneral,
                              self.previewCoordinator.isVisible,
                              self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
                        {
                            await self.windowSwitchingCoordinator.handleWindowSwitching(
                                previewCoordinator: self.previewCoordinator,
                                isModifierPressed: self.isSwitcherModifierKeyPressed,
                                isShiftPressed: true,
                                mode: self.currentInvocationMode
                            )
                            try? await Task.sleep(nanoseconds: 80_000_000)
                        }
                    }
                }
            }
        }

        if oldShiftState, !currentShiftState {
            cancelHeldKeyRepeatTask()
        }

        if !Defaults[.preventSwitcherHide], !preventSwitcherHideOnRelease, !(previewCoordinator.isSearchWindowFocused) {
            if oldSwitcherModifierState, !isSwitcherModifierKeyPressed, !hasProcessedModifierRelease {
                hasProcessedModifierRelease = true
                preventSwitcherHideOnRelease = false

                windowSwitchingCoordinator.cancelPendingRender()

                Task { @MainActor in
                    if self.previewCoordinator.isVisible, self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive {
                        self.previewCoordinator.selectAndBringToFrontCurrentWindow()
                        self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                    } else if let selectedWindow = self.windowSwitchingCoordinator.selectCurrentWindow(previewCoordinator: self.previewCoordinator) {
                        selectedWindow.bringToFront()
                        selectedWindow.warpMouseToCenterIfNeeded()
                        if selectedWindow.isWindowlessApp, Defaults[.openNewWindowForWindowlessApps] {
                            WindowUtil.activateAndOpenNewWindow(app: selectedWindow.app)
                        }
                        self.previewCoordinator.hideWindow()
                    }
                }
            }
        }
    }

    private func determineActionForKeyDown(event: CGEvent) -> (shouldConsume: Bool, actionTask: (() async -> Void)?) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let keyBoardShortcutSaved: UserKeyBind = Defaults[.UserKeybind]
        let previewIsCurrentlyVisible = previewCoordinator.isVisible || switcherSessionActive

        if spaceSwitcherSessionActive {
            if let result = determineActionForSpaceSwitcherKeyDown(keyCode: keyCode, flags: flags) {
                return result
            }
            return (false, nil)
        }

        if previewIsCurrentlyVisible {
            if keyCode == kVK_Escape {
                switcherSessionActive = false
                return (true, { @MainActor in
                    self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                    self.previewCoordinator.hideWindow()
                    self.preventSwitcherHideOnRelease = false
                    self.hasProcessedModifierRelease = true
                })
            }

            if flags.contains(.maskCommand), previewCoordinator.windowSwitcherCoordinator.currIndex >= 0 {
                if let action = getActionForCmdShortcut(keyCode: keyCode) {
                    preventSwitcherHideOnRelease = true
                    return (true, { @MainActor in
                        self.previewCoordinator.performActionOnCurrentWindow(action: action)
                        if action == .quit {
                            if self.previewCoordinator.windowSwitcherCoordinator.windows.isEmpty {
                                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                                self.preventSwitcherHideOnRelease = false
                                self.hasProcessedModifierRelease = true
                            }
                        } else {
                            self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                            self.preventSwitcherHideOnRelease = false
                            self.hasProcessedModifierRelease = true
                        }
                    })
                }
            }
        }

        // Compute desired modifier press based on current event flags to avoid relying solely on flagsChanged ordering
        let wantsAlt = (keyBoardShortcutSaved.modifierFlags & Int(CGEventFlags.maskAlternate.rawValue)) != 0
        let wantsCtrl = (keyBoardShortcutSaved.modifierFlags & Int(CGEventFlags.maskControl.rawValue)) != 0
        let wantsCmd = (keyBoardShortcutSaved.modifierFlags & Int(CGEventFlags.maskCommand.rawValue)) != 0
        let hasAlt = flags.contains(.maskAlternate)
        let hasCtrl = flags.contains(.maskControl)
        let hasCmd = flags.contains(.maskCommand)
        let isDesiredModifierPressedNow = (wantsAlt == hasAlt) && (wantsCtrl == hasCtrl) && (wantsCmd == hasCmd)

        // Space Switcher activation. Checked before the window switcher's exact-match
        // guard (which returns early even when disabled) but explicitly yields to the
        // window switcher whenever both features claim the same keybind.
        if Defaults[.enableSpaceSwitcher] {
            let spaceKeybind = Defaults[.spaceSwitcherKeybind]
            if !KeybindConflicts.windowSwitcherClaims(spaceKeybind),
               !switcherSessionActive,
               !previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
               spaceKeybind.modifierFlags != 0,
               keyCode == Int64(spaceKeybind.keyCode),
               Self.modifierFlagsMatch(spaceKeybind.modifierFlags, flags: flags, ignoring: Self.backwardFlagToIgnore(for: spaceKeybind))
            {
                if WindowUtil.shouldIgnoreKeybindForFrontmostApp() {
                    DebugLogger.log("SpaceSwitcher", details: "ignored: frontmost app blacklist/fullscreen")
                    return (false, nil)
                }
                // Mission Control owns space switching while it is up: the Dock
                // ignores our synthesized gesture and the panel cannot be shown
                // reliably, so leave the chord to the system.
                if WindowSpaces.isMissionControlActive() {
                    DebugLogger.log("SpaceSwitcher", details: "ignored: Mission Control active")
                    return (false, nil)
                }
                spaceSwitcherSessionActive = true
                let backwardFlag = Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode])
                let isShiftPressed = backwardFlag.map { flags.contains($0) } ?? false
                return (true, { @MainActor in
                    self.hasProcessedSpaceModifierRelease = false
                    self.isSpaceModifierKeyPressed = true
                    await self.spaceSwitchingCoordinator.handleActivation(isShiftPressed: isShiftPressed)
                })
            }
        }

        let isExactSwitcherShortcutPressed = (isDesiredModifierPressedNow && keyCode == keyBoardShortcutSaved.keyCode) ||
            (!isDesiredModifierPressedNow && keyBoardShortcutSaved.modifierFlags == 0 && keyCode == keyBoardShortcutSaved.keyCode)

        if isExactSwitcherShortcutPressed {
            guard Defaults[.enableWindowSwitcher] else { return (false, nil) }
            if WindowUtil.shouldIgnoreKeybindForFrontmostApp() { return (false, nil) }
            switcherSessionActive = true
            return (true, {
                await self.handleKeybindActivation(
                    mode: .allWindows,
                    isModifierPressed: true,
                    isShiftPressed: flags.contains(.maskShift)
                )
            })
        }

        // Check alternate keybind (shares same modifier as primary keybind)
        if isDesiredModifierPressedNow {
            let alternateKey = Defaults[.alternateKeybindKey]
            if alternateKey != 0, keyCode == alternateKey {
                guard Defaults[.enableWindowSwitcher] else { return (false, nil) }
                if WindowUtil.shouldIgnoreKeybindForFrontmostApp() { return (false, nil) }
                switcherSessionActive = true
                let mode = Defaults[.alternateKeybindMode]
                return (true, {
                    await self.handleKeybindActivation(
                        mode: mode,
                        isModifierPressed: true,
                        isShiftPressed: flags.contains(.maskShift)
                    )
                })
            }
        }

        if previewIsCurrentlyVisible {
            if keyCode == kVK_Tab {
                let isShiftPressed = isShiftKeyPressedGeneral

                return (true, { @MainActor in
                    if self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive {
                        if !self.previewCoordinator.windowSwitcherCoordinator.hasActiveSearch {
                            let shouldGoBackward = isShiftPressed &&
                                (!Defaults[.requireShiftTabToGoBack] ||
                                    self.isSwitcherModifierKeyPressed ||
                                    Defaults[.preventSwitcherHide])

                            await self.windowSwitchingCoordinator.handleWindowSwitching(
                                previewCoordinator: self.previewCoordinator,
                                isModifierPressed: self.isSwitcherModifierKeyPressed,
                                isShiftPressed: shouldGoBackward,
                                mode: self.currentInvocationMode
                            )
                        }
                    } else {
                        self.previewCoordinator.navigateWithArrowKey(direction: .right)
                    }
                })
            }

            switch keyCode {
            case Int64(kVK_LeftArrow), Int64(kVK_RightArrow), Int64(kVK_UpArrow), Int64(kVK_DownArrow):
                if Defaults[.passArrowsThroughToSystem], flags.contains(.maskControl) {
                    return (false, nil)
                }
                let dir: ArrowDirection = switch keyCode {
                case Int64(kVK_LeftArrow):
                    .left
                case Int64(kVK_RightArrow):
                    .right
                case Int64(kVK_UpArrow):
                    .up
                default:
                    .down
                }
                return (true, { @MainActor in
                    self.previewCoordinator.navigateWithArrowKey(direction: dir)
                })
            case Int64(kVK_ANSI_H), Int64(kVK_ANSI_J), Int64(kVK_ANSI_K), Int64(kVK_ANSI_L):
                if Defaults[.enableVimMotions],
                   !previewCoordinator.isSearchWindowFocused,
                   allowsVimMotionNavigation(flags: flags, keyBoardShortcutSaved: keyBoardShortcutSaved)
                {
                    let dir: ArrowDirection = switch keyCode {
                    case Int64(kVK_ANSI_H): .left
                    case Int64(kVK_ANSI_L): .right
                    case Int64(kVK_ANSI_K): .up
                    default: .down
                    }
                    return (true, { @MainActor in
                        self.previewCoordinator.navigateWithArrowKey(direction: dir)
                    })
                }
            case Int64(Defaults[.windowSwitcherSelectionKeyCode]), Int64(kVK_ANSI_KeypadEnter):
                if previewCoordinator.windowSwitcherCoordinator.currIndex >= 0 {
                    return (true, makeEnterSelectionTask())
                }
            default:
                break
            }
        }

        if previewIsCurrentlyVisible,
           previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
           Defaults[.enableWindowSwitcherSearch],
           keyCode == Int64(Defaults[.searchTriggerKey]),
           !(previewCoordinator.isSearchWindowFocused)
        {
            return (true, { @MainActor in
                self.previewCoordinator.focusSearchWindow()
                self.preventSwitcherHideOnRelease = true
            })
        }
        if previewIsCurrentlyVisible,
           previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
           Defaults[.enableWindowSwitcherSearch],
           !(previewCoordinator.isSearchWindowFocused)
        {
            if keyCode == Int64(kVK_Delete) {
                return (true, { @MainActor in
                    var query = self.previewCoordinator.windowSwitcherCoordinator.searchQuery
                    if !query.isEmpty {
                        query.removeLast()
                        self.previewCoordinator.windowSwitcherCoordinator.searchQuery = query
                        SharedPreviewWindowCoordinator.activeInstance?.updateSearchWindow(with: query)

                        if query.isEmpty {
                            self.preventSwitcherHideOnRelease = false
                        }
                    }
                })
            }

            if !flags.contains(.maskCommand),
               let nsEvent = NSEvent(cgEvent: event),
               let characters = nsEvent.characters,
               !characters.isEmpty
            {
                let filteredChars = characters.filter { char in
                    char.isLetter || char.isNumber || char.isWhitespace ||
                        ".,!?-_()[]{}@#$%^&*+=|\\:;\"'<>/~`".contains(char)
                }
                if !filteredChars.isEmpty {
                    return (true, { @MainActor in
                        self.previewCoordinator.windowSwitcherCoordinator.searchQuery.append(contentsOf: filteredChars)
                        let newQuery = self.previewCoordinator.windowSwitcherCoordinator.searchQuery
                        SharedPreviewWindowCoordinator.activeInstance?.updateSearchWindow(with: newQuery)

                        if !newQuery.isEmpty {
                            self.preventSwitcherHideOnRelease = true
                        }
                    })
                }
            }
        }

        if previewIsCurrentlyVisible,
           previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
           keyCode == keyBoardShortcutSaved.keyCode,
           !isSwitcherModifierKeyPressed,
           keyBoardShortcutSaved.modifierFlags != 0,
           !flags.hasSuperfluousModifiers(ignoring: [Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode]) ?? .maskShift, .maskAlphaShift, .maskNumericPad])
        {
            if WindowUtil.shouldIgnoreKeybindForFrontmostApp() { return (false, nil) }
            return (true, { await self.handleKeybindActivation() })
        }

        return (false, nil)
    }

    private func allowsVimMotionNavigation(flags: CGEventFlags, keyBoardShortcutSaved: UserKeyBind) -> Bool {
        var allowedModifiers: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad]
        let saved = keyBoardShortcutSaved.modifierFlags

        if (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0 {
            allowedModifiers.insert(.maskAlternate)
        }
        if (saved & Int(CGEventFlags.maskControl.rawValue)) != 0 {
            allowedModifiers.insert(.maskControl)
        }
        if (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0 {
            allowedModifiers.insert(.maskCommand)
        }
        if let backwardFlag = Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode]) {
            allowedModifiers.insert(backwardFlag)
        }

        let activeModifiers = flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
        return activeModifiers.subtracting(allowedModifiers).isEmpty
    }

    private func makeEnterSelectionTask() -> (() async -> Void) {
        { @MainActor in
            self.preventSwitcherHideOnRelease = false

            if self.previewCoordinator.isVisible, self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive {
                self.previewCoordinator.selectAndBringToFrontCurrentWindow()
                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                return
            }

            if let selectedWindow = self.windowSwitchingCoordinator.selectCurrentWindow(previewCoordinator: self.previewCoordinator) {
                selectedWindow.bringToFront()
                selectedWindow.warpMouseToCenterIfNeeded()
                if selectedWindow.isWindowlessApp, Defaults[.openNewWindowForWindowlessApps] {
                    WindowUtil.activateAndOpenNewWindow(app: selectedWindow.app)
                }
                self.previewCoordinator.hideWindow()
            } else {
                self.previewCoordinator.selectAndBringToFrontCurrentWindow()
            }
        }
    }

    @MainActor
    private func handleKeybindActivation(
        mode: SwitcherInvocationMode = .allWindows,
        isModifierPressed: Bool? = nil,
        isShiftPressed: Bool? = nil
    ) {
        guard Defaults[.enableWindowSwitcher] else { return }
        hasProcessedModifierRelease = false
        currentInvocationMode = mode
        let modifierPressedForActivation = isModifierPressed ?? isSwitcherModifierKeyPressed
        let shiftPressedForActivation = isShiftPressed ?? isShiftKeyPressedGeneral
        if modifierPressedForActivation {
            isSwitcherModifierKeyPressed = true
        }
        isShiftKeyPressedGeneral = shiftPressedForActivation
        if Defaults[.focusSearchOnWindowSwitcherOpen], Defaults[.enableWindowSwitcherSearch] {
            preventSwitcherHideOnRelease = true
        }
        Task { @MainActor in
            await windowSwitchingCoordinator.handleWindowSwitching(
                previewCoordinator: previewCoordinator,
                isModifierPressed: modifierPressedForActivation,
                isShiftPressed: shiftPressedForActivation,
                mode: mode
            )
        }
    }

    private func determineActionForSpaceSwitcherKeyDown(keyCode: Int64, flags: CGEventFlags) -> (shouldConsume: Bool, actionTask: (() async -> Void)?)? {
        // Only consume chords whose modifiers belong to the space keybind (plus
        // shift), so foreign shortcuts like the system Cmd+Tab pass through in
        // stay-open mode instead of being hijacked.
        let saved = Defaults[.spaceSwitcherKeybind].modifierFlags
        let backwardKeyCode = Defaults[.switcherBackwardKeyCode]
        let backwardFlag = Self.eventFlagForKeyCode(backwardKeyCode)
        var allowedModifiers: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad]
        if (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0 {
            allowedModifiers.insert(.maskAlternate)
        }
        if (saved & Int(CGEventFlags.maskControl.rawValue)) != 0 {
            allowedModifiers.insert(.maskControl)
        }
        if (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0 {
            allowedModifiers.insert(.maskCommand)
        }
        if let backwardFlag {
            allowedModifiers.insert(backwardFlag)
        }
        let activeModifiers = flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
        guard activeModifiers.subtracting(allowedModifiers).isEmpty else { return nil }

        if keyCode == Int64(kVK_Escape) {
            spaceSwitcherSessionActive = false
            return (true, { @MainActor in
                self.hasProcessedSpaceModifierRelease = true
                self.spaceSwitchingCoordinator.cancel()
            })
        }

        // Shared Backward Key: a modifier (Shift by default) reverses the trigger
        // key; a regular key steps backward on its own, as in the Window Switcher.
        if keyCode == Int64(Defaults[.spaceSwitcherKeybind].keyCode) {
            let isBackward = backwardFlag.map { flags.contains($0) } ?? false
            return (true, { @MainActor in
                await self.spaceSwitchingCoordinator.handleActivation(isShiftPressed: isBackward)
            })
        }

        if backwardFlag == nil, keyCode == Int64(backwardKeyCode) {
            return (true, { @MainActor in
                await self.spaceSwitchingCoordinator.handleActivation(isShiftPressed: true)
            })
        }

        if keyCode == Int64(Defaults[.spaceSwitcherMoveWindowKeyCode]) {
            return (true, { @MainActor in
                self.spaceSwitchingCoordinator.moveFrontmostWindowToSelectedSpace()
            })
        }

        var direction: ArrowDirection? = switch keyCode {
        case Int64(kVK_LeftArrow): .left
        case Int64(kVK_RightArrow): .right
        case Int64(kVK_UpArrow): .up
        case Int64(kVK_DownArrow): .down
        default: nil
        }
        if direction == nil, Defaults[.enableVimMotions] {
            direction = switch keyCode {
            case Int64(kVK_ANSI_H): .left
            case Int64(kVK_ANSI_L): .right
            case Int64(kVK_ANSI_K): .up
            case Int64(kVK_ANSI_J): .down
            default: nil
            }
        }
        if let direction {
            return (true, { @MainActor in
                self.spaceSwitchingCoordinator.navigate(direction)
            })
        }

        // Shared Selection Key (Return by default); keypad Enter always commits.
        if keyCode == Int64(Defaults[.windowSwitcherSelectionKeyCode]) || keyCode == Int64(kVK_ANSI_KeypadEnter) {
            spaceSwitcherSessionActive = false
            return (true, { @MainActor in
                self.hasProcessedSpaceModifierRelease = true
                self.spaceSwitchingCoordinator.commitSelection()
            })
        }

        return nil
    }

    @MainActor
    private func handleSpaceModifierEvent(isPressed: Bool) {
        let oldState = isSpaceModifierKeyPressed
        isSpaceModifierKeyPressed = isPressed

        if !oldState, isPressed {
            hasProcessedSpaceModifierRelease = false
            // Start loading previews now (or reuse the last minute's pass);
            // Tab usually follows within a beat.
            spaceSwitchingCoordinator.prewarmPreviews()
        }

        if oldState, !isPressed, !spaceSwitchingCoordinator.isSessionActive {
            spaceSwitchingCoordinator.modifierReleasedBeforeSession()
        }

        if oldState, !isPressed, !hasProcessedSpaceModifierRelease {
            hasProcessedSpaceModifierRelease = true
            // Stay-open mode: releasing the modifier leaves the switcher up;
            // Enter/click commits, Escape or clicking outside dismisses.
            guard !Defaults[.spaceSwitcherStayOpenOnRelease] else { return }
            if spaceSwitchingCoordinator.isSessionActive {
                spaceSwitchingCoordinator.commitSelection()
            }
        }
    }

    /// Returns the action for a Cmd+key shortcut if the keyCode matches any configured shortcut
    private func getActionForCmdShortcut(keyCode: Int64) -> WindowAction? {
        let shortcut1Key = Defaults[.cmdShortcut1Key]
        let shortcut2Key = Defaults[.cmdShortcut2Key]
        let shortcut3Key = Defaults[.cmdShortcut3Key]

        switch keyCode {
        case Int64(shortcut1Key):
            let action = Defaults[.cmdShortcut1Action]
            return action != .none ? action : nil
        case Int64(shortcut2Key):
            let action = Defaults[.cmdShortcut2Action]
            return action != .none ? action : nil
        case Int64(shortcut3Key):
            let action = Defaults[.cmdShortcut3Action]
            return action != .none ? action : nil
        default:
            return nil
        }
    }
}

/// Re-enables a disabled event tap and returns a passthrough result, or nil if the event type is not tap-disabled.
func reEnableIfNeeded(tap: CFMachPort?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return nil }
    if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    return Unmanaged.passUnretained(event)
}

extension CGEventFlags {
    func hasSuperfluousModifiers(ignoring: CGEventFlags = []) -> Bool {
        let significantModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let relevantToCheck = significantModifiers.subtracting(ignoring)
        return !intersection(relevantToCheck).isEmpty
    }
}
