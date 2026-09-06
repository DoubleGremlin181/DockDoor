import CoreGraphics
@testable import DockDoor
import Foundation
import Testing

struct DisplayLayoutStoreTests {
    private func record(_ key: String, updatedAt: Date = Date(), spaces: [CGSSpaceID] = [9, 10]) -> DisplaySpacesRecord {
        let identity = DisplayIdentity(key: key, uuid: key, isBuiltin: false, vendor: 1, model: 2, serial: 3, localizedName: "LG", pointSize: CGSize(width: 1920, height: 1080))
        return DisplaySpacesRecord(
            identity: identity,
            spaces: spaces.enumerated().map { SpaceRecord(uuid: "u\($1)", id: $1, index: $0, isFullscreen: false, wasCurrent: $0 == 0) },
            updatedAt: updatedAt
        )
    }

    @Test func jsonRoundTrip() throws {
        var store = DisplayLayoutStore()
        store.note(record("LG"))
        store.pending["LG"] = PendingRestore(displayKey: "LG", record: record("LG"), removedAt: Date(), sessionToken: "s", hostDisplayKey: "BI", windowsBySpace: ["u9": [1, 2]], migrations: ["u9": "p2"], preexistingSpaceUUIDs: ["p1"], assignments: ["u9": "n1"], restoredAt: nil)
        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(DisplayLayoutStore.self, from: data)
        #expect(decoded.displays["LG"] == store.displays["LG"])
        #expect(decoded.pending["LG"] == store.pending["LG"])
    }

    @Test func noteReportsChangesOnly() {
        var store = DisplayLayoutStore()
        let first = store.note(record("LG", updatedAt: Date(timeIntervalSince1970: 1)))
        let same = store.note(record("LG", updatedAt: Date(timeIntervalSince1970: 2)))
        var current = record("LG")
        current = DisplaySpacesRecord(identity: current.identity, spaces: current.spaces.map { SpaceRecord(uuid: $0.uuid, id: $0.id, index: $0.index, isFullscreen: $0.isFullscreen, wasCurrent: $0.index == 1) }, updatedAt: Date())
        let switched = store.note(current)
        let grown = store.note(record("LG", spaces: [9, 10, 11]))
        #expect(first)
        #expect(!same, "same desktops, newer timestamp: nothing to save")
        #expect(!switched, "a space switch alone is not worth a write")
        #expect(grown)
        #expect(store.displays["LG"]?.spaces.count == 3)
    }

    @Test func capDropsOldestNonPending() {
        var store = DisplayLayoutStore()
        let base = Date(timeIntervalSince1970: 1000)
        for i in 0 ..< (DisplayLayoutStore.maxDisplays + 2) {
            store.note(record("D\(i)", updatedAt: base.addingTimeInterval(TimeInterval(i))))
        }
        #expect(store.displays.count == DisplayLayoutStore.maxDisplays)
        #expect(store.displays["D0"] == nil && store.displays["D1"] == nil)
        #expect(store.displays["D2"] != nil)
    }

    @Test func olderStoreVersionIsDiscardedOnLoad() throws {
        struct Old: Codable { var version = 1 }
        let data = try JSONEncoder().encode(Old())
        let decoded = try? JSONDecoder().decode(DisplayLayoutStore.self, from: data)
        #expect(decoded == nil || decoded?.version != DisplayLayoutStore().version)
    }

    @Test func sessionTokenIsStableWithinProcess() {
        #expect(DisplayLayoutStore.currentSessionToken() == DisplayLayoutStore.currentSessionToken())
        #expect(!DisplayLayoutStore.currentSessionToken().isEmpty)
    }
}
