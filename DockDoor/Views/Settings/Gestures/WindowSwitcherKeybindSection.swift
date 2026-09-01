import Carbon.HIToolbox
import Defaults
import SwiftUI

struct WindowSwitcherKeybindSection: View {
    @Default(.enableWindowSwitcher) var enableWindowSwitcher
    @Default(.enableSpaceSwitcher) var enableSpaceSwitcher
    @Default(.enableWindowSwitcherSearch) var enableWindowSwitcherSearch
    @Default(.searchTriggerKey) var searchTriggerKey
    @Default(.fullscreenAppBlacklist) var fullscreenAppBlacklist
    @Default(.alternateKeybindKey) var alternateKeybindKey
    @Default(.alternateKeybindMode) var alternateKeybindMode
    @Default(.requireShiftTabToGoBack) var requireShiftTabToGoBack
    @Default(.switcherBackwardKeyCode) var switcherBackwardKeyCode
    @Default(.windowSwitcherSelectionKeyCode) var selectionKeyCode
    @Default(.enableVimMotions) var enableVimMotions
    @Default(.passArrowsThroughToSystem) var passArrowsThroughToSystem

    @StateObject private var keybindModel = KeybindModel(validate: KeybindConflicts.validateWindowSwitcherKeybind)
    @State private var showingAddBlacklistAppSheet = false
    @State private var newBlacklistApp = ""
    @State private var vimMotionsError: String?
    @State private var backwardKeyError: String?
    @State private var selectionKeyError: String?
    @State private var alternateKeyError: String?

    /// Backward key, selection key and Vim motions are shared with the Space Switcher.
    private var anySwitcherEnabled: Bool {
        enableWindowSwitcher || enableSpaceSwitcher
    }

    var body: some View {
        SettingsGroup(header: "Window Switcher Shortcuts") {
            VStack(alignment: .leading, spacing: 12) {
                if !enableWindowSwitcher {
                    SettingsWarningCallout("Window Switcher is disabled. Enable it in Window Switcher settings to use keyboard shortcuts.")
                }

                keyboardShortcutSection
                    .disabled(!enableWindowSwitcher)
                    .opacity(enableWindowSwitcher ? 1.0 : 0.5)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Backward Key")
                        Spacer()
                        KeyCaptureButton(keyCode: $switcherBackwardKeyCode, captureModifiers: true, validate: KeybindConflicts.validateBackwardKey, error: $backwardKeyError)
                        Button("Reset") { switcherBackwardKeyCode = 56 }
                            .buttonStyle(.bordered)
                    }
                    .settingsSearchTarget("gestures.backwardKey")
                    if let backwardKeyError {
                        SettingsWarningCallout(verbatim: backwardKeyError, style: .error)
                    }
                    Text("The key used to navigate backward in the Window and Space Switchers.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(isOn: $requireShiftTabToGoBack) {
                        Text("Require \(KeyboardLabel.localizedKey(for: switcherBackwardKeyCode))+Tab to go back in Switcher")
                    }
                    .settingsSearchTarget("gestures.requireShiftTab")
                    .disabled(!enableWindowSwitcher)
                    Text("When enabled, pressing the backward key alone won't go back in the Window Switcher. Use it with Tab to navigate backward.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
                .disabled(!anySwitcherEnabled)
                .opacity(anySwitcherEnabled ? 1.0 : 0.5)

                Divider()

                selectionKeySection
                    .disabled(!anySwitcherEnabled)
                    .opacity(anySwitcherEnabled ? 1.0 : 0.5)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { enableVimMotions },
                        set: { newValue in
                            if newValue, let reason = KeybindConflicts.validateEnablingVimMotions() {
                                vimMotionsError = reason
                                return
                            }
                            vimMotionsError = nil
                            enableVimMotions = newValue
                        }
                    )) {
                        Text("Enable Vim Motions")
                    }
                    .settingsSearchTarget("gestures.vimMotions")
                    Text("Use H/J/K/L keys to navigate left/down/up/right in the Window and Space Switchers. Disabled while search is focused.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                    if let vimMotionsError {
                        SettingsWarningCallout(verbatim: vimMotionsError, style: .error)
                    }

                    Toggle(isOn: $passArrowsThroughToSystem) {
                        Text("Pass Arrow Keys Through to System")
                    }
                    .settingsSearchTarget("gestures.arrowPassthrough")
                    .disabled(!enableWindowSwitcher)
                    Text("When enabled, Ctrl+Arrow keys will be passed through to the system instead of navigating the Window Switcher. Useful for Spaces switching.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)
                }
                .disabled(!anySwitcherEnabled)
                .opacity(anySwitcherEnabled ? 1.0 : 0.5)

                Divider()

                alternateShortcutsSection
                    .disabled(!enableWindowSwitcher)
                    .opacity(enableWindowSwitcher ? 1.0 : 0.5)

                if enableWindowSwitcherSearch {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search Trigger Key").font(.headline)
                        Text("The key that activates search while the window switcher is open.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            Text(modifierConverter.toString(keybindModel.modifierKey))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("+")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)

                            KeyCaptureButton(keyCode: $searchTriggerKey)
                        }
                    }
                    .settingsSearchTarget("gestures.searchTriggerKey")
                    .disabled(!enableWindowSwitcher)
                    .opacity(enableWindowSwitcher ? 1.0 : 0.5)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fullscreen App Blacklist").font(.headline)
                    Text("Apps in this list will not respond to window switcher shortcuts when in fullscreen mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    fullscreenAppBlacklistView
                }
                .settingsSearchTarget("gestures.fullscreenBlacklist")
            }
            .settingsSearchTarget("gestures.switcherKeybind")
        }
    }

    // MARK: - Keyboard Shortcut Section

    private var keyboardShortcutSection: some View {
        SwitcherShortcutEditor(
            model: keybindModel,
            defaultKeybind: UserKeyBind(keyCode: 48, modifierFlags: Defaults[.Int64maskAlternate]),
            caption: "Either left or right Command, Option, or Control keys work. You can also hold the modifier while pressing the trigger to capture both."
        )
    }

    // MARK: - Selection Key Section

    private var selectionKeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selection Key")
                Spacer()
                KeyCaptureButton(keyCode: $selectionKeyCode, validate: KeybindConflicts.validateSelectionKey, error: $selectionKeyError)
                Button("Reset") { selectionKeyCode = UInt16(kVK_Return) }
                    .buttonStyle(.bordered)
            }
            .settingsSearchTarget("gestures.selectionKey")
            if let selectionKeyError {
                SettingsWarningCallout(verbatim: selectionKeyError, style: .error)
            }
            Text("The key used to confirm the highlighted window or Space in the Window and Space Switchers.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Alternate Shortcuts Section

    private var alternateShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Alternate Shortcut").font(.headline)
            Text("An additional trigger key using the same modifier, invoking the switcher with a different filter mode.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                // Modifier display (from primary keybind)
                Text(modifierConverter.toString(keybindModel.modifierKey))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("+")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                KeyCaptureButton(keyCode: $alternateKeybindKey, emptyLabel: "Not set", validate: { KeybindConflicts.validateAlternateKey($0, modifier: keybindModel.modifierKey) }, error: $alternateKeyError)

                if alternateKeybindKey != 0 {
                    Button("Clear") {
                        alternateKeybindKey = 0
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Picker("Mode", selection: $alternateKeybindMode) {
                    ForEach(SwitcherInvocationMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            if let alternateKeyError {
                SettingsWarningCallout(verbatim: alternateKeyError, style: .error)
            }
        }
        .settingsSearchTarget("gestures.alternateShortcut")
    }

    // MARK: - Fullscreen App Blacklist

    private var fullscreenAppBlacklistView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !fullscreenAppBlacklist.isEmpty {
                        ForEach(fullscreenAppBlacklist, id: \.self) { appName in
                            HStack {
                                Text(appName)
                                    .foregroundColor(.primary)

                                Spacer()

                                Button(action: {
                                    fullscreenAppBlacklist.removeAll { $0 == appName }
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)

                            if appName != fullscreenAppBlacklist.last {
                                Divider()
                            }
                        }
                    } else {
                        Text("No apps in blacklist")
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(8)
            }
            .frame(maxHeight: 120)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
            )

            HStack {
                Button(action: { showingAddBlacklistAppSheet.toggle() }) {
                    Text("Add App")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(!enableWindowSwitcher)

                Spacer()

                if !fullscreenAppBlacklist.isEmpty {
                    DangerButton(action: {
                        fullscreenAppBlacklist.removeAll()
                    }) {
                        Text("Remove All")
                    }
                    .disabled(!enableWindowSwitcher)
                }
            }
        }
        .sheet(isPresented: $showingAddBlacklistAppSheet) {
            AddBlacklistAppSheet(
                isPresented: $showingAddBlacklistAppSheet,
                appNameToAdd: $newBlacklistApp,
                onAdd: { appName in
                    if !appName.isEmpty, !fullscreenAppBlacklist.contains(where: { $0.caseInsensitiveCompare(appName) == .orderedSame }) {
                        fullscreenAppBlacklist.append(appName)
                    }
                }
            )
        }
    }
}
