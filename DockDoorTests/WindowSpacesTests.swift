import CoreGraphics
@testable import DockDoor
import Testing

struct WindowSpacesTests {
    private let fullscreen: Set<CGSSpaceID> = [427]
    private let spaces: [CGWindowID: [CGSSpaceID]] = [1: [7], 2: [427], 3: [], 4: [7, 427]]

    private func movable(_ ids: [CGWindowID], to target: CGSSpaceID) -> [CGWindowID] {
        WindowSpaces.movable(ids, to: target, spacesOf: { spaces[$0] ?? [] }, fullscreenSpaceIDs: fullscreen)
    }

    @Test func windowsInAFullscreenSpaceAreRefused() {
        #expect(movable([1, 2, 3, 4], to: 385) == [1, 3], "a window on no known Space passes; one on any fullscreen Space does not")
    }

    @Test func nothingMovesIntoAFullscreenSpace() {
        #expect(movable([1, 3], to: 427).isEmpty)
    }

    @Test func plainMovesAreUntouched() {
        #expect(WindowSpaces.movable([1, 2], to: 385, spacesOf: { _ in [7] }, fullscreenSpaceIDs: []) == [1, 2])
    }
}
