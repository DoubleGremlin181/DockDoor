import AppKit
import Defaults

/// Keeps an unplugged display's desktops apart on the remaining display and
/// moves the windows back when it returns. Nothing is polled: the memory is
/// the Space Switcher's learned window→space map plus the per-display space
/// list and window frames it notes whenever it reads the spaces anyway.
/// Only windows that learning has seen are remembered; desktops are never
/// created or removed.
@MainActor
final class DisplayLayoutMemory {
    static let shared = DisplayLayoutMemory()

    /// Posted right before windows are moved, so an open Space Switcher
    /// session can drop its stale model.
    static let restoreWillBegin = Notification.Name("DockDoor.displayLayoutRestoreWillBegin")

    private static let moveSettle: UInt64 = 150_000_000

    private(set) var store: DisplayLayoutStore
    private(set) var isRunning = false
    private let sessionToken = DisplayLayoutStore.currentSessionToken()

    private var observer: DisplayReconfigurationObserver?
    private var defaultsTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    /// The learned map and space table as they stood when a reconfiguration
    /// began — before the switcher's relearn prunes desktops that just died.
    private var learnedAtChange: [CGWindowID: Set<CGSSpaceID>]?
    private var tableAtChange: [String: DisplaySpacesRecord]?
    /// Window → (display it was on, frame relative to that display), from
    /// the same passes that feed the learned map. In memory only, so a
    /// display that returns after a relaunch is restored with relative
    /// placement; the relevant entries are persisted with a pending restore.
    private var frames: [CGWindowID: (displayKey: String, relative: CGRect)] = [:]
    private var framesAtChange: [CGWindowID: (displayKey: String, relative: CGRect)]?
    private var restoringKeys: Set<String> = []

    private init() {
        store = DisplayLayoutStore.load()
        defaultsTask = Task { @MainActor [weak self] in
            for await enabled in Defaults.updates(.spaceSwitcherRememberDisplayLayouts) {
                guard let self else { return }
                if enabled { start() } else { stop() }
            }
        }
    }

    var isSupported: Bool { NSScreen.screensHaveSeparateSpaces }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        DebugLogger.log("DisplayLayoutMemory", details: "start session=\(sessionToken) supported=\(isSupported)")

        SpaceSwitcherEngine.startLearning()
        let observer = DisplayReconfigurationObserver(signatureProvider: { SpaceTopology.shared.displays().signature })
        observer.busyProvider = { Self.isBusy() }
        observer.onCapturePreChange = { [weak self] in self?.capturePreChange() }
        observer.onAct = { [weak self] change in self?.act(on: change) }
        observer.onIdle = { [weak self] in
            guard let self else { return }
            learnedAtChange = nil
            framesAtChange = nil
            tableAtChange = nil
            // The table could not be updated while the burst was in flight.
            note(spaces: SpaceTopology.shared.spaces().displays, frames: [:])
        }
        observer.start()
        self.observer = observer

        synthesizePendingForAbsentDisplays()
        // A display that came back while DockDoor was not running still has
        // its pending restore; give the window cache a moment, then run it.
        actionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            await restoreNow()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        observer?.stop()
        observer = nil
        actionTask?.cancel()
        flush()
        DebugLogger.log("DisplayLayoutMemory", details: "stop")
    }

    func flush() {
        store.save()
    }

    func forgetAll() {
        store = DisplayLayoutStore()
        DisplayLayoutStore.clear()
        DebugLogger.log("DisplayLayoutMemory", details: "forgot all layouts")
    }

    // MARK: - Space table and frames

    /// Called by the Space Switcher whenever it has just read the spaces
    /// (space changes, learning passes, opening the switcher), with the CG
    /// frames of the windows it attributed to a single Space. Records each
    /// attached display's desktops (a no-op unless something changed) and
    /// the frames relative to the display they sit on.
    func note(spaces displays: [DisplaySpaces], frames cgFrames: [CGWindowID: CGRect]) {
        guard isRunning, isSupported, observer?.coalescer.isIdle ?? true, restoringKeys.isEmpty else { return }
        let table = SpaceTopology.shared.displays()
        var changed = false
        let now = Date()
        for display in displays {
            guard let record = DisplaySpacesRecord(display, identities: table, sessionToken: sessionToken, at: now) else { continue }
            if store.pending[record.identity.key] != nil { continue }
            if store.note(record) {
                changed = true
            }
        }
        if changed {
            store.save()
            DebugLogger.log("DisplayLayoutMemory", details: "space table: \(describeTable())")
        }

        for (wid, frame) in cgFrames {
            guard let probe = table.probe(containing: CGPoint(x: frame.midX, y: frame.midY)),
                  let identity = table.identities[probe.displayID]
            else { continue }
            frames[wid] = (identity.key, frame.offsetBy(dx: -probe.bounds.minX, dy: -probe.bounds.minY))
        }
        if frames.count > 2000 {
            let alive = Set(SpaceSwitcherEngine.learnedSnapshot().keys)
            frames = frames.filter { alive.contains($0.key) }
        }
    }

    private func capturePreChange() {
        learnedAtChange = SpaceSwitcherEngine.learnedSnapshot()
        framesAtChange = frames
        tableAtChange = store.displays
        DebugLogger.log("DisplayLayoutMemory", details: "reconfiguration began; learned=\(learnedAtChange?.count ?? 0) windows, table: \(describeTable())")
    }

    /// DockDoor started (or the feature was switched on) while a remembered
    /// display is absent: treat it as removed now. Only useful within the
    /// login session that learned the windows.
    private func synthesizePendingForAbsentDisplays() {
        let attachedKeys = SpaceTopology.shared.displays().attachedKeys
        let absent = store.displays.filter { !attachedKeys.contains($0.key) && store.pending[$0.key] == nil }
        guard !absent.isEmpty else { return }
        // Read the learned map before capturing: capture rebuilds the
        // switcher model, which relearns folded windows onto the host.
        let learned = SpaceSwitcherEngine.learnedSnapshot()
        let live = LiveState.capture()
        for (key, record) in absent {
            let plan = DisplayLayoutReconciler.planDisconnect(
                record: record,
                learned: learned,
                preexistingSpaceUUIDs: preexistingSpaceUUIDs(excluding: key, table: store.displays),
                after: live,
                useEmptyDesktops: false,
                sessionToken: record.sessionToken
            )
            store.pending[key] = plan.pending
            DebugLogger.log("DisplayLayoutMemory", details: "synthesized pending restore for absent \(record.identity.localizedName) [\(key)]: migrations=\(plan.pending.migrations) windows=\(plan.pending.windowsBySpace)")
        }
        store.save()
    }

    private func preexistingSpaceUUIDs(excluding key: String, table: [String: DisplaySpacesRecord]) -> Set<String> {
        Set(table.values.filter { $0.identity.key != key }.flatMap { $0.spaces.map(\.uuid) })
    }

    // MARK: - Reconfiguration

    private func act(on change: DisplayReconfigurationObserver.Change) {
        actionTask?.cancel()
        let observer = observer
        actionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await process(change)
            observer?.finishAction()
        }
    }

    private func process(_ change: DisplayReconfigurationObserver.Change) async {
        defer {
            learnedAtChange = nil
            framesAtChange = nil
            tableAtChange = nil
        }
        DebugLogger.log("DisplayLayoutMemory", details: "displays changed: removed=\(change.removed.sorted()) added=\(change.added.sorted()) separateSpaces=\(change.current.separateSpaces)")
        guard change.current.separateSpaces else {
            DebugLogger.log("DisplayLayoutMemory", details: "displays do not have separate Spaces; nothing to do")
            return
        }

        if !change.removed.isEmpty {
            // Read the learned map before capturing: capture rebuilds the
            // switcher model, which relearns folded windows onto the host.
            let learned = learnedAtChange ?? SpaceSwitcherEngine.learnedSnapshot()
            for key in change.removed.sorted() {
                // Fresh capture per display: the previous removal's un-fold
                // may have taken the empty desktop this one would choose.
                await handleRemoval(of: key, learned: learned, after: LiveState.capture())
                if Task.isCancelled { return }
            }
            store.save()
        }

        for key in change.added.sorted() where store.pending[key] != nil {
            await restore(displayKey: key)
            if Task.isCancelled { return }
        }
        store.save()
    }

    private func handleRemoval(of key: String, learned: [CGWindowID: Set<CGSSpaceID>], after live: LiveState) async {
        let table = tableAtChange ?? store.displays
        guard let record = table[key] else {
            DebugLogger.log("DisplayLayoutMemory", details: "removed display \(key) has no remembered desktops")
            return
        }
        let plan = DisplayLayoutReconciler.planDisconnect(
            record: record,
            learned: learned,
            preexistingSpaceUUIDs: preexistingSpaceUUIDs(excluding: key, table: table),
            after: live,
            useEmptyDesktops: Defaults[.spaceSwitcherKeepUnpluggedDesktopsSeparate],
            frames: (framesAtChange ?? frames).filter { $0.value.displayKey == key }.mapValues(\.relative),
            sessionToken: record.sessionToken
        )
        store.displays[key] = record
        store.pending[key] = plan.pending
        DebugLogger.log("DisplayLayoutMemory", details: "removed \(record.identity.localizedName) [\(key)]: host=\(plan.pending.hostDisplayKey) windows=\(plan.pending.windowsBySpace) frames=\(plan.pending.frames.count) migrations=\(plan.pending.migrations) ops=\(plan.operations) notes=\(plan.notes)")
        let moved = await execute(plan.operations)
        var moves: [CGWindowID: CGSSpaceID] = [:]
        for case let .moveWindows(ids, target) in plan.operations {
            for id in ids where moved.contains(id) {
                moves[id] = target
            }
        }
        integrateMoves(moves)
    }

    private func restore(displayKey key: String) async {
        guard let pending = store.pending[key] else { return }
        restoringKeys.insert(key)
        defer { restoringKeys.remove(key) }

        let live = LiveState.capture()
        let plan = DisplayLayoutReconciler.planReconnect(pending: pending, live: live, sessionToken: sessionToken)
        DebugLogger.log("DisplayLayoutMemory", details: "restore \(pending.record.identity.localizedName) [\(key)]: assignments=\(plan.assignments) moves=\(plan.moves) skipped=\(plan.skipped) ops=\(plan.operations) notes=\(plan.notes)")
        // Nothing to assign yet (the display's Spaces not populated): keep
        // the pending for the next display event.
        let hasUserDesktops = pending.record.spaces.contains { !$0.isFullscreen }
        guard !plan.assignments.isEmpty || !hasUserDesktops else {
            DebugLogger.log("DisplayLayoutMemory", details: "restore of \(key) deferred; pending kept")
            return
        }

        NotificationCenter.default.post(name: Self.restoreWillBegin, object: nil)
        let moved = await execute(plan.operations)
        integrateMoves(plan.moves.filter { moved.contains($0.key) })

        // Restored: every attached display's desktops are whatever they have now.
        store.pending.removeValue(forKey: key)
        let identities = SpaceTopology.shared.displays()
        for display in SpaceTopology.shared.spaces().displays {
            if let record = DisplaySpacesRecord(display, identities: identities, sessionToken: sessionToken), store.pending[record.identity.key] == nil {
                store.note(record)
            }
        }
        store.save()
    }

    /// Restores every attached display that still has a pending restore
    /// (one that returned while DockDoor was not running, or the debug button).
    func restoreNow() async {
        let attached = SpaceTopology.shared.displays().attachedKeys
        for key in store.pending.keys.sorted() where attached.contains(key) {
            await restore(displayKey: key)
        }
    }

    // MARK: - Execution

    /// Runs operations in order; returns the windows actually moved.
    private func execute(_ operations: [DisplayLayoutReconciler.Operation]) async -> Set<CGWindowID> {
        var moved: Set<CGWindowID> = []
        let cid = CGSMainConnectionID()
        for operation in operations {
            if Task.isCancelled { break }
            switch operation {
            case let .moveWindows(ids, target):
                let onTarget = Set(CGSCopyWindowsForSpace(cid, target))
                let needed = ids.filter { !onTarget.contains($0) }
                guard !needed.isEmpty else { continue }
                if WindowSpaces.move(windowIDs: needed, toManagedSpace: target) {
                    moved.formUnion(needed)
                } else {
                    DebugLogger.log("DisplayLayoutMemory", details: "move of \(needed) to space \(target) failed")
                }
                try? await Task.sleep(nanoseconds: Self.moveSettle)
            case let .setFrame(id, frame):
                await setFrame(of: id, to: frame)
            }
        }
        return moved
    }

    private func setFrame(of windowID: CGWindowID, to frame: CGRect) async {
        if let current = currentFrame(of: windowID),
           abs(current.minX - frame.minX) <= 2, abs(current.minY - frame.minY) <= 2,
           abs(current.width - frame.width) <= 2, abs(current.height - frame.height) <= 2
        {
            return
        }
        guard let element = await axElement(for: windowID) else {
            DebugLogger.log("DisplayLayoutMemory", details: "no AX element for window \(windowID); frame not restored")
            return
        }
        guard let position = AXValue.from(point: frame.origin), let size = AXValue.from(size: frame.size) else { return }
        // Off the main actor: an unresponsive app holds each set for the AX
        // timeout. Position twice: apps clamp the first move to the old
        // display's bounds until the size fits, then accept the final position.
        await Task.detached(priority: .userInitiated) {
            try? element.setAttribute(kAXPositionAttribute, position)
            try? element.setAttribute(kAXSizeAttribute, size)
            try? element.setAttribute(kAXPositionAttribute, position)
        }.value
    }

    private func currentFrame(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: AnyObject]] else { return nil }
        return CGRect(cgWindowBounds: list.first?[kCGWindowBounds as String])
    }

    private func axElement(for windowID: CGWindowID) async -> AXUIElement? {
        if let info = WindowUtil.cachedWindowsUnfiltered().first(where: { $0.id == windowID }) {
            return info.axElement
        }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: AnyObject]],
              let pid = (list.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        else { return nil }
        let app = AXUIElementCreateApplication(pid_t(pid))
        return await Task.detached(priority: .userInitiated) { () -> AXUIElement? in
            guard let windows = try? app.attribute(kAXWindowsAttribute, [AXUIElement].self) else { return nil }
            return windows.first { (try? $0.cgWindowId()) == windowID }
        }.value
    }

    /// Keeps the Space Switcher and the window cache consistent with moves
    /// CGS will not report for a while.
    private func integrateMoves(_ moves: [CGWindowID: CGSSpaceID]) {
        guard !moves.isEmpty else { return }
        SpaceSwitcherEngine.recordExternalMoves(moves)
        let cached = WindowUtil.cachedWindowsUnfiltered()
        for (wid, space) in moves {
            if let info = cached.first(where: { $0.id == wid }) {
                WindowUtil.updateCachedWindowState(info, spaceID: .some(Int(space)))
            }
        }
        Task.detached(priority: .low) {
            await WindowUtil.updateAllWindowsInCurrentSpace()
        }
    }

    // MARK: - Probes

    /// True while the window server is mid-transition: a display animating
    /// a space change, Mission Control up, or Accessibility not yet granted.
    private static func isBusy() -> Bool {
        guard AXIsProcessTrusted() else { return true }
        if WindowSpaces.isMissionControlActive() { return true }
        // Note: SLSManagedDisplayIsAnimating was observed false during both
        // gesture and focus-driven switches on macOS 26; kept as a cheap guard.
        let cid = CGSMainConnectionID()
        return SpaceTopology.shared.spaces().displays.contains { CGSManagedDisplayIsAnimating(cid, $0.identifier) }
    }

    // MARK: - Diagnostics

    struct RememberedDisplaySummary: Identifiable {
        let id: String
        let name: String
        let desktopCount: Int
        let updatedAt: Date
        let isPending: Bool
    }

    var summaries: [RememberedDisplaySummary] {
        store.displays.values.sorted { $0.updatedAt > $1.updatedAt }.map { record in
            RememberedDisplaySummary(
                id: record.identity.key,
                name: record.identity.localizedName.isEmpty ? record.identity.key : record.identity.localizedName,
                desktopCount: record.spaces.count,
                updatedAt: record.updatedAt,
                isPending: store.pending[record.identity.key] != nil
            )
        }
    }

    private func describeTable() -> String {
        store.displays.values.sorted { $0.identity.key < $1.identity.key }.map { record in
            "\(record.identity.localizedName)<\(record.identity.key)>: " + record.spaces.map { "\($0.id)\($0.wasCurrent ? "*" : "")\($0.isFullscreen ? "F" : "")" }.joined(separator: " ")
        }.joined(separator: " | ")
    }
}
