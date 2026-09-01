import AppKit
import Carbon
import Defaults
import SwiftUI

class KeybindModel: ObservableObject {
    let targetKey: Defaults.Key<UserKeyBind>
    @Published var modifierKey: Int
    @Published var isRecording: Bool = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording {
                recorderToken = ShortcutRecorder.shared.begin { [weak self] capture in
                    guard let self, isRecording else { return }
                    isRecording = false
                    if let capture {
                        record(keyCode: capture.keyCode, command: capture.flags.contains(.maskCommand),
                               option: capture.flags.contains(.maskAlternate), control: capture.flags.contains(.maskControl))
                    }
                }
            } else if let recorderToken {
                ShortcutRecorder.shared.end(recorderToken)
                self.recorderToken = nil
            }
        }
    }

    @Published var currentKeybind: UserKeyBind?
    /// Reason the last capture / modifier change / reset was refused; nil once a value is accepted.
    @Published var captureError: String?
    /// Returns a localized reason to refuse `bind`, or nil to accept it.
    let validate: (UserKeyBind) -> String?

    private var recorderToken: ShortcutRecorder.Token?
    private var focusObservers: [NSObjectProtocol] = []

    init(targetKey: Defaults.Key<UserKeyBind> = .UserKeybind, validate: @escaping (UserKeyBind) -> String? = { _ in nil }) {
        self.targetKey = targetKey
        self.validate = validate
        modifierKey = Defaults[targetKey].modifierFlags
        currentKeybind = Defaults[targetKey]
        // Recording goes through the global event tap; stop when the settings
        // window loses focus so chords typed elsewhere are never captured.
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.cancelRecording()
            })
        }
    }

    /// Applies `bind` if it passes validation; otherwise records the reason and
    /// leaves the stored shortcut untouched. Returns whether it was applied.
    @discardableResult
    func apply(_ bind: UserKeyBind) -> Bool {
        if let reason = validate(bind) {
            captureError = reason
            // Keep the picker in sync with the stored value if a modifier change was refused.
            if let current = currentKeybind, modifierKey != current.modifierFlags {
                modifierKey = current.modifierFlags
            }
            return false
        }
        captureError = nil
        Defaults[targetKey] = bind
        currentKeybind = bind
        modifierKey = bind.modifierFlags
        return true
    }

    /// A chord was captured. Exactly one of ⌘/⌥/⌃ held becomes the initializer;
    /// otherwise the currently selected initializer is kept.
    func record(keyCode: UInt16, command: Bool, option: Bool, control: Bool) {
        var modifier = modifierKey
        if [command, option, control].filter({ $0 }).count == 1 {
            if command {
                modifier = Defaults[.Int64maskCommand]
            } else if option {
                modifier = Defaults[.Int64maskAlternate]
            } else {
                modifier = Defaults[.Int64maskControl]
            }
        }
        apply(UserKeyBind(keyCode: keyCode, modifierFlags: modifier))
    }

    func cancelRecording() {
        isRecording = false
    }

    deinit {
        for observer in focusObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let recorderToken {
            ShortcutRecorder.shared.end(recorderToken)
        }
    }

    /// Modifier picker changed: re-bind the current trigger key with the new modifier.
    func changeModifier(to modifier: Int) {
        guard let current = currentKeybind, current.keyCode != 0, current.modifierFlags != modifier else { return }
        apply(UserKeyBind(keyCode: current.keyCode, modifierFlags: modifier))
    }

    func reset(to bind: UserKeyBind) {
        apply(bind)
    }

    func syncFromDefaults() {
        captureError = nil
        currentKeybind = Defaults[targetKey]
        modifierKey = Defaults[targetKey].modifierFlags
    }
}

struct KeyCapView: View {
    let text: String
    let symbol: String?

    var body: some View {
        HStack {
            if let symbol, !symbol.isEmpty {
                Image(systemName: symbol)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.2))
        .cornerRadius(4)
    }
}

class ShortcutCaptureViewController: NSViewController {
    weak var coordinator: ShortcutCaptureView.Coordinator?

    override func loadView() {
        view = NSView()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if coordinator?.parent.isRecording ?? false {
            DispatchQueue.main.async {
                self.view.window?.makeFirstResponder(self.view)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.handleKeyEvent(event)
    }
}

struct ShortcutCaptureView: NSViewControllerRepresentable {
    typealias NSViewControllerType = ShortcutCaptureViewController
    @Binding var currentKeybind: UserKeyBind?
    @Binding var isRecording: Bool
    @Binding var modifierKey: Int
    var targetKey: Defaults.Key<UserKeyBind> = .UserKeybind
    /// Validation + persistence; when nil the capture writes straight to `targetKey`.
    var model: KeybindModel?

    class Coordinator: NSObject {
        var parent: ShortcutCaptureView

        init(_ parent: ShortcutCaptureView) {
            self.parent = parent
        }

        func handleKeyEvent(_ event: NSEvent) {
            guard parent.isRecording else { return }

            if event.type == .keyDown {
                let isModifierKeyAlone = (
                    event.keyCode == kVK_Shift || event.keyCode == kVK_RightShift ||
                        event.keyCode == kVK_Control || event.keyCode == kVK_RightControl ||
                        event.keyCode == kVK_Option || event.keyCode == kVK_RightOption ||
                        event.keyCode == kVK_Command || event.keyCode == kVK_RightCommand ||
                        event.keyCode == kVK_Function // Fn key
                ) && event.charactersIgnoringModifiers?.isEmpty == true

                if isModifierKeyAlone {
                    return
                }

                parent.isRecording = false
                if event.keyCode == kVK_Escape {
                    DispatchQueue.main.async { event.window?.makeFirstResponder(nil) }
                    return
                }
                // If user is holding exactly one of Command/Option/Control while recording,
                // capture that as the initializer modifier automatically.
                let flags = event.modifierFlags
                let wantsCmd = flags.contains(.command)
                let wantsOpt = flags.contains(.option)
                let wantsCtrl = flags.contains(.control)
                if let model = parent.model {
                    model.record(keyCode: UInt16(event.keyCode), command: wantsCmd, option: wantsOpt, control: wantsCtrl)
                } else {
                    let count = [wantsCmd, wantsOpt, wantsCtrl].filter { $0 }.count
                    var capturedModifier = parent.modifierKey
                    if count == 1 {
                        if wantsCmd {
                            capturedModifier = Defaults[.Int64maskCommand]
                        } else if wantsOpt {
                            capturedModifier = Defaults[.Int64maskAlternate]
                        } else if wantsCtrl {
                            capturedModifier = Defaults[.Int64maskControl]
                        }
                    }
                    let newKeybind = UserKeyBind(keyCode: UInt16(event.keyCode), modifierFlags: capturedModifier)
                    Defaults[parent.targetKey] = newKeybind
                    parent.currentKeybind = newKeybind
                    parent.modifierKey = capturedModifier
                }
                DispatchQueue.main.async {
                    event.window?.makeFirstResponder(nil)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSViewController(context: Context) -> ShortcutCaptureViewController {
        let viewController = ShortcutCaptureViewController()
        viewController.coordinator = context.coordinator
        return viewController
    }

    func updateNSViewController(_ nsViewController: ShortcutCaptureViewController, context: Context) {
        if isRecording {
            DispatchQueue.main.async {
                if nsViewController.view.window?.firstResponder != nsViewController.view {
                    nsViewController.view.window?.makeFirstResponder(nsViewController.view)
                }
            }
        } else {
            if nsViewController.view.window?.firstResponder == nsViewController.view {
                DispatchQueue.main.async {
                    nsViewController.view.window?.makeFirstResponder(nil)
                }
            }
        }
    }
}

/// Primary-shortcut editor shared by the Window Switcher and Space Switcher
/// shortcut groups: keycap summary, initializer picker, record and reset
/// buttons, and the validation error from the model.
struct SwitcherShortcutEditor: View {
    @ObservedObject var model: KeybindModel
    let defaultKeybind: UserKeyBind
    let caption: LocalizedStringKey
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let keybind = model.currentKeybind, keybind.keyCode != 0 {
                HStack(spacing: 8) {
                    KeyCapView(text: modifierConverter.toString(keybind.modifierFlags), symbol: nil)
                    Text("+").foregroundColor(.secondary)
                    KeyCapView(text: KeyboardLabel.localizedKey(for: keybind.keyCode), symbol: nil)
                }
            } else {
                Text("No shortcut set").foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Picker("Initializer", selection: $model.modifierKey) {
                    Text("Control ⌃").tag(Defaults[.Int64maskControl])
                    Text("Option ⌥").tag(Defaults[.Int64maskAlternate])
                    Text("Command ⌘").tag(Defaults[.Int64maskCommand])
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: model.modifierKey) { newValue in
                    model.changeModifier(to: newValue)
                }

                Button(action: { model.isRecording.toggle() }) {
                    HStack {
                        Image(systemName: model.isRecording ? "keyboard.fill" : "record.circle")
                        Text(model.isRecording ? "Press shortcut… (click or Esc to cancel)" : "Change…")
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Reset") {
                    model.cancelRecording()
                    model.reset(to: defaultKeybind)
                }
                .buttonStyle(.bordered)
            }

            if isEnabled, let error = model.captureError {
                SettingsWarningCallout(verbatim: error, style: .error)
            }

            Text(caption)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .background(
            ShortcutCaptureView(
                currentKeybind: $model.currentKeybind,
                isRecording: $model.isRecording,
                modifierKey: $model.modifierKey,
                targetKey: model.targetKey,
                model: model
            )
            .allowsHitTesting(false)
            .frame(width: 0, height: 0)
        )
        .onAppear { model.syncFromDefaults() }
        .onDisappear { model.cancelRecording() }
        .onChange(of: isEnabled) { enabled in
            if !enabled {
                model.cancelRecording()
            }
        }
    }
}
