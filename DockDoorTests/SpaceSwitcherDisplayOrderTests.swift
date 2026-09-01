import CoreGraphics
@testable import DockDoor
import Testing

// MARK: - SpaceSwitcherDisplayOrder Tests

struct SpaceSwitcherDisplayOrderTests {
    private func display(_ id: String, desktops: [Int]) -> DisplaySpaces {
        DisplaySpaces(
            identifier: id,
            screen: nil,
            currentSpaceID: nil,
            spaces: desktops.map { SpaceInfo(id: CGSSpaceID($0), uuid: "", type: 0, displayIdentifier: id, desktopNumber: $0, isCurrent: false) }
        )
    }

    // Main display in the middle, a left display, a right display higher up, and one unresolved.
    private let main = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let left = CGRect(x: -1200, y: 0, width: 1200, height: 600)
    private let right = CGRect(x: 1000, y: 300, width: 800, height: 600)
    private var frames: [String: CGRect] {
        ["main": main, "left": left, "right": right]
    }

    private var numbered: [DisplaySpaces] {
        [display("main", desktops: [1, 2]), display("left", desktops: [3]), display("right", desktops: [4, 5]), display("ghost", desktops: [])]
    }

    private func ids(_ order: SpaceSwitcherDisplayOrder, lead: String? = nil) -> [String] {
        WindowSpaces.reorderRows(numbered, order: order, frames: frames, leadIdentifier: lead).map(\.identifier)
    }

    @Test func mainFirstKeepsInput() {
        #expect(ids(.mainDisplayFirst) == ["main", "left", "right", "ghost"])
    }

    @Test func leftToRight() {
        #expect(ids(.leftToRight) == ["left", "main", "right", "ghost"])
    }

    @Test func topToBottom() {
        #expect(ids(.topToBottom) == ["right", "left", "main", "ghost"])
    }

    @Test func leadDisplayFirstThenLeftToRight() {
        #expect(ids(.displayWithMouseFirst, lead: "right") == ["right", "left", "main", "ghost"])
        #expect(ids(.displayWithActiveWindowFirst, lead: "main") == ["main", "left", "right", "ghost"])
        #expect(ids(.displayWithMouseFirst, lead: nil) == ["left", "main", "right", "ghost"])
        #expect(ids(.displayWithMouseFirst, lead: "ghost") == ["left", "main", "right", "ghost"], "unresolved displays never lead")
    }

    @Test func reorderingPreservesDesktopNumbers() {
        let rows = WindowSpaces.reorderRows(numbered, order: .leftToRight, frames: frames)
        let numbersByDisplay = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0.spaces.map(\.desktopNumber)) })
        #expect(numbersByDisplay["main"] == [1, 2])
        #expect(numbersByDisplay["left"] == [3])
        #expect(numbersByDisplay["right"] == [4, 5])
    }
}
