@testable import DockDoor
import Foundation
import Testing

struct DisplayChangeCoalescerTests {
    typealias C = DisplayChangeCoalescer
    private let two = C.Signature(keys: ["BI", "LG"], separateSpaces: true)
    private let one = C.Signature(keys: ["BI"], separateSpaces: true)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func unplugBurstActsOnce() {
        var c = C(initial: two)
        #expect(c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { false }) == [.capturePreChange, .armTimer(C.debounce)])
        #expect(c.hasPreChange)
        #expect(c.handle(.beginConfiguration, now: at(0.1), signature: { one }, isBusy: { false }) == [.armTimer(C.debounce)], "second begin in the burst keeps the first snapshot")
        #expect(c.handle(.postConfiguration, now: at(0.5), signature: { one }, isBusy: { false }) == [.armTimer(C.debounce)])
        #expect(c.handle(.screenParametersChanged, now: at(0.7), signature: { one }, isBusy: { false }) == [.armTimer(C.debounce)])
        #expect(c.handle(.timer, now: at(3.2), signature: { one }, isBusy: { false }) == [.act(previous: two, current: one)])
        #expect(c.phase == .acting)
        #expect(c.handle(.timer, now: at(4), signature: { one }, isBusy: { false }) == [])
        #expect(c.actionFinished(now: at(5), signature: one) == [.armTimer(C.cooldown)])
        #expect(c.handle(.timer, now: at(8), signature: { one }, isBusy: { false }) == [.becameIdle])
        #expect(c.isIdle)
        #expect(c.lastActed == one)
    }

    @Test func flapWithoutNetChangeIsNoOp() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { false })
        _ = c.handle(.postConfiguration, now: at(1), signature: { one }, isBusy: { false })
        _ = c.handle(.postConfiguration, now: at(2), signature: { two }, isBusy: { false })
        #expect(c.handle(.timer, now: at(4.5), signature: { two }, isBusy: { false }) == [.armTimer(C.cooldown)])
        #expect(c.phase == .cooldown)
        #expect(!c.hasPreChange)
        #expect(c.handle(.timer, now: at(8), signature: { two }, isBusy: { false }) == [.becameIdle])
    }

    @Test func busyWindowServerWalksTheLadderThenActs() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { true })
        #expect(c.handle(.timer, now: at(2.5), signature: { one }, isBusy: { true }) == [.armTimer(C.quiescenceLadder[0])])
        #expect(c.handle(.timer, now: at(4), signature: { one }, isBusy: { true }) == [.armTimer(C.quiescenceLadder[1])])
        #expect(c.handle(.timer, now: at(7.5), signature: { one }, isBusy: { true }) == [.armTimer(C.quiescenceLadder[2])])
        #expect(c.handle(.timer, now: at(15.5), signature: { one }, isBusy: { true }) == [.act(previous: two, current: one)], "acts after the last rung even if still busy")
    }

    @Test func quiescenceEndsEarlyWhenIdle() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { true })
        _ = c.handle(.timer, now: at(2.5), signature: { one }, isBusy: { true })
        #expect(c.handle(.timer, now: at(4), signature: { one }, isBusy: { false }) == [.act(previous: two, current: one)])
    }

    @Test func hardCapForcesEvaluation() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { false })
        for i in 1 ... 10 {
            _ = c.handle(.postConfiguration, now: at(TimeInterval(i) * 1.5), signature: { one }, isBusy: { false })
        }
        #expect(c.handle(.postConfiguration, now: at(21), signature: { one }, isBusy: { false }) == [.act(previous: two, current: one)])
    }

    @Test func sleepSuppressesAndWakeSettles() {
        var c = C(initial: two)
        #expect(c.handle(.willSleep, now: at(0), signature: { two }, isBusy: { false }) == [.cancelTimer])
        #expect(c.phase == .asleep)
        #expect(c.handle(.beginConfiguration, now: at(1), signature: { two }, isBusy: { false }) == [])
        #expect(c.handle(.postConfiguration, now: at(2), signature: { one }, isBusy: { false }) == [])
        #expect(c.handle(.didWake, now: at(60), signature: { one }, isBusy: { false }) == [.armTimer(C.wakeSettle)])
        #expect(!c.hasPreChange, "no pre-change snapshot during sleep: the rolling snapshot is the reference")
        #expect(c.handle(.timer, now: at(65), signature: { one }, isBusy: { false }) == [.act(previous: two, current: one)])
    }

    @Test func wakeWithoutChangeIsQuiet() {
        var c = C(initial: two)
        _ = c.handle(.willSleep, now: at(0), signature: { two }, isBusy: { false })
        _ = c.handle(.didWake, now: at(60), signature: { two }, isBusy: { false })
        #expect(c.handle(.timer, now: at(65), signature: { two }, isBusy: { false }) == [.armTimer(C.cooldown)])
    }

    @Test func changeDuringActionRequeues() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { false })
        _ = c.handle(.timer, now: at(3), signature: { one }, isBusy: { false })
        #expect(c.phase == .acting)
        #expect(c.handle(.beginConfiguration, now: at(3.5), signature: { one }, isBusy: { false }) == [])
        #expect(c.actionFinished(now: at(4), signature: two) == [.armTimer(C.debounce)])
        #expect(c.phase == .coalescing(since: at(4)))
        #expect(c.lastActed == two)
    }

    @Test func sleepDuringActionEndsAsleep() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { false })
        _ = c.handle(.timer, now: at(3), signature: { one }, isBusy: { false })
        _ = c.handle(.willSleep, now: at(3.5), signature: { one }, isBusy: { false })
        #expect(c.actionFinished(now: at(4), signature: one) == [.cancelTimer])
        #expect(c.phase == .asleep)
    }

    @Test func beginDuringCooldownCapturesAgain() {
        var c = C(initial: two)
        _ = c.handle(.beginConfiguration, now: at(0), signature: { two }, isBusy: { false })
        _ = c.handle(.timer, now: at(3), signature: { one }, isBusy: { false })
        _ = c.actionFinished(now: at(4), signature: one)
        #expect(c.handle(.beginConfiguration, now: at(5), signature: { one }, isBusy: { false }) == [.capturePreChange, .armTimer(C.debounce)])
        #expect(c.handle(.timer, now: at(8), signature: { two }, isBusy: { false }) == [.act(previous: one, current: two)])
    }

    @Test func separateSpacesToggleCountsAsChange() {
        var c = C(initial: two)
        let merged = C.Signature(keys: ["BI", "LG"], separateSpaces: false)
        _ = c.handle(.screenParametersChanged, now: at(0), signature: { two }, isBusy: { false })
        #expect(c.handle(.timer, now: at(3), signature: { merged }, isBusy: { false }) == [.act(previous: two, current: merged)])
    }
}
