import AppKit
@testable import DockDoor
import Testing

// MARK: - SpaceSwitcherEngine Attribution Tests

struct SpaceAttributionTests {
    @Test func singleSpaceAnswerIsASwitchTarget() {
        #expect(SpaceSwitcherEngine.resolveAttribution(fresh: [2]) == SpaceSwitcherEngine.Attribution(spaces: [2], isSticky: false))
    }

    @Test func multipleSpacesAreSticky() {
        let attribution = SpaceSwitcherEngine.resolveAttribution(fresh: [1, 2])
        #expect(attribution?.spaces == [1, 2])
        #expect(attribution?.isSticky == true)
    }

    @Test func noSpaceMeansNoAttribution() {
        #expect(SpaceSwitcherEngine.resolveAttribution(fresh: []) == nil)
    }
}

// MARK: - Ghost Filter Tests

struct GhostFilterTests {
    @Test func onscreenWindowsAlwaysAccepted() {
        #expect(!SpaceSwitcherEngine.isGhost(spaces: [1], isOnscreen: true, currentSpaceIDs: [1], isKnownToDiscovery: false, hasTitle: false))
    }

    @Test func offscreenOnOnlyVisibleSpacesIsNotDrawn() {
        #expect(SpaceSwitcherEngine.isGhost(spaces: [1], isOnscreen: false, currentSpaceIDs: [1, 2], isKnownToDiscovery: true, hasTitle: true))
    }

    @Test func offscreenOnOtherSpaceNeedsVouching() {
        #expect(SpaceSwitcherEngine.isGhost(spaces: [3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: false, hasTitle: false))
        #expect(!SpaceSwitcherEngine.isGhost(spaces: [3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: true, hasTitle: false))
        #expect(!SpaceSwitcherEngine.isGhost(spaces: [3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: false, hasTitle: true))
    }

    @Test func partiallyOffscreenAttributionIsAccepted() {
        #expect(!SpaceSwitcherEngine.isGhost(spaces: [1, 3], isOnscreen: false, currentSpaceIDs: [1], isKnownToDiscovery: true, hasTitle: true))
    }
}

struct ThumbnailDiffTests {
    private func solid(_ gray: CGFloat, width: Int = 64, height: Int = 36) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func identicalImagesDoNotDiffer() {
        #expect(!SpaceSwitchingCoordinator.thumbnailsDiffer(solid(0.5), solid(0.5)))
    }

    @Test func contentChangeDiffers() {
        #expect(SpaceSwitchingCoordinator.thumbnailsDiffer(solid(0.2), solid(0.8)))
    }

    @Test func shapeChangeDiffers() {
        #expect(SpaceSwitchingCoordinator.thumbnailsDiffer(solid(0.5), solid(0.5, width: 36, height: 64)))
    }
}
