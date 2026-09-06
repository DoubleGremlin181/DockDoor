import CoreGraphics
@testable import DockDoor
import Foundation
import Testing

/// Scenario mirroring a real unplug on macOS 26: the LG had desktops
/// A(9: windows 1, 2), B(10: window 3), C(7: windows 4, 5, current). The
/// built-in had p1(5, current, window 50) and an empty p2(19). macOS moved
/// B and C to the built-in intact (same space IDs) and folded A's windows
/// into p1.
struct DisplayLayoutReconcilerTests {
    typealias R = DisplayLayoutReconciler
    private let token = "session"
    private let biBounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let lgBounds = CGRect(x: 1512, y: -98, width: 1920, height: 1080)

    private func identity(_ key: String, size: CGSize) -> DisplayIdentity {
        DisplayIdentity(key: key, uuid: key, isBuiltin: key == "BI", vendor: 0, model: 0, serial: 0, localizedName: key, pointSize: size)
    }

    private func display(_ key: String, bounds: CGRect, main: Bool) -> LiveDisplay {
        LiveDisplay(identity: identity(key, size: bounds.size), displayID: main ? 1 : 2, bounds: bounds, visibleBounds: bounds.insetBy(dx: 0, dy: 20), isMain: main)
    }

    private func window(_ id: CGWindowID, frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600), sticky: Bool = false) -> LiveWindow {
        LiveWindow(id: id, pid: 100, frame: frame, isSticky: sticky)
    }

    private func space(_ id: CGSSpaceID, uuid: String, on key: String, windows: [CGWindowID], current: Bool = false, fullscreen: Bool = false) -> LiveSpace {
        LiveSpace(id: id, uuid: uuid, displayKey: key, isFullscreen: fullscreen, isCurrent: current, windowIDs: windows)
    }

    private func state(displays: [LiveDisplay], spaces: [LiveSpace], windows: [LiveWindow]) -> LiveState {
        LiveState(displays: Dictionary(uniqueKeysWithValues: displays.map { ($0.identity.key, $0) }), spaces: spaces, windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }))
    }

    private var bi: LiveDisplay { display("BI", bounds: biBounds, main: true) }
    private var lg: LiveDisplay { display("LG", bounds: lgBounds, main: false) }

    private var lgRecord: DisplaySpacesRecord {
        DisplaySpacesRecord(identity: identity("LG", size: lgBounds.size), spaces: [
            SpaceRecord(uuid: "A", id: 9, index: 0, isFullscreen: false, wasCurrent: false),
            SpaceRecord(uuid: "B", id: 10, index: 1, isFullscreen: false, wasCurrent: false),
            SpaceRecord(uuid: "C", id: 7, index: 2, isFullscreen: false, wasCurrent: true),
        ], updatedAt: Date())
    }

    /// The Space Switcher's learned map before the unplug.
    private let learned: [CGWindowID: Set<CGSSpaceID>] = [1: [9], 2: [9], 3: [10], 4: [7], 5: [7], 50: [5], 90: [9, 10]]
    private let preexisting: Set<String> = ["p1", "p2"]
    private let allWindows: [CGWindowID] = [1, 2, 3, 4, 5, 50]

    private var afterUnplug: LiveState {
        state(displays: [bi], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [1, 2, 50], current: true),
            space(19, uuid: "p2", on: "BI", windows: []),
            space(10, uuid: "B", on: "BI", windows: [3]),
            space(7, uuid: "C", on: "BI", windows: [4, 5]),
        ], windows: allWindows.map { window($0) } + [window(90, sticky: true)])
    }

    private func disconnect(after: LiveState, useEmpty: Bool = true) -> R.DisconnectPlan {
        R.planDisconnect(record: lgRecord, learned: learned, preexistingSpaceUUIDs: preexisting, after: after, useEmptyDesktops: useEmpty, sessionToken: token)
    }

    // MARK: - Disconnect

    @Test func intactDesktopsMapBySpaceIDAndFoldedOneIsSeparated() {
        let plan = disconnect(after: afterUnplug)
        #expect(plan.pending.hostDisplayKey == "BI")
        #expect(plan.pending.windowsBySpace == ["A": [1, 2], "B": [3], "C": [4, 5]], "sticky window 90 is not remembered")
        #expect(plan.pending.migrations == ["A": "p2", "B": "B", "C": "C"])
        #expect(plan.operations == [.moveWindows([1, 2], to: 19)])
        #expect(plan.notes.first?.contains("folded into p1") == true)
    }

    @Test func foldedDesktopStaysWhenNotAllowedOrNoEmptyDesktop() {
        let kept = disconnect(after: afterUnplug, useEmpty: false)
        #expect(kept.operations.isEmpty)
        #expect(kept.pending.migrations == ["B": "B", "C": "C"])

        let noEmpty = state(displays: [bi], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [1, 2, 50], current: true),
            space(10, uuid: "B", on: "BI", windows: [3]),
            space(7, uuid: "C", on: "BI", windows: [4, 5]),
        ], windows: allWindows.map { window($0) })
        let plan = disconnect(after: noEmpty)
        #expect(plan.operations.isEmpty)
        #expect(plan.pending.migrations["A"] == nil)
    }

    @Test func currentDesktopIsNeverAnUnmergeTarget() {
        let live = state(displays: [bi], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50]),
            space(19, uuid: "p2", on: "BI", windows: [], current: true),
            space(10, uuid: "B", on: "BI", windows: [1, 2, 3]),
        ], windows: allWindows.map { window($0) })
        #expect(disconnect(after: live).operations.isEmpty)
    }

    @Test func desktopRemintedWithNewIDButSameUUIDStillMaps() {
        let live = state(displays: [bi], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50], current: true),
            space(40, uuid: "B", on: "BI", windows: [3]),
        ], windows: [window(3), window(50)])
        #expect(disconnect(after: live).pending.migrations == ["B": "B"])
    }

    @Test func fullscreenDesktopsAreIgnored() {
        var spaces = lgRecord.spaces
        spaces.append(SpaceRecord(uuid: "F", id: 12, index: 3, isFullscreen: true, wasCurrent: false))
        let record = DisplaySpacesRecord(identity: lgRecord.identity, spaces: spaces, updatedAt: Date())
        let live = state(displays: [bi], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50], current: true),
            space(12, uuid: "F", on: "BI", windows: [7], fullscreen: true),
        ], windows: [window(7), window(50)])
        let plan = R.planDisconnect(record: record, learned: [7: [12]], preexistingSpaceUUIDs: preexisting, after: live, useEmptyDesktops: true, sessionToken: token)
        #expect(plan.pending.migrations.isEmpty)
        #expect(plan.pending.windowsBySpace.isEmpty)
    }

    // MARK: - Reconnect

    private var pending: PendingRestore { disconnect(after: afterUnplug).pending }

    /// After the un-merge and a replug: macOS gave the LG three fresh desktops.
    private var afterReplug: LiveState {
        state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50], current: true),
            space(19, uuid: "p2", on: "BI", windows: [1, 2]),
            space(10, uuid: "B", on: "BI", windows: [3]),
            space(7, uuid: "C", on: "BI", windows: [4, 5]),
            space(30, uuid: "n1", on: "LG", windows: [], current: true),
            space(31, uuid: "n2", on: "LG", windows: []),
            space(32, uuid: "n3", on: "LG", windows: []),
        ], windows: allWindows.map { window($0) })
    }

    @Test func replugMovesEachMigratedDesktopBackInOrder() {
        let plan = R.planReconnect(pending: pending, live: afterReplug, sessionToken: token)
        #expect(plan.assignments == ["A": "n1", "B": "n2", "C": "n3"])
        #expect(plan.moves == [1: 30, 2: 30, 3: 31, 4: 32, 5: 32])
        #expect(plan.skipped.isEmpty)
        #expect(plan.operations.first == .moveWindows([1, 2], to: 30))
        // Frames: relative offset on the built-in, scaled onto the LG, inside its bounds.
        let frames = plan.operations.compactMap { op -> CGRect? in
            if case let .setFrame(_, frame) = op { return frame }
            return nil
        }
        #expect(frames.count == 5)
        #expect(frames.allSatisfy { lgBounds.contains($0) })
    }

    @Test func replugIsIdempotent() {
        let first = R.planReconnect(pending: pending, live: afterReplug, sessionToken: token)
        var settled = pending
        settled.assignments = first.assignments
        let done = state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50], current: true),
            space(19, uuid: "p2", on: "BI", windows: []),
            space(10, uuid: "B", on: "BI", windows: []),
            space(7, uuid: "C", on: "BI", windows: []),
            space(30, uuid: "n1", on: "LG", windows: [1, 2], current: true),
            space(31, uuid: "n2", on: "LG", windows: [3]),
            space(32, uuid: "n3", on: "LG", windows: [4, 5]),
        ], windows: allWindows.map { window($0) })
        let second = R.planReconnect(pending: settled, live: done, sessionToken: token)
        #expect(second.operations.isEmpty)
        #expect(second.assignments == first.assignments)
    }

    @Test func macOSMovingDesktopsBackItselfIsRespected() {
        // The LG came back with B and C already on it (same IDs) plus one new desktop.
        let live = state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50], current: true),
            space(19, uuid: "p2", on: "BI", windows: [1, 2]),
            space(30, uuid: "n1", on: "LG", windows: [], current: true),
            space(10, uuid: "B", on: "LG", windows: [3]),
            space(7, uuid: "C", on: "LG", windows: [4, 5]),
        ], windows: allWindows.map { window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.assignments == ["A": "n1", "B": "B", "C": "C"])
        #expect(plan.moves == [1: 30, 2: 30])
    }

    @Test func fewerDesktopsLeaveTheExtrasWhereTheyAre() {
        let live = state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50], current: true),
            space(19, uuid: "p2", on: "BI", windows: [1, 2]),
            space(10, uuid: "B", on: "BI", windows: [3]),
            space(7, uuid: "C", on: "BI", windows: [4, 5]),
            space(30, uuid: "n1", on: "LG", windows: [], current: true),
            space(31, uuid: "n2", on: "LG", windows: []),
        ], windows: allWindows.map { window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.assignments == ["A": "n1", "B": "n2"])
        #expect(plan.moves == [1: 30, 2: 30, 3: 31], "C stays intact on the built-in")
        #expect(plan.notes.contains { $0.contains("left in place") })
    }

    @Test func rememberedFramesWinOverCurrentPlacement() {
        var withFrames = pending
        withFrames.frames = [1: CGRect(x: 200, y: 100, width: 640, height: 480)]
        let plan = R.planReconnect(pending: withFrames, live: afterReplug, sessionToken: token)
        #expect(plan.operations.contains(.setFrame(1, CGRect(x: 1712, y: 2, width: 640, height: 480))), "remembered frame, offset onto the LG")
        let other = plan.operations.compactMap { op -> CGRect? in
            if case let .setFrame(2, frame) = op { return frame }
            return nil
        }.first
        #expect(other != nil && other != CGRect(x: 1712, y: 2, width: 640, height: 480), "window 2 has no remembered frame and keeps its relative placement")
    }

    @Test func disconnectKeepsOnlyRememberedWindowsFrames() {
        let frames: [CGWindowID: CGRect] = [1: CGRect(x: 1, y: 2, width: 3, height: 4), 50: CGRect(x: 9, y: 9, width: 9, height: 9), 90: .zero]
        let plan = R.planDisconnect(record: lgRecord, learned: learned, preexistingSpaceUUIDs: preexisting, after: afterUnplug, useEmptyDesktops: true, frames: frames, sessionToken: token)
        #expect(plan.pending.frames == [1: CGRect(x: 1, y: 2, width: 3, height: 4)])
    }

    @Test func windowsOpenedOnAMigratedDesktopTravelWithIt() {
        var live = afterReplug
        live = state(displays: [bi, lg], spaces: live.spaces.map { space in
            space.uuid == "C" ? self.space(7, uuid: "C", on: "BI", windows: [4, 5, 77]) : space
        }, windows: allWindows.map { window($0) } + [window(77)])
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.moves[77] == 32)
    }

    @Test func deliberatelyMovedWindowIsLeftAlone() {
        // User dragged window 4 onto the built-in's own desktop p1 while the LG was away.
        let live = state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50, 4], current: true),
            space(19, uuid: "p2", on: "BI", windows: [1, 2]),
            space(10, uuid: "B", on: "BI", windows: [3]),
            space(7, uuid: "C", on: "BI", windows: [5]),
            space(30, uuid: "n1", on: "LG", windows: [], current: true),
            space(31, uuid: "n2", on: "LG", windows: []),
            space(32, uuid: "n3", on: "LG", windows: []),
        ], windows: allWindows.map { window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.moves[4] == nil)
        #expect(plan.skipped == [4])
        #expect(plan.moves[5] == 32)
    }

    @Test func windowsOfADestroyedMigratedDesktopAreReclaimedAnywhere() {
        // User closed desktop C; macOS dumped 4 and 5 onto p1.
        let live = state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [50, 4, 5], current: true),
            space(19, uuid: "p2", on: "BI", windows: [1, 2]),
            space(10, uuid: "B", on: "BI", windows: [3]),
            space(30, uuid: "n1", on: "LG", windows: [], current: true),
            space(31, uuid: "n2", on: "LG", windows: []),
            space(32, uuid: "n3", on: "LG", windows: []),
        ], windows: allWindows.map { window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.moves[4] == 32 && plan.moves[5] == 32)
    }

    @Test func closedWindowsAreSimplyGone() {
        var live = afterReplug
        live = state(displays: [bi, lg], spaces: live.spaces.map { space in
            space.uuid == "B" ? self.space(10, uuid: "B", on: "BI", windows: []) : space
        }, windows: [1, 2, 4, 5, 50].map { window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.moves[3] == nil)
        #expect(plan.moves.count == 4)
    }

    @Test func differentSessionOnlyMovesWhatSitsOnMigratedDesktops() {
        // After a new login the remembered IDs are meaningless, but a migrated
        // desktop that still exists by uuid is still moved as a unit.
        let live = state(displays: [bi, lg], spaces: [
            space(5, uuid: "p1", on: "BI", windows: [1, 2, 50], current: true),
            space(7, uuid: "C", on: "BI", windows: [4, 5]),
            space(30, uuid: "n1", on: "LG", windows: [], current: true),
            space(31, uuid: "n2", on: "LG", windows: []),
            space(32, uuid: "n3", on: "LG", windows: []),
        ], windows: allWindows.map { window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: "other")
        #expect(plan.moves == [4: 32, 5: 32])
    }

    @Test func stickyWindowsNeverMove() {
        var live = afterReplug
        live = state(displays: [bi, lg], spaces: live.spaces, windows: allWindows.map { $0 == 3 ? window($0, sticky: true) : window($0) })
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.moves[3] == nil)
    }

    @Test func noUserDesktopsYetProducesNoOperations() {
        let live = state(displays: [bi, lg], spaces: [space(19, uuid: "p2", on: "BI", windows: [1, 2])], windows: [window(1), window(2)])
        let plan = R.planReconnect(pending: pending, live: live, sessionToken: token)
        #expect(plan.operations.isEmpty)
        #expect(plan.notes.first?.contains("no user desktops") == true)
    }

    // MARK: - Frames

    @Test func mapFrameOffsetsWhenSizesMatch() {
        let bounds = CGRect(x: 1512, y: -98, width: 1920, height: 1080)
        let mapped = R.mapFrame(CGRect(x: 100, y: 50, width: 800, height: 600), from: bounds.size, to: bounds, visible: bounds)
        #expect(mapped == CGRect(x: 1612, y: -48, width: 800, height: 600))
    }

    @Test func mapFrameScalesProportionally() {
        let bounds = CGRect(x: 0, y: 0, width: 960, height: 540)
        let mapped = R.mapFrame(CGRect(x: 100, y: 50, width: 800, height: 600), from: CGSize(width: 1920, height: 1080), to: bounds, visible: bounds)
        #expect(mapped == CGRect(x: 50, y: 25, width: 400, height: 300))
    }

    @Test func mapFrameClampsIntoVisibleArea() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let visible = CGRect(x: 0, y: 25, width: 1000, height: 500)
        let offRight = R.mapFrame(CGRect(x: 980, y: 10, width: 300, height: 200), from: bounds.size, to: bounds, visible: visible)
        #expect(offRight.minX == 920 && offRight.minY == 25)
        let offLeft = R.mapFrame(CGRect(x: -500, y: 700, width: 300, height: 200), from: bounds.size, to: bounds, visible: visible)
        #expect(offLeft.maxX == 80 && offLeft.minY == 485)
        let huge = R.mapFrame(CGRect(x: 0, y: 0, width: 5000, height: 5000), from: bounds.size, to: bounds, visible: visible)
        #expect(huge.size == visible.size)
    }
}
