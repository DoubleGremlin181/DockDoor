import AppKit
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

    @Test func systemMainIdentifierResolvesToFirstScreen() {
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: NSScreen.systemMainDisplayIdentifier, resolveLastActiveWindow: false) == NSScreen.screens.first)
    }

    @Test func legacyPinnedIdentifierStillResolves() {
        guard let screen = NSScreen.screens.first else { return }
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: screen.legacyIdentifier(), resolveLastActiveWindow: false) == screen)
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: screen.uniqueIdentifier(), resolveLastActiveWindow: false) == screen)
    }

    @Test func unknownPinnedIdentifierFallsThrough() {
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: "", resolveLastActiveWindow: false) == nil)
        #expect(SwitcherScreenPlacement.resolve(strategy: .pinnedToScreen, pinnedIdentifier: "no-such-display", resolveLastActiveWindow: false) == nil)
    }
}
