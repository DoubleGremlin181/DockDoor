import AppKit

/// Feeds CoreGraphics reconfiguration callbacks, AppKit screen-parameter
/// notifications and sleep/wake into a `DisplayChangeCoalescer`, and runs
/// the effects it returns on the main thread.
@MainActor
final class DisplayReconfigurationObserver {
    struct Change {
        let removed: Set<String>
        let added: Set<String>
        let previous: DisplayChangeCoalescer.Signature
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
    private var observers: [NSObjectProtocol] = []
    private var registered = false

    init(signatureProvider: @escaping () -> DisplayChangeCoalescer.Signature) {
        self.signatureProvider = signatureProvider
        coalescer = DisplayChangeCoalescer(initial: signatureProvider())
    }

    func start() {
        guard !registered else { return }
        registered = true
        coalescer = DisplayChangeCoalescer(initial: signatureProvider())

        CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.screenParametersChanged) }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.willSleep) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.didWake) }
        })
    }

    func stop() {
        guard registered else { return }
        registered = false
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// The action started by `onAct` completed.
    func finishAction() {
        let effects = coalescer.actionFinished(now: Date(), signature: signatureProvider())
        run(effects)
    }

    func handle(_ event: DisplayChangeCoalescer.Event) {
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
                timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handle(.timer) }
                }
            case .cancelTimer:
                timer?.invalidate()
                timer = nil
            case let .act(previous, current):
                onAct(Change(
                    removed: previous.keys.subtracting(current.keys),
                    added: current.keys.subtracting(previous.keys),
                    previous: previous,
                    current: current
                ))
            case .becameIdle:
                onIdle()
            }
        }
    }

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard let userInfo else { return }
        let observer = Unmanaged<DisplayReconfigurationObserver>.fromOpaque(userInfo).takeUnretainedValue()
        let event: DisplayChangeCoalescer.Event = flags.contains(.beginConfigurationFlag) ? .beginConfiguration : .postConfiguration
        if Thread.isMainThread {
            MainActor.assumeIsolated { observer.handle(event) }
        } else {
            DispatchQueue.main.async { observer.handle(event) }
        }
    }
}
