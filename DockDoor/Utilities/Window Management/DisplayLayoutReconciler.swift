import CoreGraphics
import Foundation

/// Pure planning for display layout memory, fed by the Space Switcher's
/// learned window→space map and its per-display space list. Desktops are
/// never created or removed — only windows move.
enum DisplayLayoutReconciler {
    enum Operation: Equatable {
        case moveWindows([CGWindowID], to: CGSSpaceID)
        /// CG global coordinates
        case setFrame(CGWindowID, CGRect)
    }

    struct DisconnectPlan {
        var pending: PendingRestore
        var operations: [Operation]
        var notes: [String]
    }

    struct ReconnectPlan {
        var operations: [Operation]
        /// Window → target space for every window the plan moves
        var moves: [CGWindowID: CGSSpaceID]
        /// Remembered desktop uuid → target desktop uuid
        var assignments: [String: String]
        /// Remembered windows left alone because the user placed them on a
        /// pre-existing desktop while their desktop was absent
        var skipped: [CGWindowID]
        var notes: [String]
    }

    // MARK: - Disconnect

    /// Works out where each remembered desktop of the removed display went.
    /// macOS keeps most desktops intact (same space ID) on the host and folds
    /// the rest into the host's current desktop; a folded group is pulled
    /// apart onto a free empty desktop when `useEmptyDesktops` allows it.
    static func planDisconnect(
        record: DisplaySpacesRecord,
        learned: [CGWindowID: Set<CGSSpaceID>],
        preexistingSpaceUUIDs: Set<String>,
        after: LiveState,
        useEmptyDesktops: Bool,
        frames: [CGWindowID: CGRect] = [:],
        sessionToken: String,
        now: Date = Date()
    ) -> DisconnectPlan {
        var notes: [String] = []
        let remembered = record.spaces.filter { !$0.isFullscreen }.sorted { $0.index < $1.index }
        let uuidByID = Dictionary(remembered.map { ($0.id, $0.uuid) }, uniquingKeysWith: { a, _ in a })

        // Learned membership, restricted to windows on exactly one space.
        var windowsBySpace: [String: [CGWindowID]] = [:]
        for (wid, spaceIDs) in learned where spaceIDs.count == 1 {
            if let id = spaceIDs.first, let uuid = uuidByID[id] {
                windowsBySpace[uuid, default: []].append(wid)
            }
        }
        for key in windowsBySpace.keys {
            windowsBySpace[key]?.sort()
        }
        let rememberedIDs = Set(windowsBySpace.values.flatMap { $0 })
        let rememberedFrames = frames.filter { rememberedIDs.contains($0.key) }

        // Host: the display holding most of the remembered windows; main otherwise.
        var counts: [String: Int] = [:]
        for space in after.spaces {
            let hits = space.windowIDs.filter { rememberedIDs.contains($0) }.count
            if hits > 0 { counts[space.displayKey, default: 0] += hits }
        }
        let hostKey = counts.max { a, b in (a.value, a.key) < (b.value, b.key) }?.key
            ?? after.mainDisplayKey
            ?? after.displays.keys.sorted().first
            ?? ""
        let hostSpaces = after.spaces(on: hostKey).filter { !$0.isFullscreen }

        var migrations: [String: String] = [:]
        var claimed: Set<String> = []
        var operations: [Operation] = []

        // Desktops macOS moved intact keep their space ID (or uuid).
        for space in remembered {
            if let live = hostSpaces.first(where: { ($0.uuid == space.uuid || $0.id == space.id) && !claimed.contains($0.uuid) }) {
                migrations[space.uuid] = live.uuid
                claimed.insert(live.uuid)
            }
        }

        // Folded desktops: their windows now sit on some other host desktop.
        var freeEmpty = hostSpaces.filter { $0.windowIDs.isEmpty && !$0.isCurrent && !claimed.contains($0.uuid) }
        for space in remembered where migrations[space.uuid] == nil {
            let present = (windowsBySpace[space.uuid] ?? []).filter { wid in
                guard let window = after.windows[wid], !window.isSticky else { return false }
                return after.space(containing: wid)?.displayKey == hostKey
            }
            guard !present.isEmpty else { continue }
            let landing = present.compactMap { after.space(containing: $0)?.uuid }
                .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                .max { a, b in (a.value, a.key) < (b.value, b.key) }?.key ?? "?"
            if useEmptyDesktops, !freeEmpty.isEmpty {
                let target = freeEmpty.removeFirst()
                operations.append(.moveWindows(present, to: target.id))
                migrations[space.uuid] = target.uuid
                claimed.insert(target.uuid)
                notes.append("desktop \(space.uuid) was folded into \(landing); separated onto \(target.uuid)")
            } else {
                notes.append("desktop \(space.uuid) stays folded into \(landing)")
            }
        }

        let pending = PendingRestore(
            displayKey: record.identity.key,
            record: record,
            removedAt: now,
            sessionToken: sessionToken,
            hostDisplayKey: hostKey,
            windowsBySpace: windowsBySpace,
            migrations: migrations,
            preexistingSpaceUUIDs: preexistingSpaceUUIDs,
            frames: rememberedFrames
        )
        return DisconnectPlan(pending: pending, operations: operations, notes: notes)
    }

    // MARK: - Reconnect

    /// Assigns remembered desktops onto the desktops the returning display
    /// has (same uuid or space ID first, then in order; desktops that find no
    /// room stay where macOS left them) and moves windows back: whatever now
    /// lives on each migrated desktop, plus remembered windows by ID, each
    /// placed at its remembered frame on that display.
    static func planReconnect(pending: PendingRestore, live: LiveState, sessionToken: String) -> ReconnectPlan {
        var notes: [String] = []
        guard let target = live.displays[pending.displayKey] else {
            return ReconnectPlan(operations: [], moves: [:], assignments: [:], skipped: [], notes: ["target display not live"])
        }
        let targetSpaces = live.spaces(on: pending.displayKey).filter { !$0.isFullscreen }
        guard !targetSpaces.isEmpty else {
            return ReconnectPlan(operations: [], moves: [:], assignments: [:], skipped: [], notes: ["target display has no user desktops yet"])
        }
        let remembered = pending.record.spaces.filter { !$0.isFullscreen }.sorted { $0.index < $1.index }
        let idsValid = pending.sessionToken == sessionToken

        // Desktop assignment.
        var assignments: [String: String] = [:]
        var taken: Set<String> = []
        for space in remembered {
            if let prior = pending.assignments[space.uuid], targetSpaces.contains(where: { $0.uuid == prior }), !taken.contains(prior) {
                assignments[space.uuid] = prior
                taken.insert(prior)
            } else if let same = targetSpaces.first(where: { ($0.uuid == space.uuid || $0.id == space.id) && !taken.contains($0.uuid) }) {
                assignments[space.uuid] = same.uuid
                taken.insert(same.uuid)
            }
        }
        var remaining = targetSpaces.filter { !taken.contains($0.uuid) }
        for space in remembered where assignments[space.uuid] == nil {
            if !remaining.isEmpty {
                let next = remaining.removeFirst()
                assignments[space.uuid] = next.uuid
                taken.insert(next.uuid)
            } else {
                // No room on the returning display: its windows stay where they are.
                notes.append("desktop \(space.uuid) has no desktop to return to; left in place")
            }
        }

        var operations: [Operation] = []
        var moves: [CGWindowID: CGSSpaceID] = [:]
        var claimed: Set<CGWindowID> = []
        var skipped: [CGWindowID] = []

        for space in remembered {
            guard let targetUUID = assignments[space.uuid],
                  let targetSpace = targetSpaces.first(where: { $0.uuid == targetUUID })
            else { continue }
            let migrated = pending.migrations[space.uuid].flatMap { live.space(uuid: $0) }
            var group: [CGWindowID] = []

            // Everything currently on the migrated desktop travels as a unit.
            if let migrated, migrated.uuid != targetSpace.uuid {
                for wid in migrated.windowIDs {
                    guard let window = live.windows[wid], !window.isSticky, !claimed.contains(wid) else { continue }
                    claimed.insert(wid)
                    group.append(wid)
                }
            }

            // Remembered windows by ID, wherever they ended up.
            if idsValid {
                for wid in pending.windowsBySpace[space.uuid] ?? [] where !claimed.contains(wid) {
                    guard let window = live.windows[wid], !window.isSticky else { continue }
                    let current = live.space(containing: wid)
                    if current?.uuid == targetSpace.uuid {
                        claimed.insert(wid)
                        continue
                    }
                    let deliberate = current.map { pending.preexistingSpaceUUIDs.contains($0.uuid) } ?? false
                    if deliberate, migrated != nil {
                        skipped.append(wid)
                        continue
                    }
                    claimed.insert(wid)
                    group.append(wid)
                }
            }

            let toMove = group.filter { live.space(containing: $0)?.uuid != targetSpace.uuid }
            guard !toMove.isEmpty else { continue }
            operations.append(.moveWindows(toMove, to: targetSpace.id))
            for wid in toMove {
                moves[wid] = targetSpace.id
                guard let window = live.windows[wid] else { continue }
                if let remembered = pending.frames[wid] {
                    // Where it sat on this display before the unplug.
                    operations.append(.setFrame(wid, mapFrame(remembered, from: pending.record.identity.pointSize, to: target.bounds, visible: target.visibleBounds)))
                } else if let sourceKey = live.space(containing: wid)?.displayKey, let source = live.displays[sourceKey] {
                    // New since the unplug: keep its relative placement.
                    let relative = window.frame.offsetBy(dx: -source.bounds.minX, dy: -source.bounds.minY)
                    operations.append(.setFrame(wid, mapFrame(relative, from: source.bounds.size, to: target.bounds, visible: target.visibleBounds)))
                }
            }
        }

        return ReconnectPlan(operations: operations, moves: moves, assignments: assignments, skipped: skipped, notes: notes)
    }

    // MARK: - Frames

    /// Places a display-relative frame onto `bounds`: offset when the size
    /// matches, proportional scale otherwise, then nudged so a grabbable strip
    /// of the title bar stays inside `visible`. All CG global coordinates.
    static func mapFrame(_ relative: CGRect, from size: CGSize, to bounds: CGRect, visible: CGRect) -> CGRect {
        var frame: CGRect
        if size.width > 0, size.height > 0, size != bounds.size {
            let sx = bounds.width / size.width
            let sy = bounds.height / size.height
            frame = CGRect(x: relative.minX * sx, y: relative.minY * sy, width: relative.width * sx, height: relative.height * sy)
        } else {
            frame = relative
        }
        frame = frame.offsetBy(dx: bounds.minX, dy: bounds.minY)

        let visible = visible.isEmpty ? bounds : visible
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        let grab = min(80, frame.width)
        if frame.minX > visible.maxX - grab { frame.origin.x = visible.maxX - grab }
        if frame.maxX < visible.minX + grab { frame.origin.x = visible.minX + grab - frame.width }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.minY > visible.maxY - 40 { frame.origin.y = visible.maxY - 40 }
        return frame.integral
    }
}
