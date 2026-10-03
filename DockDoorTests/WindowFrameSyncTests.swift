import CoreGraphics
@testable import DockDoor
import Testing

struct WindowFrameSyncTests {
    typealias S = WindowFrameSync
    private let laptopDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let externalDisplay = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    private let laptop = CGRect(x: 0, y: 32, width: 1512, height: 860)
    private let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    /// Where the window server drops a laptop-filling window on the external display
    private let shifted = CGRect(x: 1512, y: 57, width: 1512, height: 860)

    private var displays: [CGRect] { [laptopDisplay, externalDisplay] }

    @Test func appStillOnTheOldDisplayIsToldTheServerFrame() {
        #expect(S.verdict(app: laptop, server: shifted, planned: nil) == .assert(shifted))
    }

    @Test func appStillOnTheOldDisplayIsToldThePlannedFrame() {
        #expect(S.verdict(app: laptop, server: shifted, planned: external) == .assert(external))
    }

    @Test func appThatFollowedIsLeftAloneWithoutAPlan() {
        #expect(S.verdict(app: shifted, server: shifted, planned: nil) == .leave)
    }

    @Test func plannedFrameWinsOverWhereTheAppPutTheWindow() {
        #expect(S.verdict(app: shifted, server: shifted, planned: external) == .assert(external), "adopting the window server's shift is not the restore")
        #expect(S.verdict(app: external, server: external, planned: external) == .leave)
    }

    @Test func settledNeedsAgreementOnTheTargetDisplay() {
        #expect(S.settled(app: external, server: external, target: external, displays: displays))
        // The app shrank the frame it was given but kept it on the external display.
        let constrained = CGRect(x: 1512, y: 25, width: 1920, height: 1055)
        #expect(S.settled(app: constrained, server: constrained, target: external, displays: displays))
        #expect(!S.settled(app: laptop, server: laptop, target: external, displays: displays), "clamped back onto the laptop")
        #expect(!S.settled(app: external, server: shifted, target: external, displays: displays), "window server has not caught up")
    }

    @Test func strayedMeansTheTwoFramesAreOnDifferentDisplays() {
        #expect(S.strayed(app: laptop, server: shifted, displays: displays))
        #expect(S.strayed(app: external, server: laptop, displays: displays))
        #expect(!S.strayed(app: shifted, server: shifted, displays: displays))
        // Same display, different frame: an app that reports with an offset, or a resize in flight.
        #expect(!S.strayed(app: CGRect(x: 1600, y: 40, width: 928, height: 782), server: CGRect(x: 1700, y: 34, width: 928, height: 782), displays: displays))
        // Off every display: nothing to go by.
        #expect(!S.strayed(app: CGRect(x: 5000, y: 0, width: 400, height: 300), server: shifted, displays: displays))
    }

    private var areas: [S.DisplayArea] {
        [S.DisplayArea(bounds: laptopDisplay, usable: laptop), S.DisplayArea(bounds: externalDisplay, usable: externalDisplay)]
    }

    @Test func windowFillingItsDisplayArrivesFillingTheOther() {
        #expect(S.arrival(before: laptop, server: shifted, areas: areas) == external)
        // The window server carries the external's 1920x1080 onto the smaller laptop unchanged.
        #expect(S.arrival(before: external, server: CGRect(x: 0, y: 0, width: 1920, height: 1080), areas: areas) == laptop)
    }

    @Test func windowThatFitsKeepsTheWindowServersShift() {
        let before = CGRect(x: 102, y: 70, width: 1001, height: 662)
        #expect(S.arrival(before: before, server: CGRect(x: 1700, y: 80, width: 1001, height: 662), areas: areas) == nil)
    }

    @Test func windowTooBigForTheNewDisplayIsFittedIn() {
        let before = CGRect(x: 1600, y: 40, width: 1800, height: 1000)
        let fitted = S.arrival(before: before, server: CGRect(x: 0, y: 0, width: 1800, height: 1000), areas: areas)
        #expect(fitted == laptop)
        let wide = S.arrival(before: CGRect(x: 1600, y: 200, width: 1700, height: 500), server: CGRect(x: 0, y: 200, width: 1700, height: 500), areas: areas)
        #expect(wide == CGRect(x: 0, y: 200, width: 1512, height: 500))
    }

    @Test func namedTargetDisplayBeatsTheOverlapGuess() {
        // A 2560-wide fill dropped at the laptop's origin still overlaps the external more.
        let wideDisplay = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let wideAreas = [S.DisplayArea(bounds: laptopDisplay, usable: laptop, displayID: 1), S.DisplayArea(bounds: wideDisplay, usable: wideDisplay, displayID: 2)]
        let landed = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(S.arrival(before: wideDisplay, server: landed, areas: wideAreas) == laptop, "without a target the origin decides, not the overlap")
        #expect(S.arrival(before: wideDisplay, server: landed, areas: wideAreas, target: wideAreas[0]) == laptop)
        // Origin off every display (an 1800-wide window dropped at x = -212): overlap decides.
        #expect(S.arrival(before: CGRect(x: 1600, y: 40, width: 1800, height: 942), server: CGRect(x: -212, y: 11, width: 1800, height: 942), areas: wideAreas) == laptop)
        // Not a fill: fitted into the named target.
        let big = CGRect(x: 1600, y: 100, width: 2000, height: 1200)
        #expect(S.arrival(before: big, server: CGRect(x: 0, y: 0, width: 2000, height: 1200), areas: wideAreas, target: wideAreas[0]) == laptop)
        // A target the window is already on: nothing to do.
        #expect(S.arrival(before: laptop, server: laptop, areas: wideAreas, target: wideAreas[0]) == nil)
    }

    @Test func noArrivalFrameWithoutAChangeOfDisplay() {
        #expect(S.arrival(before: laptop, server: laptop, areas: areas) == nil)
        #expect(S.arrival(before: laptop, server: shifted, areas: []) == nil)
    }

    @Test func agreementToleratesTwoPointsNotThree() {
        #expect(S.matches(laptop, CGRect(x: 2, y: 30, width: 1510, height: 862)))
        #expect(!S.matches(laptop, CGRect(x: 3, y: 32, width: 1512, height: 860)))
        #expect(!S.matches(laptop, CGRect(x: 0, y: 32, width: 1512, height: 863)))
        #expect(!S.matches(laptop, shifted))
    }
}
