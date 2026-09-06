import CoreGraphics
@testable import DockDoor
import Testing

struct DisplayIdentityTests {
    private func probe(_ id: CGDirectDisplayID, uuid: String?, x: CGFloat = 0, y: CGFloat = 0, builtin: Bool = false, vms: (UInt32, UInt32, UInt32) = (0, 0, 0)) -> DisplayIdentity.Probe {
        DisplayIdentity.Probe(displayID: id, uuid: uuid, isBuiltin: builtin, vendor: vms.0, model: vms.1, serial: vms.2, localizedName: "D\(id)", bounds: CGRect(x: x, y: y, width: 1000, height: 600))
    }

    @Test func uniqueUUIDIsTheKey() {
        let ids = DisplayIdentity.identities(for: [probe(1, uuid: "aaaa-1"), probe(2, uuid: "BBBB-2")])
        #expect(ids[1]?.key == "AAAA-1")
        #expect(ids[2]?.key == "BBBB-2")
    }

    @Test func collidingUUIDsGetPositionalSuffixes() {
        let ids = DisplayIdentity.identities(for: [probe(7, uuid: "SAME", x: 1000), probe(3, uuid: "SAME", x: -1000), probe(9, uuid: "OTHER")])
        #expect(ids[3]?.key == "SAME#0", "leftmost first")
        #expect(ids[7]?.key == "SAME#1")
        #expect(ids[9]?.key == "OTHER")
    }

    @Test func fallbackKeysWithoutUUID() {
        #expect(DisplayIdentity.baseKey(for: probe(1, uuid: nil, vms: (1, 2, 3))) == "vms:1-2-3")
        #expect(DisplayIdentity.baseKey(for: probe(1, uuid: nil, builtin: true)) == "builtin")
        #expect(DisplayIdentity.baseKey(for: probe(1, uuid: "")) == "unknown:1000x600")
    }

    @Test func identityKeepsMetadata() {
        let ids = DisplayIdentity.identities(for: [probe(4, uuid: "u", builtin: true, vms: (5, 6, 7))])
        let identity = ids[4]
        #expect(identity?.isBuiltin == true)
        #expect(identity?.vendor == 5 && identity?.model == 6 && identity?.serial == 7)
        #expect(identity?.pointSize == CGSize(width: 1000, height: 600))
        #expect(identity?.localizedName == "D4")
    }
}
