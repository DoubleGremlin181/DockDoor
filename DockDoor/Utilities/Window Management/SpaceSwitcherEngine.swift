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
    }

    private static let minWindowSize = CGSize(width: 80, height: 50)

    /// Memory of window→space attribution. CGSCopySpacesForWindows returns []
    /// for windows on inactive spaces on modern macOS, so every authoritative
    /// attribution (CGS answer, onscreen containment) is recorded here to keep
    /// non-current spaces populated after they've been seen once. Persisted so
    /// app relaunches start warm (window IDs are stable while windows live;
    /// dead entries are ignored because only enumerated windows are looked up).
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

    /// Cheap learning pass run on every native space change: records fresh CGS
    /// attributions for onscreen windows so previews stay complete from normal
    /// use of the machine, not just from opening the switcher. Also prunes
    /// entries that reference deleted spaces.
    @MainActor
    static func learnVisibleWindows() {
        let displays = WindowSpaces.displaySpacesSnapshot()
        DisplayLayoutMemory.shared.noteSpaces(displays)
        let knownSpaceIDs = Set(displays.flatMap { $0.spaces.map(\.id) })
        guard !knownSpaceIDs.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]]
        else { return }

        var frames: [CGWindowID: CGRect] = [:]
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            let wid = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            let fresh = Set(wid.cgsSpaces().filter { knownSpaceIDs.contains($0) })
            if !fresh.isEmpty, learnedSpaces[wid] != fresh {
                learnedSpaces[wid] = fresh
                learnedDirty = true
            }
            if fresh.count == 1, let bounds = entry[kCGWindowBounds as String] as? [String: AnyObject] {
                frames[wid] = CGRect(
                    x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                    y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                    width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                    height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                )
            }
        }
        DisplayLayoutMemory.shared.noteFrames(frames)

        let pruned = learnedSpaces.filter { !$0.value.intersection(knownSpaceIDs).isEmpty }
        if pruned.count != learnedSpaces.count {
            learnedSpaces = pruned
            learnedDirty = true
        }
        persistLearnedIfNeeded()
    }

    /// Copy of the learned map for display layout memory.
    @MainActor
    static func learnedSnapshot() -> [CGWindowID: Set<CGSSpaceID>] {
        learnedSpaces
    }

    /// Pins windows moved outside a switcher session (display layout restore)
    /// to their new space: CGS reports an empty space list for a while after
    /// SLSMoveWindowsToManagedSpace, which would otherwise drop them from
    /// every card until the next learning pass sees them onscreen.
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
    /// thumbnails, titles, and AX handles where available.
    ///
    /// `attributionOverrides` pins windows the session just moved to their
    /// target space: CGS reports an empty space list for a while after
    /// SLSMoveWindowsToManagedSpace, which would otherwise make the moved
    /// window vanish from every card (unseeable and un-undoable).
    @MainActor
    static func buildModel(attributionOverrides: [CGWindowID: CGSSpaceID] = [:]) -> Model {
        let displays = WindowSpaces.displaySpacesSnapshot(order: Defaults[.spaceSwitcherDisplayOrder])
        DisplayLayoutMemory.shared.noteSpaces(displays)
        let knownSpaceIDs = Set(displays.flatMap { $0.spaces.map(\.id) })
        let currentSpaceIDs = Set(displays.compactMap(\.currentSpaceID))

        var cachedByID: [CGWindowID: WindowInfo] = [:]
        for info in WindowUtil.getAllWindowsOfAllApps() where !info.isWindowlessApp {
            cachedByID[info.id] = info
        }

        var windowsBySpace: [CGSSpaceID: [SpaceWindow]] = [:]
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else {
            return Model(displays: displays, windowsBySpace: [:])
        }

        let spacesByWindow = perSpaceWindowMap(for: displays)
        var frames: [CGWindowID: CGRect] = [:]

        for entry in list {
            guard let candidate = windowCandidate(from: entry, cachedByID: cachedByID) else { continue }

            var fresh = Array(spacesByWindow[candidate.wid] ?? [])
            if fresh.isEmpty {
                fresh = candidate.wid.cgsSpaces().filter { knownSpaceIDs.contains($0) }
            }
            guard let attribution = resolveAttribution(
                fresh: fresh,
                moveOverride: attributionOverrides[candidate.wid],
                onscreenCurrentSpaceID: candidate.isOnscreen ? currentSpaceID(containing: candidate.frame, in: displays) : nil,
                learned: learnedSpaces[candidate.wid],
                cachedSpaceID: candidate.info?.spaceID.map { CGSSpaceID($0) },
                knownSpaceIDs: knownSpaceIDs
            ) else { continue }

            let hasTitle = (candidate.cgTitle?.isEmpty == false) || (candidate.info?.windowName?.isEmpty == false)
            switch ghostFilterVerdict(
                spaces: attribution.spaces,
                isOnscreen: candidate.isOnscreen,
                currentSpaceIDs: currentSpaceIDs,
                isKnownToDiscovery: candidate.info != nil,
                hasTitle: hasTitle
            ) {
            case .rejectAndUnlearn:
                if learnedSpaces.removeValue(forKey: candidate.wid) != nil {
                    learnedDirty = true
                }
                continue
            case .reject:
                continue
            case .accept:
                break
            }

            if attribution.isAuthoritative, learnedSpaces[candidate.wid] != Set(attribution.spaces) {
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
        DisplayLayoutMemory.shared.noteFrames(frames)
        return Model(displays: displays, windowsBySpace: windowsBySpace)
    }

    /// Authoritative wid→spaces map straight from the window server: unlike
    /// CGSCopySpacesForWindows, the per-space window-list query answers for
    /// NON-current spaces too.
    private static func perSpaceWindowMap(for displays: [DisplaySpaces]) -> [CGWindowID: Set<CGSSpaceID>] {
        var spacesByWindow: [CGWindowID: Set<CGSSpaceID>] = [:]
        for display in displays {
            for space in display.spaces {
                for wid in CGSCopyWindowsForSpace(CGSMainConnectionID(), space.id) {
                    spacesByWindow[wid, default: []].insert(space.id)
                }
            }
        }
        return spacesByWindow
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
    private static func windowCandidate(from entry: [String: AnyObject], cachedByID: [CGWindowID: WindowInfo]) -> Candidate? {
        guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        let pid = pid_t((entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)

        let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
        guard alpha > 0.01 else { return nil }

        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: AnyObject] else { return nil }
        let frame = CGRect(
            x: (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0,
            y: (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0,
            width: (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0,
            height: (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
        )
        guard frame.width >= minWindowSize.width, frame.height >= minWindowSize.height else { return nil }

        let wid = CGWindowID((entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        let info = cachedByID[wid]
        if let info, info.isMinimized || info.isHidden {
            return nil
        }

        let app = NSRunningApplication(processIdentifier: pid)
        // Filter system/overlay noise (Spotlight, loginwindow, menu-bar app
        // popovers): only regular apps, unless DockDoor's own discovery
        // already accepted the window.
        guard app?.activationPolicy == .regular || info != nil else { return nil }
        // Match the Window Switcher's hidden-app behavior
        if app?.isHidden == true, !Defaults[.includeHiddenWindowsInSwitcher] {
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

    private static func currentSpaceID(containing frame: CGRect, in displays: [DisplaySpaces]) -> CGSSpaceID? {
        displays.first(where: { display in
            guard let screen = display.screen else { return false }
            return screen.cgFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
        })?.currentSpaceID
    }

    struct Attribution: Equatable {
        let spaces: [CGSSpaceID]
        let isSticky: Bool
        /// From a live CGS answer — safe to record in the learned map
        let isAuthoritative: Bool
    }

    /// Attribution chain: fresh CGS answer → session move override → onscreen
    /// containment → learned map → cached discovery spaceID. The onscreen rule
    /// covers follow-the-active-space windows (some Electron apps): shown on
    /// the current space but sticky (never a switch target) and never learned,
    /// or they'd get pinned to whatever space happened to be active.
    /// Internal for testing.
    static func resolveAttribution(
        fresh: [CGSSpaceID],
        moveOverride: CGSSpaceID?,
        onscreenCurrentSpaceID: CGSSpaceID?,
        learned: Set<CGSSpaceID>?,
        cachedSpaceID: CGSSpaceID?,
        knownSpaceIDs: Set<CGSSpaceID>
    ) -> Attribution? {
        if !fresh.isEmpty {
            return Attribution(spaces: fresh, isSticky: fresh.count > 1, isAuthoritative: true)
        }
        if let moveOverride, knownSpaceIDs.contains(moveOverride) {
            return Attribution(spaces: [moveOverride], isSticky: true, isAuthoritative: false)
        }
        if let onscreenCurrentSpaceID {
            return Attribution(spaces: [onscreenCurrentSpaceID], isSticky: true, isAuthoritative: false)
        }
        if let learned {
            let valid = learned.filter { knownSpaceIDs.contains($0) }
            if !valid.isEmpty {
                return Attribution(spaces: Array(valid), isSticky: valid.count > 1, isAuthoritative: false)
            }
        }
        if let cachedSpaceID, knownSpaceIDs.contains(cachedSpaceID) {
            return Attribution(spaces: [cachedSpaceID], isSticky: false, isAuthoritative: false)
        }
        return nil
    }

    enum GhostFilterVerdict: Equatable {
        case accept
        /// Invisible helper surface; its stale learned attribution should be dropped
        case rejectAndUnlearn
        case reject
    }

    /// Ghost filters (mirror upstream shouldAcceptWindow). A window whose
    /// attributed spaces are all currently visible yet is not onscreen is an
    /// invisible helper surface — it would render as a black box. Offscreen
    /// windows on other spaces must be vouched for: known to DockDoor's
    /// AX-vetted discovery or carrying a real title; untitled unknowns are
    /// transparent helper surfaces (Electron apps park them on spaces) that
    /// capture as faint empty outlines. Internal for testing.
    static func ghostFilterVerdict(
        spaces: [CGSSpaceID],
        isOnscreen: Bool,
        currentSpaceIDs: Set<CGSSpaceID>,
        isKnownToDiscovery: Bool,
        hasTitle: Bool
    ) -> GhostFilterVerdict {
        if !isOnscreen, spaces.allSatisfy({ currentSpaceIDs.contains($0) }) {
            return .rejectAndUnlearn
        }
        if !isOnscreen, !isKnownToDiscovery, !hasTitle {
            return .reject
        }
        return .accept
    }

    /// Monotonic commit counter so a stale verify task never fights a newer commit
    @MainActor private static var commitGeneration = 0

    /// "When switching to an application, switch to a Space with open windows"
    /// (System Settings → Desktop & Dock). On by default; when off, focusing a
    /// window on another Space does not switch to it.
    static var switchesSpaceOnActivation: Bool {
        (CFPreferencesCopyAppValue("workspaces-auto-swoosh" as CFString, "com.apple.dock" as CFString) as? Bool) ?? true
    }

    @MainActor
    static func switchTo(space: SpaceInfo, in model: Model) {
        // Resolve current state freshly at commit time: the user may have
        // switched spaces natively (trackpad swipe) while the panel was open.
        let freshDisplays = WindowSpaces.displaySpacesSnapshot()
        guard let display = freshDisplays.first(where: { $0.identifier == space.displayIdentifier }) else { return }
        guard display.currentSpaceID != space.id else {
            DebugLogger.log("SpaceSwitcherEngine", details: "switchTo: space \(space.id) already current")
            return
        }

        commitGeneration += 1
        let generation = commitGeneration
        let originSpaceID = display.currentSpaceID
        let focusTarget = model.windowsBySpace[space.id]?.first(where: { !$0.isSticky && $0.info != nil })?.info

        // Primary for non-empty Spaces: focus its frontmost window — macOS
        // jumps straight to that Space in one slide, however far away it is,
        // and the Dock stays in sync because it is an ordinary activation.
        // Empty Spaces have nothing to focus, so they take the Dock-swipe
        // gesture, one step per Space.
        if let focusTarget, switchesSpaceOnActivation {
            focusTarget.bringToFront()
            verifySwitch(space: space, generation: generation, originSpaceID: originSpaceID, after: 500_000_000) {
                DebugLogger.log("SpaceSwitcherEngine", details: "focus did not switch; gesture fallback to \(space.id)")
                gestureThenVerify(space: space, generation: generation, originSpaceID: originSpaceID, focusTarget: nil)
            }
        } else {
            gestureThenVerify(space: space, generation: generation, originSpaceID: originSpaceID, focusTarget: focusTarget)
        }

        Task.detached(priority: .low) {
            await WindowUtil.updateAllWindowsInCurrentSpace()
        }
    }

    @MainActor
    private static func gestureThenVerify(space: SpaceInfo, generation: Int, originSpaceID: CGSSpaceID?, focusTarget: WindowInfo?) {
        let freshDisplays = WindowSpaces.displaySpacesSnapshot()
        guard let display = freshDisplays.first(where: { $0.identifier == space.displayIdentifier }) else { return }
        WindowSpaces.switchViaDockGesture(
            to: space,
            on: display,
            keepCursor: Defaults[.spaceSwitcherWarpCursor]
        )
        // Each animated step takes ~0.4 s; verify once the whole walk had time to land.
        let currentIndex = display.spaces.firstIndex { $0.id == display.currentSpaceID } ?? 0
        let targetIndex = display.spaces.firstIndex { $0.id == space.id } ?? currentIndex
        let walk = UInt64(max(1, abs(targetIndex - currentIndex))) * 400_000_000
        verifySwitch(space: space, generation: generation, originSpaceID: originSpaceID, after: walk + 600_000_000) {
            if let focusTarget {
                DebugLogger.log("SpaceSwitcherEngine", details: "gesture did not switch; bringToFront fallback wid=\(focusTarget.id)")
                focusTarget.bringToFront()
            } else {
                DebugLogger.log("SpaceSwitcherEngine", details: "gesture did not switch; CGS fallback to \(space.id)")
                WindowSpaces.setCurrentSpace(space.id, onDisplay: space.displayIdentifier)
            }
        }
    }

    /// Runs `fallback` if, after the delay, the display is still on the
    /// origin Space. Bails if a newer commit exists or the user navigated on
    /// their own — never yank them around.
    @MainActor
    private static func verifySwitch(space: SpaceInfo, generation: Int, originSpaceID: CGSSpaceID?, after nanoseconds: UInt64, fallback: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard generation == commitGeneration else { return }
            let displays = WindowSpaces.displaySpacesSnapshot()
            guard let current = displays.first(where: { $0.identifier == space.displayIdentifier }),
                  current.currentSpaceID != space.id,
                  current.currentSpaceID == originSpaceID
            else { return }
            fallback()
        }
    }

    static func fullscreenAppName(for space: SpaceInfo, in model: Model) -> String? {
        guard space.isFullscreen else { return nil }
        return model.windowsBySpace[space.id]?.first?.appName
    }
}
