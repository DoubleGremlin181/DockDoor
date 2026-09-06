import AppKit
import Defaults
import SwiftUI

struct SpaceSwitcherSettingsView: View {
    @Default(.enableSpaceSwitcher) var enableSpaceSwitcher
    @Default(.spaceSwitcherStayOpenOnRelease) var spaceSwitcherStayOpenOnRelease
    @Default(.spaceSwitcherStartOnSecondSpace) var spaceSwitcherStartOnSecondSpace
    @Default(.spaceSwitcherWarpCursor) var spaceSwitcherWarpCursor
    @Default(.spaceSwitcherPreviewDelay) var previewDelay
    @Default(.spaceSwitcherPlacementStrategy) var placementStrategy
    @Default(.spaceSwitcherPinnedScreenIdentifier) var pinnedScreenIdentifier
    @Default(.spaceSwitcherDisplayOrder) var displayOrder
    @Default(.spaceSwitcherPreviewStyle) var spaceSwitcherPreviewStyle
    @Default(.spaceSwitcherShowSpaceLabels) var spaceSwitcherShowSpaceLabels
    @Default(.spaceSwitcherShowDisplayNames) var spaceSwitcherShowDisplayNames
    @Default(.spaceSwitcherCardWidth) var spaceSwitcherCardWidth
    @Default(.spaceSwitcherRememberDisplayLayouts) var rememberDisplayLayouts
    @Default(.spaceSwitcherKeepUnpluggedDesktopsSeparate) var keepUnpluggedDesktopsSeparate
    @Default(.debugMode) var debugMode

    /// Set when enabling the feature had to move its shortcut off one the
    /// Window Switcher owns; shown until the view reappears.
    @State private var reassignedKeybind: UserKeyBind?

    var body: some View {
        BaseSettingsView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                if enableSpaceSwitcher {
                    behaviorSection
                    placementSection
                    appearanceSection
                    displayMemorySection
                }
            }
        }
        .onAppear { reassignedKeybind = nil }
    }

    // MARK: - Display memory

    private var displayMemorySection: some View {
        SettingsGroup(header: "Display memory") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $rememberDisplayLayouts) {
                    Text("Remember desktop layouts per display")
                }
                .settingsSearchTarget("spaceSwitcher.rememberDisplayLayouts")
                Text("When a display is unplugged, the windows from its desktops are kept apart on the remaining display and moved back when it returns. Only windows the Space Switcher has seen are remembered; desktops are never created or removed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                if rememberDisplayLayouts, !NSScreen.screensHaveSeparateSpaces {
                    SettingsWarningCallout(verbatim: String(localized: "Requires “Displays have separate Spaces” in System Settings → Desktop & Dock.", comment: "Display memory requirement callout"))
                }

                if rememberDisplayLayouts {
                    Toggle(isOn: $keepUnpluggedDesktopsSeparate) {
                        Text("Use empty desktops to keep unplugged desktops apart")
                    }
                    .settingsSearchTarget("spaceSwitcher.keepUnpluggedDesktopsSeparate")
                    Text("If macOS folds two of the unplugged display’s desktops together, the second group of windows is moved onto an empty desktop of the remaining display when one is free.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 20)

                    SettingsNote(icon: "rectangle.on.rectangle.slash", text: "Full-screen apps and windows shown on every desktop are left where macOS puts them. Identical monitors are told apart by their position in the arrangement.")

                    HStack {
                        Button {
                            DisplayLayoutMemory.shared.forgetAll()
                        } label: {
                            Text("Forget remembered layouts")
                        }
                        .settingsSearchTarget("spaceSwitcher.forgetDisplayLayouts")

                        if debugMode {
                            Button {
                                Task { await DisplayLayoutMemory.shared.restoreNow() }
                            } label: {
                                Text("Run restore now")
                            }
                        }
                    }

                    if debugMode {
                        rememberedDisplaysList
                    }
                }
            }
        }
    }

    private var rememberedDisplaysList: some View {
        VStack(alignment: .leading, spacing: 4) {
            let summaries = DisplayLayoutMemory.shared.summaries
            if summaries.isEmpty {
                Text("No layouts remembered yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ForEach(summaries) { summary in
                Text(verbatim: "\(summary.name): \(summary.desktopCount) desktops, \(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))\(summary.isPending ? " (absent)" : "")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 20)
    }

    // MARK: - Header

    private var headerSection: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $enableSpaceSwitcher) {
                    Text("Enable Space Switcher")
                }
                .settingsSearchTarget("spaceSwitcher.enable")
                .onChange(of: enableSpaceSwitcher) { enabled in
                    if enabled {
                        reassignedKeybind = KeybindConflicts.resolveSpaceKeybindOnEnable()
                    }
                    askUserToRestartApplication()
                }

                Text("Shows every Space on every display with a preview of its windows, and lets you jump between Spaces with a keyboard shortcut — hold the modifier and tap the trigger key to cycle, release to switch.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let reassignedKeybind {
                    SettingsWarningCallout(verbatim: String(localized: "Shortcut changed to \(KeybindConflicts.describe(reassignedKeybind)) because the previous one is used by the Window Switcher.", comment: "Shown after enabling the Space Switcher moved its shortcut"))
                }

                SettingsNote(icon: "keyboard", text: "Shortcuts are configured in Gestures & Keybinds → Space Switcher Shortcuts.")
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsGroup(header: "Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { !spaceSwitcherStayOpenOnRelease },
                    set: { spaceSwitcherStayOpenOnRelease = !$0 }
                )) { Text("Release initializer key to switch Space") }
                    .settingsSearchTarget("spaceSwitcher.stayOpen")
                Text("When off, the switcher stays open after releasing the shortcut: navigate with arrow keys and confirm with the selection key or a click; Escape or clicking outside dismisses. Windows can be dragged between Spaces while the switcher is open.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                Toggle(isOn: $spaceSwitcherStartOnSecondSpace) { Text("Start on second Space") }
                    .settingsSearchTarget("spaceSwitcher.startOnSecond")
                Text("Highlight the next Space instead of the current one when opening.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                HStack {
                    Text("Preview delay")
                    Spacer()
                    Slider(value: $previewDelay, in: 0 ... 0.5, step: 0.05)
                        .frame(width: 200)
                    Text(String(format: "%.0f ms", previewDelay * 1000))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                .settingsSearchTarget("spaceSwitcher.previewDelay")
                Text("How long opening waits for previews still loading. Previews start loading when the shortcut’s modifier is pressed and are kept for a minute.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                Toggle(isOn: $spaceSwitcherWarpCursor) {
                    Text("Move cursor to the selected display")
                }
                .settingsSearchTarget("spaceSwitcher.warpCursor")
                Text("After switching, the cursor jumps to the center of the display that owns the selected Space.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: - Placement

    private var placementSection: some View {
        SettingsGroup(header: "Placement") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Screen", selection: $placementStrategy) {
                    ForEach(WindowSwitcherPlacementStrategy.allCases, id: \.self) {
                        Text($0.localizedName).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .settingsSearchTarget("spaceSwitcher.placement")
                .onChange(of: placementStrategy) { newStrategy in
                    if newStrategy == .pinnedToScreen, pinnedScreenIdentifier.isEmpty {
                        pinnedScreenIdentifier = NSScreen.main?.uniqueIdentifier() ?? ""
                    }
                }

                if placementStrategy == .pinnedToScreen {
                    Picker("Pin to", selection: $pinnedScreenIdentifier) {
                        ForEach(NSScreen.screens, id: \.self) { screen in
                            Text(screen.displayName).tag(screen.uniqueIdentifier())
                        }
                        if !pinnedScreenIdentifier.isEmpty,
                           !NSScreen.screens.contains(where: { $0.uniqueIdentifier() == pinnedScreenIdentifier })
                        {
                            Text("Disconnected Display").tag(pinnedScreenIdentifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.leading, 20)

                    if !pinnedScreenIdentifier.isEmpty,
                       !NSScreen.screens.contains(where: { $0.uniqueIdentifier() == pinnedScreenIdentifier })
                    {
                        Text("This display is currently disconnected.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    }
                }

                Picker(String(localized: "Display row order", comment: "Space Switcher display row order picker label"), selection: $displayOrder) {
                    ForEach(SpaceSwitcherDisplayOrder.allCases) { order in
                        Text(order.localizedName).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .settingsSearchTarget("spaceSwitcher.displayOrder")
                .disabled(NSScreen.screens.count < 2)
                Text(NSScreen.screens.count < 2
                    ? String(localized: "Connect a second display to choose how its row is ordered.", comment: "Space Switcher display row order caption with one display")
                    : displayOrder.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsGroup(header: "Appearance") {
            VStack(alignment: .leading, spacing: 10) {
                Picker(String(localized: "Preview style", comment: "Space Switcher preview style picker label"), selection: $spaceSwitcherPreviewStyle) {
                    ForEach(SpaceSwitcherPreviewStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .settingsSearchTarget("spaceSwitcher.previewStyle")
                Text(spaceSwitcherPreviewStyle.localizedDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                Toggle(isOn: $spaceSwitcherShowSpaceLabels) {
                    Text("Show Space labels")
                }
                .settingsSearchTarget("spaceSwitcher.showLabels")

                Toggle(isOn: $spaceSwitcherShowDisplayNames) {
                    Text("Show display names")
                }
                .settingsSearchTarget("spaceSwitcher.showDisplayNames")
                Text("Label each row with its display name when more than one display has Spaces.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)

                HStack {
                    Text("Space card width")
                    Spacer()
                    Slider(value: $spaceSwitcherCardWidth, in: 120 ... 800, step: 10)
                        .frame(width: 200)
                    Text("\(Int(spaceSwitcherCardWidth)) pt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .settingsSearchTarget("spaceSwitcher.cardWidth")
            }
        }
    }
}
