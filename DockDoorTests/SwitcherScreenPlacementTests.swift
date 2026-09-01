@testable import DockDoor
import Testing

// MARK: - SwitcherScreenPlacement Tests

struct SwitcherScreenPlacementTests {
    @Test func mouseStrategyDefersToCaller() {
        #expect(SwitcherScreenPlacement.resolve(strategy: .screenWithMouse, pinnedIdentifier: "", resolveLastActiveWindow: true) == nil)
    }

    @Test func lastActiveWindowDeferredWhenNotResolvedHere() {
        #expect(SwitcherScreenPlacement.resolve(strategy: .screenWithLastActiveWindow, pinnedIdentifier: "", resolveLastActiveWindow: false) == nil)
    }

    @Test func unknownPinnedIdentifierFallsThrough() {
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: "", resolveLastActiveWindow: false) == nil)
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: "no-such-display", resolveLastActiveWindow: false) == nil)
    }
}
