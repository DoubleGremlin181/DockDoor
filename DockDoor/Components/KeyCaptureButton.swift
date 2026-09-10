import Carbon.HIToolbox.Events
import SwiftUI

struct KeyCaptureButton: View {
    @Binding var keyCode: UInt16
    var emptyLabel: String?
    var captureModifiers: Bool = false
    /// Returns a localized reason to refuse the pressed key, or nil to accept it.
    var validate: ((UInt16) -> String?)?
    /// When provided, the refusal reason is published here for the parent to
    /// render (keeps the button in line with its row); otherwise it is shown inline.
    var error: Binding<String?>?
    var allowsEscape: Bool = false

    @State private var isCapturing = false
    @State private var monitors: [Any] = []
    @State private var inlineError: String?

    private func setError(_ message: String?) {
        if let error {
            error.wrappedValue = message
        } else {
            inlineError = message
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            captureControl
            if error == nil, let inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onChange(of: keyCode) { _ in setError(nil) }
    }

    @ViewBuilder
    private var captureControl: some View {
        if isCapturing {
            Text("Press a key…")
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(minWidth: 50)
                .onDisappear {
                    stopCapture()
                }
        } else {
            Button(action: startCapture) {
                Text(displayLabel)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(keyCode == 0 && emptyLabel != nil ? 0.1 : 0.2))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
    }

    private var displayLabel: String {
        if keyCode == 0, let emptyLabel {
            return emptyLabel
        }
        return KeyboardLabel.localizedKey(for: keyCode)
    }

    /// Stores the key unless `validate` refuses it, in which case the previous
    /// value is kept and the reason is shown under the button.
    private func accept(_ newKeyCode: UInt16) {
        if let reason = validate?(newKeyCode) {
            setError(reason)
            return
        }
        setError(nil)
        keyCode = newKeyCode
    }

    private func stopCapture() {
        isCapturing = false
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    private func startCapture() {
        stopCapture()
        setError(nil)
        isCapturing = true

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape), !allowsEscape {
                stopCapture()
                return nil
            }
            accept(event.keyCode)
            stopCapture()
            return nil
        }!)

        if captureModifiers {
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
                if modifierKeyCodes.contains(event.keyCode) {
                    accept(event.keyCode)
                    stopCapture()
                }
                return event
            }!)
        }
    }
}
