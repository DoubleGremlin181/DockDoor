@testable import DockDoor
import Testing

// MARK: - SpaceSwitcherEngine Attribution Tests

struct SpaceAttributionTests {
    private let known: Set<CGSSpaceID> = [1, 2, 3]

    private func resolve(
        fresh: [CGSSpaceID] = [],
        moveOverride: CGSSpaceID? = nil,
        onscreenCurrentSpaceID: CGSSpaceID? = nil,
        learned: Set<CGSSpaceID>? = nil,
        cachedSpaceID: CGSSpaceID? = nil
    ) -> SpaceSwitcherEngine.Attribution? {
        SpaceSwitcherEngine.resolveAttribution(
            fresh: fresh,
            moveOverride: moveOverride,
            onscreenCurrentSpaceID: onscreenCurrentSpaceID,
            learned: learned,
            cachedSpaceID: cachedSpaceID,
            knownSpaceIDs: known
        )
    }

    @Test func freshAnswerWinsAndIsAuthoritative() {
        let attribution = resolve(fresh: [2], moveOverride: 3, onscreenCurrentSpaceID: 1, learned: [1], cachedSpaceID: 3)
        #expect(attribution == SpaceSwitcherEngine.Attribution(spaces: [2], isSticky: false, isAuthoritative: true))
    }

    @Test func multipleFreshSpacesAreSticky() {
        let attribution = resolve(fresh: [1, 2])
        #expect(attribution?.isSticky == true)
        #expect(attribution?.isAuthoritative == true)
    }

    @Test func moveOverrideBeatsOnscreenAndLearned() {
        let attribution = resolve(moveOverride: 3, onscreenCurrentSpaceID: 1, learned: [2])
        #expect(attribution == SpaceSwitcherEngine.Attribution(spaces: [3], isSticky: true, isAuthoritative: false))
    }

    @Test func unknownMoveOverrideIsSkipped() {
        let attribution = resolve(moveOverride: 99, learned: [2])
        #expect(attribution?.spaces == [2])
    }

    @Test func onscreenContainmentIsStickyAndNotAuthoritative() {
        let attribution = resolve(onscreenCurrentSpaceID: 1)
        #expect(attribution == SpaceSwitcherEngine.Attribution(spaces: [1], isSticky: true, isAuthoritative: false))
    }

    @Test func learnedSpacesFilteredToKnown() {
        let attribution = resolve(learned: [2, 99])
        #expect(attribution == SpaceSwitcherEngine.Attribution(spaces: [2], isSticky: false, isAuthoritative: false))
    }

    @Test func fullyStaleLearnedFallsThroughToCached() {
        let attribution = resolve(learned: [98, 99], cachedSpaceID: 3)
        #expect(attribution == SpaceSwitcherEngine.Attribution(spaces: [3], isSticky: false, isAuthoritative: false))
    }

    @Test func unknownCachedSpaceYieldsNoAttribution() {
        #expect(resolve(cachedSpaceID: 99) == nil)
        #expect(resolve() == nil)
    }
}

// MARK: - Ghost Filter Tests

struct GhostFilterTests {
    @Test func onscreenWindowsAlwaysAccepted() {
        #expect(SpaceSwitcherEngine.ghostFilterVerdict(spaces: [1], isOnscreen: true, currentSpaceIDs: [1], isKnownToDiscovery: false, hasTitle: false) == .accept)
    }

    @Test func offscreenOnOnlyVisibleSpacesIsInvisibleHelper() {
        #expect(SpaceSwitcherEngine.ghostFilterVerdict(spaces: [1], isOnscreen: false, currentSpaceIDs: [1, 2], isKnownToDiscovery: true, hasTitle: true) == .rejectAndUnlearn)
    }

    @Test func offscreenOnOtherSpaceNeedsVouching() {
        #expect(SpaceSwitcherEngine.ghostFilterVerdict(spaces: [3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: false, hasTitle: false) == .reject)
        #expect(SpaceSwitcherEngine.ghostFilterVerdict(spaces: [3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: true, hasTitle: false) == .accept)
        #expect(SpaceSwitcherEngine.ghostFilterVerdict(spaces: [3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: false, hasTitle: true) == .accept)
    }

    @Test func partiallyOffscreenAttributionIsAccepted() {
        #expect(SpaceSwitcherEngine.ghostFilterVerdict(spaces: [1, 3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: true, hasTitle: true) == .accept)
    }
}
