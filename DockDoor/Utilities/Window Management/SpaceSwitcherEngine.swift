import AppKit
import Defaults

enum SpaceSwitcherEngine {
    struct SpaceWindow: Identifiable {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let title: String?
        let appName: String?
        let icon: NSImage?
        let image: CGImage?
        /// On multiple spaces, or space attribution unreliable — never a switch target
        let isSticky: Bool
        /// Cached DockDoor entry when known; required for focus-based switching
        let info: WindowInfo?
    }

    struct Model {
        let displays: [DisplaySpaces]
        /// Buckets are in z-order, frontmost first
        let windowsBySpace: [CGSSpaceID: [SpaceWindow]]

        var allSpaces: [SpaceInfo] {
            displays.flatMap(\.spaces)
        }

        /// Same model with fresh thumbnails swapped in for the given windows.
        func replacingImages(_ images: [CGWindowID: CGImage]) -> Model {
            guard !images.isEmpty else { return self }
            var updated = windowsBySpace
            for (spaceID, windows) in updated {
                updated[spaceID] = windows.map { window in
                    guard let image = images[window.id] else { return window }
                    return SpaceWindow(
                        id: window.id, pid: window.pid, frame: window.frame, title: window.title, appName: window.appName,
                        icon: window.icon, image: image, isSticky: window.isSticky, info: window.info
                    )
                }
            }
            return Model(displays: displays, windowsBySpace: updated)
        }
    }

    private static let minWindowSize = CGSize(width: 80, height: 50)

    /// Where each window lived, as last reported by the window server. Not an
    /// attribution source for the switcher (the live answer is always used);
    /// it is the record Display Layout Memory reads when a display goes away
    /// and its Spaces are gone. Persisted so relaunches start warm (window IDs
    /// are stable while windows live; dead entries are ignored because only
    /// enumerated windows are looked up).
    private static let learnedStore = Defaults.Key<Data>("spaceSwitcherLearnedSpaces", default: Data())

    @MainActor private static var learnedSpaces: [CGWindowID: Set<CGSSpaceID>] = (try? JSONDecoder().decode([CGWindowID: Set<CGSSpaceID>].self, from: Defaults[learnedStore])) ?? [:]

    @MainActor private static var learnedDirty = false

    @MainActor private static func persistLearnedIfNeeded() {
        guard learnedDirty else { return }
        learnedDirty = false
        if let data = try? JSONEncoder().encode(learnedSpaces) {
            Defaults[learnedStore] = data
        }
    }

    /// Space-table generation the last `buildModel` ran against: a learning
    /// pass for the same generation has nothing new to see.
    @MainActor private static var lastModelSpaceGeneration: UInt64?
    @MainActor private static var learningSubscription: UUID?
    @MainActor private static var relearnTask: Task<Void, Never>?

    /// Learns from normal Space usage so previews and display layout memory
    /// are complete without the switcher ever being opened. Idempotent and
    /// shared: either the Space Switcher or display layout memory alone
    /// keeps the map warm.
    @MainActor
    static func startLearning() {
        guard learningSubscription == nil else { return }
        learningSubscription = SpaceTopology.shared.subscribe { event in
            switch event {
            case .activeSpaceChanged:
                // Debounced until the switch settles
                scheduleLearning(after: 0.8)
            case .displaysChanged, .screenParametersChanged:
                // macOS migrates Spaces to new IDs; learn (and prune dead
                // IDs) once the new topology is stable.
                scheduleLearning(after: 3)
            case .displaysWillChange, .willSleep, .didWake:
                break
            }
        }
        scheduleLearning(after: 2)
    }

    @MainActor
    private static func scheduleLearning(after seconds: TimeInterval) {
        relearnTask?.cancel()
        relearnTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            learnVisibleWindows()
        }
    }

    /// Learning pass run after every native space change: records the window
    /// server's membership for every Space (it answers for non-current
    /// Spaces too, so windows opened on other desktops are covered), notes
    /// the onscreen windows' frames, and prunes entries that reference
    /// deleted Spaces. Skipped when a model build already learned this
    /// generation.
    @MainActor
    static func learnVisibleWindows() {
        let table = SpaceTopology.shared.spaces()
        let knownSpaceIDs = table.knownSpaceIDs
        guard !knownSpaceIDs.isEmpty else { return }

        var frames: [CGWindowID: CGRect] = [:]
        if lastModelSpaceGeneration != table.generation {
            let membership = SpaceTopology.shared.membership(maxAge: 1)
            for (wid, spaces) in membership.spacesByWindow {
                let fresh = spaces.intersection(knownSpaceIDs)
                if !fresh.isEmpty, learnedSpaces[wid] != fresh {
                    learnedSpaces[wid] = fresh
                    learnedDirty = true
                }
            }
            if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] {
                for entry in list where (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
                    let wid = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
                    if learnedSpaces[wid]?.count == 1, let frame = CGRect(cgWindowBounds: entry[kCGWindowBounds as String]) {
                        frames[wid] = frame
                    }
                }
            }
        }

        let pruned = learnedSpaces.filter { !$0.value.intersection(knownSpaceIDs).isEmpty }
        if pruned.count != learnedSpaces.count {
            learnedSpaces = pruned
            learnedDirty = true
        }
        persistLearnedIfNeeded()
        DisplayLayoutMemory.shared.note(spaces: table.displays, frames: frames)
    }

    /// Copy of the learned map for display layout memory.
    @MainActor
    static func learnedSnapshot() -> [CGWindowID: Set<CGSSpaceID>] {
        learnedSpaces
    }

    /// Records windows moved by a display layout restore so the map is right
    /// for a reconfiguration that arrives before the next learning pass.
    @MainActor
    static func recordExternalMoves(_ moves: [CGWindowID: CGSSpaceID]) {
        for (wid, space) in moves where learnedSpaces[wid] != [space] {
            learnedSpaces[wid] = [space]
            learnedDirty = true
        }
        persistLearnedIfNeeded()
    }

    /// Builds the model from a fresh CGWindowList enumeration so frames and
    /// space assignments are current; DockDoor's window cache contributes
    /// thumbnails, titles, and AX handles where available. Space assignment
    /// comes straight from the window server (per-Space membership, then the
    /// per-window query), which answers for every Space and reflects a move
    /// immediately.
    ///
    /// `includeAll` skips the switcher's visibility filters (minimized and
    /// hidden windows): display layout memory needs every window on every
    /// desktop.
    @MainActor
    static func buildModel(includeAll: Bool = false) -> Model {
        let table = SpaceTopology.shared.spaces()
        let displays = WindowSpaces.orderedRows(from: table, order: Defaults[.spaceSwitcherDisplayOrder])
        let knownSpaceIDs = table.knownSpaceIDs
        let currentSpaceIDs = table.currentSpaceIDs

        var cachedByID: [CGWindowID: WindowInfo] = [:]
        let cached = includeAll ? WindowUtil.cachedWindowsUnfiltered() : WindowUtil.getAllWindowsOfAllApps()
        for info in cached where !info.isWindowlessApp {
            cachedByID[info.id] = info
        }

        var windowsBySpace: [CGSSpaceID: [SpaceWindow]] = [:]
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
            return Model(displays: displays, windowsBySpace: [:])
        }

        let spacesByWindow = SpaceTopology.shared.membership(maxAge: 1).spacesByWindow
        var frames: [CGWindowID: CGRect] = [:]
        var appsByPID: [pid_t: NSRunningApplication?] = [:]

        for entry in list {
            let pid = pid_t((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            if appsByPID[pid] == nil {
                appsByPID[pid] = .some(NSRunningApplication(processIdentifier: pid))
            }
            guard let candidate = windowCandidate(from: entry, app: appsByPID[pid] ?? nil, cachedByID: cachedByID, includeAll: includeAll) else { continue }

            var fresh = Array(spacesByWindow[candidate.wid] ?? [])
            if fresh.isEmpty {
                fresh = candidate.wid.cgsSpaces().filter { knownSpaceIDs.contains($0) }
            }
            guard let attribution = resolveAttribution(fresh: fresh) else { continue }

            // A minimized window is offscreen on a visible Space by definition;
            // the ghost filter would reject it.
            let isMinimized = includeAll && candidate.info?.isMinimized == true
            let hasTitle = (candidate.cgTitle?.isEmpty == false) || (candidate.info?.windowName?.isEmpty == false)
            guard isMinimized || isGhost(
                spaces: attribution.spaces,
                isOnscreen: candidate.isOnscreen,
                currentSpaceIDs: currentSpaceIDs,
                isKnownToDiscovery: candidate.info != nil,
                hasTitle: hasTitle
            ) == false else { continue }

            if learnedSpaces[candidate.wid] != Set(attribution.spaces) {
                learnedSpaces[candidate.wid] = Set(attribution.spaces)
                learnedDirty = true
            }
            let window = SpaceWindow(
                id: candidate.wid,
                pid: candidate.pid,
                frame: candidate.frame,
                title: (candidate.cgTitle?.isEmpty == false ? candidate.cgTitle : nil) ?? candidate.info?.windowName,
                appName: candidate.app?.localizedName ?? candidate.ownerName,
                icon: candidate.app?.icon,
                image: candidate.info?.image,
                isSticky: attribution.isSticky,
                info: candidate.info
            )
            for space in attribution.spaces {
                windowsBySpace[space, default: []].append(window)
            }
            if !attribution.isSticky {
                frames[candidate.wid] = candidate.frame
            }
        }

        persistLearnedIfNeeded()
        lastModelSpaceGeneration = table.generation
        DisplayLayoutMemory.shared.note(spaces: table.displays, frames: frames)
        return Model(displays: displays, windowsBySpace: windowsBySpace)
    }

    private struct Candidate {
        let wid: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let isOnscreen: Bool
        let cgTitle: String?
        let app: NSRunningApplication?
        let info: WindowInfo?
        let ownerName: String?
    }

    /// Basic eligibility filters on a raw CGWindowList entry. DockDoor's own
    /// regular windows (Settings) are included on purpose; its panels live at
    /// non-zero window levels and fail the layer filter.
    private static func windowCandidate(from entry: [String: AnyObject], app: NSRunningApplication?, cachedByID: [CGWindowID: WindowInfo], includeAll: Bool) -> Candidate? {
        guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        let pid = pid_t((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)

        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard alpha > 0.01 else { return nil }

        guard let frame = CGRect(cgWindowBounds: entry[kCGWindowBounds as String]),
              frame.width >= minWindowSize.width, frame.height >= minWindowSize.height
        else { return nil }

        let wid = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        let info = cachedByID[wid]
        if !includeAll, let info, info.isMinimized || info.isHidden {
            return nil
        }

        // Filter system/overlay noise (Spotlight, loginwindow, menu-bar app
        // popovers): only regular apps, unless DockDoor's own discovery
        // already accepted the window.
        guard app?.activationPolicy == .regular || info != nil else { return nil }
        // Match the Window Switcher's hidden-app behavior
        if !includeAll, app?.isHidden == true, !Defaults[.includeHiddenWindowsInSwitcher] {
            return nil
        }

        return Candidate(
            wid: wid,
            pid: pid,
            frame: frame,
            isOnscreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
            cgTitle: entry[kCGWindowName as String] as? String,
            app: app,
            info: info,
            ownerName: entry[kCGWindowOwnerName as String] as? String
        )
    }

    struct Attribution: Equatable {
        let spaces: [CGSSpaceID]
        /// On more than one Space — never a switch target
        let isSticky: Bool
    }

    /// The window server's answer is the only attribution source: it names
    /// every Space a window is on, for any Space, and reflects a move at once.
    /// An empty answer means the window is on no Space (an ordered-out helper
    /// surface) and is left out. Internal for testing.
    static func resolveAttribution(fresh: [CGSSpaceID]) -> Attribution? {
        guard !fresh.isEmpty else { return nil }
        return Attribution(spaces: fresh, isSticky: fresh.count > 1)
    }

    /// Ghost filters (mirror upstream shouldAcceptWindow). A window on only
    /// currently visible Spaces yet not onscreen is minimized or hidden, not
    /// something to draw — its capture would be a stale or black box. Offscreen
    /// windows on other Spaces must be vouched for: known to DockDoor's
    /// AX-vetted discovery or carrying a real title; untitled unknowns are
    /// transparent helper surfaces (Electron apps park them on Spaces) that
    /// capture as faint empty outlines. Internal for testing.
    static func isGhost(
        spaces: [CGSSpaceID],
        isOnscreen: Bool,
        currentSpaceIDs: Set<CGSSpaceID>,
        isKnownToDiscovery: Bool,
        hasTitle: Bool
    ) -> Bool {
        guard !isOnscreen else { return false }
        if spaces.allSatisfy({ currentSpaceIDs.contains($0) }) {
            return true
        }
        return !isKnownToDiscovery && !hasTitle
    }

    /// Monotonic commit counter so a stale verify task never fights a newer commit
    @MainActor private static var commitGeneration = 0

    @MainActor
    static func switchTo(space: SpaceInfo, in model: Model) {
        // Resolve current state freshly at commit time: the user may have
        // switched spaces natively (trackpad swipe) while the panel was open.
        guard let display = SpaceTopology.shared.spaces().display(for: space.displayIdentifier) else { return }
        guard display.currentSpaceID != space.id else {
            DebugLogger.log("SpaceSwitcherEngine", details: "switchTo: space \(space.id) already current")
            return
        }

        commitGeneration += 1
        // Instant Dock walk for every switch: direct landing on any desktop
        // of any display, empty or not, with the desktops in between never
        // drawn. Falls back to focusing a window on the Space.
        let focusTarget = model.windowsBySpace[space.id]?.first(where: { !$0.isSticky && $0.info != nil })?.info
        gestureThenVerify(space: space, on: display, generation: commitGeneration, originSpaceID: display.currentSpaceID, focusTarget: focusTarget, retried: false)
        // The Space change this causes is observed like any other; the window
        // cache refresh that follows it is not repeated here.
    }

    /// Number of Spaces between the current one and the target on a display
    private static func stepCount(from origin: CGSSpaceID?, to target: CGSSpaceID, on display: DisplaySpaces) -> Int {
        guard let origin,
              let from = display.spaces.firstIndex(where: { $0.id == origin }),
              let to = display.spaces.firstIndex(where: { $0.id == target })
        else { return 1 }
        return abs(to - from)
    }

    /// Spaces strictly between origin and target on a display: where a
    /// multi-step walk lands when the Dock drops a swipe.
    private static func spacesOnPath(from origin: CGSSpaceID?, to target: CGSSpaceID, on display: DisplaySpaces) -> Set<CGSSpaceID> {
        guard let origin,
              let from = display.spaces.firstIndex(where: { $0.id == origin }),
              let to = display.spaces.firstIndex(where: { $0.id == target }),
              abs(to - from) > 1
        else { return [] }
        let range = from < to ? (from + 1) ..< to : (to + 1) ..< from
        return Set(display.spaces[range].map(\.id))
    }

    @MainActor
    private static func gestureThenVerify(space: SpaceInfo, on display: DisplaySpaces?, generation: Int, originSpaceID: CGSSpaceID?, focusTarget: WindowInfo?, retried: Bool) {
        guard let display = display ?? SpaceTopology.shared.spaces().display(for: space.displayIdentifier) else { return }
        WindowSpaces.switchViaDockGesture(to: space, on: display, keepCursor: Defaults[.spaceSwitcherWarpCursor])
        let onPath = spacesOnPath(from: display.currentSpaceID, to: space.id, on: display)
        let walk = UInt64(max(1, stepCount(from: display.currentSpaceID, to: space.id, on: display))) * 40_000_000
        verifySwitch(space: space, generation: generation, originSpaceID: originSpaceID, onPath: onPath, after: 600_000_000 + walk) { landed in
            if !retried, onPath.contains(landed) {
                // Landed short: the Dock dropped a swipe. Walk the rest once.
                DebugLogger.log("SpaceSwitcherEngine", details: "gesture landed short on \(landed); re-issuing the remaining steps to \(space.id)")
                gestureThenVerify(space: space, on: nil, generation: generation, originSpaceID: landed, focusTarget: focusTarget, retried: true)
            } else if let focusTarget {
                DebugLogger.log("SpaceSwitcherEngine", details: "gesture did not switch; bringToFront fallback wid=\(focusTarget.id)")
                focusTarget.bringToFront()
            } else {
                // No window to focus and no safe direct call: the raw
                // window-server switch only rewrites bookkeeping and leaves the
                // Dock out of sync, so give up rather than desync.
                DebugLogger.log("SpaceSwitcherEngine", details: "gesture did not switch and nothing to focus on \(space.id); giving up")
            }
        }
    }

    /// Runs `fallback` if, after the delay, the display is still on the
    /// origin Space or on one of the Spaces on the way to the target. Bails
    /// if a newer commit exists or the user navigated somewhere else on
    /// their own — never yank them around.
    @MainActor
    private static func verifySwitch(space: SpaceInfo, generation: Int, originSpaceID: CGSSpaceID?, onPath: Set<CGSSpaceID>, after nanoseconds: UInt64, fallback: @escaping @MainActor (CGSSpaceID) -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard generation == commitGeneration else { return }
            guard let current = SpaceTopology.shared.spaces().display(for: space.displayIdentifier),
                  let landed = current.currentSpaceID,
                  landed != space.id,
                  landed == originSpaceID || onPath.contains(landed)
            else { return }
            fallback(landed)
        }
    }

    static func fullscreenAppName(for space: SpaceInfo, in model: Model) -> String? {
        guard space.isFullscreen else { return nil }
        return model.windowsBySpace[space.id]?.first?.appName
    }
}
