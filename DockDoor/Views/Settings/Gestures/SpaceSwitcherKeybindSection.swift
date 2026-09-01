import Carbon.HIToolbox
import Defaults
import SwiftUI

struct SpaceSwitcherKeybindSection: View {
    @Default(.enableSpaceSwitcher) var enableSpaceSwitcher
    @Default(.spaceSwitcherMoveWindowKeyCode) var spaceSwitcherMoveWindowKeyCode
    @Default(.switcherBackwardKeyCode) var switcherBackwardKeyCode
    @Default(.windowSwitcherSelectionKeyCode) var selectionKeyCode
    @Default(.enableVimMotions) var enableVimMotions

    @State private var moveWindowKeyError: String?

    @StateObject private var keybindModel = KeybindModel(
        targetKey: .spaceSwitcherKeybind,
        validate: KeybindConflicts.validateSpaceSwitcherKeybind
    )

    var body: some View {
        SettingsGroup(header: "Space Switcher Shortcuts") {
            VStack(alignment: .leading, spacing: 12) {
                if !enableSpaceSwitcher {
                    SettingsWarningCallout("Space Switcher is disabled. Enable it in Space Switcher settings to use keyboard shortcuts.")
                }

                SwitcherShortcutEditor(
                    model: keybindModel,
                    defaultKeybind: UserKeyBind(keyCode: 48, modifierFlags: Defaults[.Int64maskAlternate]),
                    caption: "A modifier key is required — hold it to keep the switcher open, release it to switch to the selected Space."
                )
                .settingsSearchTarget("spaceSwitcher.keybind")
                .disabled(!enableSpaceSwitcher)
                .opacity(enableSpaceSwitcher ? 1.0 : 0.5)

                Divider()

                moveWindowKeySection
                    .disabled(!enableSpaceSwitcher)
                    .opacity(enableSpaceSwitcher ? 1.0 : 0.5)

                Divider()

                sharedKeysSection
                    .disabled(!enableSpaceSwitcher)
                    .opacity(enableSpaceSwitcher ? 1.0 : 0.5)
            }
            .settingsSearchTarget("gestures.spaceSwitcherKeybind")
        }
    }

    // MARK: - Move Window Key

    private var moveWindowKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Move Window Key")
                Spacer()
                KeyCaptureButton(keyCode: $spaceSwitcherMoveWindowKeyCode, validate: KeybindConflicts.validateSpaceMoveWindowKey, error: $moveWindowKeyError)
                Button("Reset") { spaceSwitcherMoveWindowKeyCode = UInt16(kVK_ANSI_M) }
                    .buttonStyle(.bordered)
            }
            .settingsSearchTarget("spaceSwitcher.moveWindowKey")
            if let moveWindowKeyError {
                SettingsWarningCallout(verbatim: moveWindowKeyError, style: .error)
            }
            Text("While the switcher is open, press this key to move the active window to the selected Space.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Shared keys

    private var sharedKeysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shared Keys").font(.headline)
            Text("Configured under Window Switcher Shortcuts above; they apply to both switchers.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                sharedKey("Backward", value: KeyboardLabel.localizedKey(for: switcherBackwardKeyCode))
                sharedKey("Select", value: KeyboardLabel.localizedKey(for: selectionKeyCode))
                sharedKey("Vim Motions", value: enableVimMotions ? String(localized: "On") : String(localized: "Off"))
            }

            SettingsNote(icon: "rectangle.slash", text: "The Fullscreen App Blacklist also applies to the Space Switcher shortcut.")
        }
    }

    private func sharedKey(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            KeyCapView(text: value, symbol: nil)
        }
    }
}
