import Carbon.HIToolbox
import Defaults
@testable import DockDoor
import Testing

/// Runs `body` with the given Defaults applied, restoring the previous values afterwards.
private func withDefaults(_ apply: () -> Void, _ body: () throws -> Void) rethrows {
    let snapshot = (
        Defaults[.enableWindowSwitcher], Defaults[.enableSpaceSwitcher], Defaults[.enableCmdTabEnhancements],
        Defaults[.UserKeybind], Defaults[.alternateKeybindKey], Defaults[.spaceSwitcherKeybind],
        Defaults[.spaceSwitcherMoveWindowKeyCode], Defaults[.windowSwitcherSelectionKeyCode],
        Defaults[.switcherBackwardKeyCode], Defaults[.enableVimMotions]
    )
    defer {
        Defaults[.enableWindowSwitcher] = snapshot.0
        Defaults[.enableSpaceSwitcher] = snapshot.1
        Defaults[.enableCmdTabEnhancements] = snapshot.2
        Defaults[.UserKeybind] = snapshot.3
        Defaults[.alternateKeybindKey] = snapshot.4
        Defaults[.spaceSwitcherKeybind] = snapshot.5
        Defaults[.spaceSwitcherMoveWindowKeyCode] = snapshot.6
        Defaults[.windowSwitcherSelectionKeyCode] = snapshot.7
        Defaults[.switcherBackwardKeyCode] = snapshot.8
        Defaults[.enableVimMotions] = snapshot.9
    }
    // Baseline: Window Switcher on ⌘Tab, Space Switcher on ⌥Tab, no alternate, no Cmd+Tab enhancements.
    Defaults[.enableWindowSwitcher] = true
    Defaults[.enableSpaceSwitcher] = true
    Defaults[.enableCmdTabEnhancements] = false
    Defaults[.UserKeybind] = cmdTab
    Defaults[.alternateKeybindKey] = 0
    Defaults[.spaceSwitcherKeybind] = optTab
    Defaults[.spaceSwitcherMoveWindowKeyCode] = UInt16(kVK_ANSI_M)
    Defaults[.windowSwitcherSelectionKeyCode] = UInt16(kVK_Return)
    Defaults[.switcherBackwardKeyCode] = UInt16(kVK_Shift)
    Defaults[.enableVimMotions] = false
    apply()
    try body()
}

private let tab = UInt16(kVK_Tab)
private var cmdTab: UserKeyBind {
    UserKeyBind(keyCode: tab, modifierFlags: Defaults[.Int64maskCommand])
}

private var optTab: UserKeyBind {
    UserKeyBind(keyCode: tab, modifierFlags: Defaults[.Int64maskAlternate])
}

private var ctrlTab: UserKeyBind {
    UserKeyBind(keyCode: tab, modifierFlags: Defaults[.Int64maskControl])
}

@Suite(.serialized)
struct KeybindConflictsTests {
    // MARK: Space ↔ Window primary

    @Test func spaceBindEqualToWindowPrimaryIsRejected() {
        withDefaults({}) {
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(cmdTab) != nil)
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(optTab) == nil)
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(ctrlTab) == nil)
        }
    }

    @Test func windowBindEqualToSpacePrimaryIsRejected() {
        withDefaults({}) {
            #expect(KeybindConflicts.validateWindowSwitcherKeybind(optTab) != nil)
            #expect(KeybindConflicts.validateWindowSwitcherKeybind(ctrlTab) == nil)
        }
    }

    @Test func conflictsIgnoredWhenOtherFeatureDisabled() {
        withDefaults({ Defaults[.enableWindowSwitcher] = false }) {
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(cmdTab) == nil)
            #expect(!KeybindConflicts.windowSwitcherClaims(cmdTab))
        }
        withDefaults({ Defaults[.enableSpaceSwitcher] = false }) {
            #expect(KeybindConflicts.validateWindowSwitcherKeybind(optTab) == nil)
        }
    }

    @Test func spaceBindRequiresModifier() {
        withDefaults({}) {
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(UserKeyBind(keyCode: tab, modifierFlags: 0)) != nil)
        }
    }

    // MARK: Alternate key

    @Test func alternateKeyClaimsSpaceBind() {
        withDefaults({
            Defaults[.UserKeybind] = UserKeyBind(keyCode: UInt16(kVK_ANSI_Grave), modifierFlags: Defaults[.Int64maskAlternate])
            Defaults[.alternateKeybindKey] = tab
        }) {
            #expect(KeybindConflicts.windowSwitcherClaims(optTab))
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(optTab) != nil)
        }
    }

    @Test func alternateKeyRejectedWhenEqualToSpaceTrigger() {
        withDefaults({ Defaults[.UserKeybind] = UserKeyBind(keyCode: UInt16(kVK_ANSI_Grave), modifierFlags: Defaults[.Int64maskAlternate]) }) {
            #expect(KeybindConflicts.validateAlternateKey(tab, modifier: Defaults[.Int64maskAlternate]) != nil)
            #expect(KeybindConflicts.validateAlternateKey(UInt16(kVK_ANSI_Q), modifier: Defaults[.Int64maskAlternate]) == nil)
            #expect(KeybindConflicts.validateAlternateKey(UInt16(kVK_ANSI_Grave), modifier: Defaults[.Int64maskAlternate]) != nil, "same as primary key")
        }
    }

    // MARK: Window primary modifier change vs alternate key

    @Test func windowModifierChangeCheckedAgainstAlternateChord() {
        withDefaults({
            Defaults[.UserKeybind] = UserKeyBind(keyCode: UInt16(kVK_ANSI_Grave), modifierFlags: Defaults[.Int64maskCommand])
            Defaults[.alternateKeybindKey] = tab
            Defaults[.spaceSwitcherKeybind] = ctrlTab
        }) {
            let ctrlGrave = UserKeyBind(keyCode: UInt16(kVK_ANSI_Grave), modifierFlags: Defaults[.Int64maskControl])
            #expect(KeybindConflicts.validateWindowSwitcherKeybind(ctrlGrave) != nil, "⌃ + alternate Tab would equal the Space bind")
            let optGrave = UserKeyBind(keyCode: UInt16(kVK_ANSI_Grave), modifierFlags: Defaults[.Int64maskAlternate])
            #expect(KeybindConflicts.validateWindowSwitcherKeybind(optGrave) == nil)
        }
    }

    @Test func cmdTabAllowedWithEnhancements() {
        withDefaults({ Defaults[.enableCmdTabEnhancements] = true; Defaults[.UserKeybind] = optTab; Defaults[.spaceSwitcherKeybind] = ctrlTab }) {
            #expect(KeybindConflicts.validateWindowSwitcherKeybind(cmdTab) == nil)
            #expect(KeybindConflicts.validateSpaceSwitcherKeybind(cmdTab) == nil)
        }
    }

    // MARK: Move-window key

    @Test func moveWindowKeyRejectsReservedSessionKeys() {
        withDefaults({}) {
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(tab) != nil, "trigger key")
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_Escape)) != nil)
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_Return)) != nil, "selection key")
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_ANSI_KeypadEnter)) != nil)
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_LeftArrow)) != nil)
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_ANSI_H)) == nil, "vim off")
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_ANSI_M)) == nil)
        }
        withDefaults({ Defaults[.enableVimMotions] = true }) {
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_ANSI_H)) != nil)
        }
        withDefaults({ Defaults[.switcherBackwardKeyCode] = UInt16(kVK_ANSI_Grave) }) {
            #expect(KeybindConflicts.validateSpaceMoveWindowKey(UInt16(kVK_ANSI_Grave)) != nil, "non-modifier backward key")
        }
    }

    @Test func sharedKeysRejectSpaceMoveAndTriggerKeys() {
        withDefaults({}) {
            #expect(KeybindConflicts.validateSelectionKey(UInt16(kVK_ANSI_M)) != nil)
            #expect(KeybindConflicts.validateSelectionKey(tab) != nil)
            #expect(KeybindConflicts.validateSelectionKey(UInt16(kVK_Space)) == nil)
            #expect(KeybindConflicts.validateBackwardKey(UInt16(kVK_ANSI_M)) != nil)
            #expect(KeybindConflicts.validateBackwardKey(UInt16(kVK_Shift)) == nil, "modifier keys are always fine")
        }
        withDefaults({ Defaults[.enableSpaceSwitcher] = false }) {
            #expect(KeybindConflicts.validateSelectionKey(UInt16(kVK_ANSI_M)) == nil)
        }
    }

    @Test func enablingVimMotionsBlockedByMoveKey() {
        withDefaults({ Defaults[.spaceSwitcherMoveWindowKeyCode] = UInt16(kVK_ANSI_J) }) {
            #expect(KeybindConflicts.validateEnablingVimMotions() != nil)
        }
        withDefaults({}) {
            #expect(KeybindConflicts.validateEnablingVimMotions() == nil)
        }
    }

    // MARK: Auto-resolution on enable

    @Test func resolveOnEnableMovesToFirstFreeModifier() {
        withDefaults({ Defaults[.spaceSwitcherKeybind] = cmdTab }) {
            let moved = KeybindConflicts.resolveSpaceKeybindOnEnable()
            #expect(moved == optTab)
            #expect(Defaults[.spaceSwitcherKeybind] == optTab)
        }
        withDefaults({
            Defaults[.UserKeybind] = optTab
            Defaults[.spaceSwitcherKeybind] = optTab
        }) {
            #expect(KeybindConflicts.resolveSpaceKeybindOnEnable() == ctrlTab)
        }
        withDefaults({
            Defaults[.UserKeybind] = optTab
            Defaults[.alternateKeybindKey] = 0
            Defaults[.spaceSwitcherKeybind] = UserKeyBind(keyCode: tab, modifierFlags: 0)
        }) {
            #expect(KeybindConflicts.resolveSpaceKeybindOnEnable() == ctrlTab, "missing modifier resolves to first free one")
        }
    }

    @Test func resolveOnEnableIsNoOpWithoutConflict() {
        withDefaults({}) {
            #expect(KeybindConflicts.resolveSpaceKeybindOnEnable() == nil)
            #expect(Defaults[.spaceSwitcherKeybind] == optTab)
        }
    }

    // MARK: Backward-modifier tolerance in chord matching

    @Test func backwardFlagIgnoredOnlyWhenModifierOutsideChord() {
        withDefaults({}) {
            // Default backward key is Shift; the returned .maskShift is inert
            // because modifierFlagsMatch only compares Alt/Ctrl/Cmd.
            #expect(KeybindHelper.backwardFlagToIgnore(for: optTab) == .maskShift)
            #expect(KeybindHelper.modifierFlagsMatch(optTab.modifierFlags, flags: [.maskAlternate, .maskShift], ignoring: .maskShift))
        }
        withDefaults({ Defaults[.switcherBackwardKeyCode] = UInt16(kVK_Control) }) {
            #expect(KeybindHelper.backwardFlagToIgnore(for: optTab) == .maskControl)
        }
        withDefaults({ Defaults[.switcherBackwardKeyCode] = UInt16(kVK_Option) }) {
            #expect(KeybindHelper.backwardFlagToIgnore(for: optTab) == nil, "backward modifier inside the chord is never ignored")
        }
    }

    @Test func modifierMatchToleratesHeldBackwardModifier() {
        withDefaults({ Defaults[.switcherBackwardKeyCode] = UInt16(kVK_Control) }) {
            let optCtrl: CGEventFlags = [.maskAlternate, .maskControl]
            let saved = optTab.modifierFlags
            #expect(!KeybindHelper.modifierFlagsMatch(saved, flags: optCtrl), "exact match rejects the extra Control")
            #expect(KeybindHelper.modifierFlagsMatch(saved, flags: optCtrl, ignoring: KeybindHelper.backwardFlagToIgnore(for: optTab)))
            #expect(!KeybindHelper.modifierFlagsMatch(saved, flags: [.maskControl], ignoring: KeybindHelper.backwardFlagToIgnore(for: optTab)), "chord modifier itself must still be held")
        }
    }

    @Test func chordModifiersHeldAllowsExtras() {
        let saved = optTab.modifierFlags
        #expect(KeybindHelper.chordModifiersHeld(saved, flags: [.maskAlternate]))
        #expect(KeybindHelper.chordModifiersHeld(saved, flags: [.maskAlternate, .maskShift, .maskControl]), "extra modifiers do not end the session")
        #expect(!KeybindHelper.chordModifiersHeld(saved, flags: [.maskControl]))
        #expect(!KeybindHelper.chordModifiersHeld(saved, flags: []))
    }
}
