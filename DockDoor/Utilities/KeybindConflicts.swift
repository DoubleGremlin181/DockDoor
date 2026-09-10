import Carbon.HIToolbox
import Defaults
import Foundation

/// Single source of truth for shortcut overlap between the Window Switcher and
/// the Space Switcher. Settings use the `validate*` functions to refuse input
/// that would persist an overlapping state; the event tap uses
/// `windowSwitcherClaims` as a defensive fallback for values written outside
/// the UI.
enum KeybindConflicts {
    // MARK: - Runtime precedence

    /// True when the Window Switcher (primary or alternate shortcut) owns `bind`.
    static func windowSwitcherClaims(_ bind: UserKeyBind) -> Bool {
        guard Defaults[.enableWindowSwitcher] else { return false }
        let primary = Defaults[.UserKeybind]
        if sameChord(bind, primary) {
            return true
        }
        if let alternate = alternateKeybind(primaryModifier: primary.modifierFlags) {
            return sameChord(bind, alternate)
        }
        return false
    }

    /// The alternate shortcut as a full chord: its own modifier when set,
    /// otherwise the Window Switcher's primary modifier.
    static func alternateKeybind(primaryModifier: Int = Defaults[.UserKeybind].modifierFlags) -> UserKeyBind? {
        let key = Defaults[.alternateKeybindKey]
        guard key != 0 else { return nil }
        return UserKeyBind(keyCode: key, modifierFlags: effectiveAlternateModifier(primaryModifier: primaryModifier))
    }

    static func effectiveAlternateModifier(primaryModifier: Int = Defaults[.UserKeybind].modifierFlags) -> Int {
        let modifier = Defaults[.alternateKeybindModifierFlags]
        return modifier == 0 ? primaryModifier : modifier
    }

    // MARK: - Shortcut validation (nil = accepted)

    static func validateSpaceSwitcherKeybind(_ bind: UserKeyBind) -> String? {
        guard bind.modifierFlags != 0 else {
            return String(localized: "The Space Switcher shortcut needs a modifier key.", comment: "Keybind validation error")
        }
        if windowSwitcherClaims(bind) {
            return String(localized: "\(describe(bind)) is already used by the Window Switcher. Choose a different shortcut.", comment: "Keybind validation error")
        }
        return nil
    }

    /// Validates a new Window Switcher primary shortcut; when the alternate key
    /// shares its modifier ("Same as main"), the alternate chord is checked too.
    static func validateWindowSwitcherKeybind(_ bind: UserKeyBind) -> String? {
        if Defaults[.alternateKeybindModifierFlags] != 0, let alternate = alternateKeybind(primaryModifier: bind.modifierFlags), sameChord(bind, alternate) {
            return String(localized: "The primary shortcut can't be the same as the alternate shortcut.", comment: "Keybind validation error")
        }
        guard Defaults[.enableSpaceSwitcher] else { return nil }
        let space = Defaults[.spaceSwitcherKeybind]
        if sameChord(bind, space) {
            return String(localized: "\(describe(bind)) is already used by the Space Switcher. Choose a different shortcut.", comment: "Keybind validation error")
        }
        if Defaults[.alternateKeybindModifierFlags] == 0,
           let alternate = alternateKeybind(primaryModifier: bind.modifierFlags), sameChord(alternate, space)
        {
            return String(localized: "With this modifier the alternate shortcut \(describe(space)) would collide with the Space Switcher. Change the alternate key first.", comment: "Keybind validation error")
        }
        return nil
    }

    /// `modifier` is the alternate shortcut's effective modifier (its own, or the
    /// Window Switcher's when set to "Same as main").
    static func validateAlternateKey(_ key: UInt16, modifier: Int) -> String? {
        guard key != 0 else { return nil }
        let bind = UserKeyBind(keyCode: key, modifierFlags: modifier)
        if sameChord(bind, Defaults[.UserKeybind]) {
            return String(localized: "The alternate shortcut can't be the same as the primary shortcut.", comment: "Keybind validation error")
        }
        if Defaults[.enableSpaceSwitcher], sameChord(bind, Defaults[.spaceSwitcherKeybind]) {
            return String(localized: "\(describe(bind)) is already used by the Space Switcher. Choose a different key.", comment: "Keybind validation error")
        }
        return nil
    }

    /// Changing the alternate shortcut's modifier while a key is set.
    static func validateAlternateModifier(_ modifier: Int, primaryModifier: Int) -> String? {
        let key = Defaults[.alternateKeybindKey]
        guard key != 0 else { return nil }
        return validateAlternateKey(key, modifier: modifier == 0 ? primaryModifier : modifier)
    }

    /// Keys the Space Switcher consumes while a session is open.
    static func validateSpaceMoveWindowKey(_ key: UInt16) -> String? {
        if key == Defaults[.spaceSwitcherKeybind].keyCode {
            return String(localized: "That key is the Space Switcher trigger key.", comment: "Keybind validation error")
        }
        if key == UInt16(kVK_Escape) {
            return String(localized: "Escape always dismisses the switcher.", comment: "Keybind validation error")
        }
        if key == Defaults[.windowSwitcherSelectionKeyCode] || key == UInt16(kVK_Return) || key == UInt16(kVK_ANSI_KeypadEnter) {
            return String(localized: "That key is the Selection Key.", comment: "Keybind validation error")
        }
        if key == Defaults[.switcherBackwardKeyCode], !isModifierKeyCode(key) {
            return String(localized: "That key is the Backward Key.", comment: "Keybind validation error")
        }
        if arrowKeyCodes.contains(key) {
            return String(localized: "Arrow keys navigate the switcher.", comment: "Keybind validation error")
        }
        if Defaults[.enableVimMotions], vimKeyCodes.contains(key) {
            return String(localized: "H, J, K and L are reserved while Vim Motions are enabled.", comment: "Keybind validation error")
        }
        return nil
    }

    static func validateSelectionKey(_ key: UInt16) -> String? {
        sharedSessionKeyReason(key)
    }

    static func validateBackwardKey(_ key: UInt16) -> String? {
        if isModifierKeyCode(key) {
            return nil
        }
        return sharedSessionKeyReason(key)
    }

    /// Enabling Vim Motions while the move-window key is one of H/J/K/L.
    static func validateEnablingVimMotions() -> String? {
        guard Defaults[.enableSpaceSwitcher], vimKeyCodes.contains(Defaults[.spaceSwitcherMoveWindowKeyCode]) else { return nil }
        return String(localized: "The Space Switcher's Move Window Key is one of H/J/K/L. Change it before enabling Vim Motions.", comment: "Keybind validation error")
    }

    // MARK: - Auto-resolution when a feature is enabled

    /// If the stored Space Switcher shortcut is claimed by the Window Switcher,
    /// move it to the first free modifier among Option, Control, Command with the
    /// same trigger key. Returns the new shortcut when a change was made.
    @discardableResult
    static func resolveSpaceKeybindOnEnable() -> UserKeyBind? {
        let current = Defaults[.spaceSwitcherKeybind]
        guard current.modifierFlags == 0 || windowSwitcherClaims(current) else { return nil }
        let key = current.keyCode != 0 ? current.keyCode : UInt16(kVK_Tab)
        for modifier in [Defaults[.Int64maskAlternate], Defaults[.Int64maskControl], Defaults[.Int64maskCommand]] {
            let candidate = UserKeyBind(keyCode: key, modifierFlags: modifier)
            if validateSpaceSwitcherKeybind(candidate) == nil {
                Defaults[.spaceSwitcherKeybind] = candidate
                return candidate
            }
        }
        return nil
    }

    // MARK: - Display

    static func describe(_ bind: UserKeyBind) -> String {
        modifierSymbol(bind.modifierFlags) + KeyboardLabel.localizedKey(for: bind.keyCode)
    }

    static func modifierSymbol(_ modifier: Int) -> String {
        if modifier == Defaults[.Int64maskCommand] {
            return "⌘"
        }
        if modifier == Defaults[.Int64maskAlternate] {
            return "⌥"
        }
        if modifier == Defaults[.Int64maskControl] {
            return "⌃"
        }
        return ""
    }

    // MARK: - Helpers

    static let arrowKeyCodes: Set<UInt16> = [UInt16(kVK_LeftArrow), UInt16(kVK_RightArrow), UInt16(kVK_UpArrow), UInt16(kVK_DownArrow)]
    static let vimKeyCodes: Set<UInt16> = [UInt16(kVK_ANSI_H), UInt16(kVK_ANSI_J), UInt16(kVK_ANSI_K), UInt16(kVK_ANSI_L)]

    static func isModifierKeyCode(_ key: UInt16) -> Bool {
        [kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_Command, kVK_RightCommand, kVK_Function]
            .contains(Int(key))
    }

    private static func sameChord(_ a: UserKeyBind, _ b: UserKeyBind) -> Bool {
        a.keyCode == b.keyCode && a.modifierFlags == b.modifierFlags
    }

    private static func sharedSessionKeyReason(_ key: UInt16) -> String? {
        guard Defaults[.enableSpaceSwitcher] else { return nil }
        if key == Defaults[.spaceSwitcherMoveWindowKeyCode] {
            return String(localized: "That key is the Space Switcher's Move Window Key.", comment: "Keybind validation error")
        }
        if key == Defaults[.spaceSwitcherKeybind].keyCode {
            return String(localized: "That key is the Space Switcher trigger key.", comment: "Keybind validation error")
        }
        return nil
    }
}
