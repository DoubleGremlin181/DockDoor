import AppKit

/// Feeds `SpaceTopology`'s display, screen-parameter and sleep/wake events
/// into a `DisplayChangeCoalescer` and runs the effects it returns on the
/// main thread.
@MainActor
final class DisplayReconfigurationObserver {
    struct Change {
        let removed: Set<String>
        let added: Set<String>
        let current: DisplayChangeCoalescer.Signature
    }

    var signatureProvider: () -> DisplayChangeCoalescer.Signature
    var busyProvider: () -> Bool = { false }
    var onCapturePreChange: () -> Void = {}
    /// Must call `finishAction()` when done (possibly after awaiting)
    var onAct: (Change) -> Void = { _ in }
    var onIdle: () -> Void = {}

    private(set) var coalescer: DisplayChangeCoalescer
    private var timer: Timer?
    private var subscription: UUID?

    init(signatureProvider: @escaping () -> DisplayChangeCoalescer.Signature) {
        self.signatureProvider = signatureProvider
        coalescer = DisplayChangeCoalescer(initial: signatureProvider())
    }

    var isRunning: Bool { subscription != nil }

    func start() {
        guard subscription == nil else { return }
        coalescer = DisplayChangeCoalescer(initial: signatureProvider())
        subscription = SpaceTopology.shared.subscribe { [weak self] event in
            guard let self else { return }
            let mapped: DisplayChangeCoalescer.Event? = switch event {
            case .displaysWillChange: .beginConfiguration
            case .displaysChanged: .postConfiguration
            case .screenParametersChanged: .screenParametersChanged
            case .willSleep: .willSleep
            case .didWake: .didWake
            case .activeSpaceChanged: nil
            }
            if let mapped {
                MainActor.assumeIsolated { self.handle(mapped) }
            }
        }
    }

    func stop() {
        guard let subscription else { return }
        SpaceTopology.shared.unsubscribe(subscription)
        self.subscription = nil
        timer?.invalidate()
        timer = nil
    }

    // No deinit cleanup: the owner must stop() before releasing (the
    // subscription would otherwise outlive the observer, harmlessly weak).

    /// The action started by `onAct` completed.
    func finishAction() {
        guard isRunning else { return }
        run(coalescer.actionFinished(now: Date(), signature: signatureProvider()))
    }

    func handle(_ event: DisplayChangeCoalescer.Event) {
        guard isRunning else { return }
        let effects = coalescer.handle(event, now: Date(), signature: signatureProvider, isBusy: busyProvider)
        DebugLogger.log("DisplayLayoutMemory", details: "event \(event) → \(coalescer.phase) \(effects)")
        run(effects)
    }

    private func run(_ effects: [DisplayChangeCoalescer.Effect]) {
        for effect in effects {
            switch effect {
            case .capturePreChange:
                onCapturePreChange()
            case let .armTimer(delay):
                timer?.invalidate()
                // Common modes: a menu or window drag right after plugging in
                // must not stall the settle timer.
                let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handle(.timer) }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            case .cancelTimer:
                timer?.invalidate()
                timer = nil
            case let .act(previous, current):
                onAct(Change(removed: previous.keys.subtracting(current.keys), added: current.keys.subtracting(previous.keys), current: current))
            case .becameIdle:
                onIdle()
            }
        }
    }
}
