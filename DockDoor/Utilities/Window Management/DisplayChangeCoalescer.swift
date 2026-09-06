import Foundation

/// Turns the burst of display reconfiguration callbacks, screen-parameter
/// notifications and sleep/wake into at most one "the set of displays
/// changed" action, taken only once the window server has settled. Pure:
/// the owner supplies the clock, the current display signature and a
/// busy probe, and executes the returned effects.
struct DisplayChangeCoalescer {
    struct Signature: Equatable, Hashable {
        var keys: Set<String>
        var separateSpaces: Bool
    }

    enum Event: Equatable {
        case beginConfiguration
        case postConfiguration
        case screenParametersChanged
        case willSleep
        case didWake
        case timer
    }

    enum Effect: Equatable {
        /// Copy the memory (learned map, space table, frames) before the
        /// switcher's relearn prunes desktops that just died
        case capturePreChange
        case armTimer(TimeInterval)
        case cancelTimer
        case act(previous: Signature, current: Signature)
        /// Back to idle: the space table may be refreshed again
        case becameIdle
    }

    enum Phase: Equatable {
        case idle
        case coalescing(since: Date)
        case waitingForQuiescence(attempt: Int)
        case acting
        case asleep
        case cooldown
    }

    static let debounce: TimeInterval = 1.0
    static let hardCap: TimeInterval = 20
    static let quiescenceLadder: [TimeInterval] = [1.5, 3.5, 8]
    static let cooldown: TimeInterval = 3
    static let wakeSettle: TimeInterval = 5

    private(set) var phase: Phase = .idle
    private(set) var lastActed: Signature
    /// A pre-change snapshot was captured for the burst in progress
    private(set) var hasPreChange = false
    private var changeDuringAction = false
    private var sleepDuringAction = false

    init(initial: Signature) {
        lastActed = initial
    }

    var isIdle: Bool { phase == .idle }

    mutating func handle(_ event: Event, now: Date, signature: () -> Signature, isBusy: () -> Bool) -> [Effect] {
        switch (phase, event) {
        case (.asleep, .didWake):
            phase = .coalescing(since: now)
            return [.armTimer(Self.wakeSettle)]
        case (.asleep, .beginConfiguration), (.asleep, .postConfiguration), (.asleep, .screenParametersChanged):
            // Displays leave while asleep; the switcher's relearn would prune
            // their desktops from the learned map long before wake settles,
            // so copy the memory at the first sign of change.
            return capturePreChangeOnce()
        case (.asleep, .timer), (.asleep, .willSleep):
            return []
        case (.acting, .willSleep):
            sleepDuringAction = true
            return []
        case (_, .willSleep):
            phase = .asleep
            return [.cancelTimer]
        case (.acting, .beginConfiguration), (.acting, .postConfiguration), (.acting, .screenParametersChanged), (.acting, .didWake):
            changeDuringAction = true
            return []
        case (.acting, .timer):
            return []
        case (.idle, .beginConfiguration), (.idle, .postConfiguration), (.idle, .screenParametersChanged), (.idle, .didWake),
             (.cooldown, .beginConfiguration), (.cooldown, .postConfiguration), (.cooldown, .screenParametersChanged), (.cooldown, .didWake):
            // Whatever the first event of a burst is: on a real unplug the
            // window server has already migrated Spaces by the time the
            // "begin" callback fires, so nothing is gained by waiting for it.
            phase = .coalescing(since: now)
            return capturePreChangeOnce() + [.armTimer(Self.debounce)]
        case (.idle, .timer):
            return []
        case (.cooldown, .timer):
            phase = .idle
            return [.becameIdle]
        case let (.coalescing(since), .beginConfiguration), let (.coalescing(since), .postConfiguration),
             let (.coalescing(since), .screenParametersChanged), let (.coalescing(since), .didWake):
            if now.timeIntervalSince(since) >= Self.hardCap {
                return evaluate(now: now, signature: signature, isBusy: isBusy)
            }
            return capturePreChangeOnce() + [.armTimer(Self.debounce)]
        case (.coalescing, .timer):
            return evaluate(now: now, signature: signature, isBusy: isBusy)
        case (.waitingForQuiescence, .beginConfiguration), (.waitingForQuiescence, .postConfiguration),
             (.waitingForQuiescence, .screenParametersChanged), (.waitingForQuiescence, .didWake):
            phase = .coalescing(since: now)
            return [.armTimer(Self.debounce)]
        case let (.waitingForQuiescence(attempt), .timer):
            if !isBusy() || attempt >= Self.quiescenceLadder.count {
                return beginAction(signature: signature())
            }
            phase = .waitingForQuiescence(attempt: attempt + 1)
            return [.armTimer(Self.quiescenceLadder[attempt])]
        }
    }

    private mutating func capturePreChangeOnce() -> [Effect] {
        guard !hasPreChange else { return [] }
        hasPreChange = true
        return [.capturePreChange]
    }

    /// The owner finished the action started by `.act`.
    mutating func actionFinished(now: Date, signature: Signature) -> [Effect] {
        lastActed = signature
        hasPreChange = false
        if sleepDuringAction {
            sleepDuringAction = false
            changeDuringAction = false
            phase = .asleep
            return [.cancelTimer]
        }
        if changeDuringAction {
            changeDuringAction = false
            phase = .coalescing(since: now)
            return [.armTimer(Self.debounce)]
        }
        phase = .cooldown
        return [.armTimer(Self.cooldown)]
    }

    private mutating func evaluate(now: Date, signature: () -> Signature, isBusy: () -> Bool) -> [Effect] {
        let current = signature()
        if current == lastActed {
            hasPreChange = false
            phase = .cooldown
            return [.armTimer(Self.cooldown)]
        }
        if !isBusy() {
            return beginAction(signature: current)
        }
        phase = .waitingForQuiescence(attempt: 1)
        return [.armTimer(Self.quiescenceLadder[0])]
    }

    private mutating func beginAction(signature: Signature) -> [Effect] {
        phase = .acting
        changeDuringAction = false
        return [.act(previous: lastActed, current: signature)]
    }
}
