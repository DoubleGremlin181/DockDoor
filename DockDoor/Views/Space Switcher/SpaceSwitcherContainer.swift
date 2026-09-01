import Defaults
import SwiftUI

struct SpaceSwitcherContainer: View {
    static let coordinateSpaceName = "spaceSwitcherRoot"

    @ObservedObject var state: SpaceSwitcherState
    @State private var backgroundAppearance: BackgroundAppearance = .resolve()
    /// Window Switcher appearance so the list style tracks the user's
    /// compact-mode settings exactly; kept live via Defaults.updates below.
    @State private var appearance = PreviewAppearanceSettings.resolve(windowSwitcherActive: true, dockPosition: .cmdTab)
    @Default(.spaceSwitcherPreviewStyle) private var previewStyle
    @Default(.spaceSwitcherShowDisplayNames) private var showDisplayNamesSetting

    /// Card frames resolved during layout; a plain reference type so updates
    /// during rendering don't recursively invalidate the view.
    private final class FrameStore {
        var frames: [CGSSpaceID: CGRect] = [:]
        var dragActive = false
    }

    @State private var frameStore = FrameStore()

    private struct DragGhost {
        let window: SpaceSwitcherEngine.SpaceWindow
        let sourceSpaceID: CGSSpaceID
        var location: CGPoint
        var size: CGSize
    }

    @State private var dragGhost: DragGhost?

    private var dropTargetID: CGSSpaceID? {
        guard let ghost = dragGhost,
              let target = frameStore.frames.first(where: { $0.value.contains(ghost.location) })?.key,
              target != ghost.sourceSpaceID
        else { return nil }
        return target
    }

    private var showDisplayNames: Bool {
        showDisplayNamesSetting && state.model.displays.count > 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(state.model.displays) { display in
                displayRow(display)
            }
        }
        .padding(16)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .backgroundPreferenceValue(SpaceCardFramesKey.self) { anchors in
            GeometryReader { proxy in
                let _ = updateFrames(anchors, proxy)
                Color.clear
            }
        }
        .overlay(alignment: .topLeading) {
            if let ghost = dragGhost {
                ghostView(ghost)
                    .scaleEffect(1.05)
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                    .offset(
                        x: ghost.location.x - ghost.size.width / 2,
                        y: ghost.location.y - ghost.size.height / 2
                    )
                    .allowsHitTesting(false)
            }
        }
        .dockStyle(backgroundAppearance: backgroundAppearance)
        .task {
            let keys = PreviewAppearanceSettings.observedKeys + BackgroundAppearance.observedKeys
            for await _ in Defaults.updates(keys, initial: true) {
                let updated = PreviewAppearanceSettings.resolve(windowSwitcherActive: true, dockPosition: .cmdTab)
                if updated != appearance {
                    appearance = updated
                }
                let updatedBg = BackgroundAppearance.resolve()
                if updatedBg != backgroundAppearance {
                    backgroundAppearance = updatedBg
                }
            }
        }
    }

    /// The dragged item, drawn in the same style it was picked up from.
    @ViewBuilder
    private func ghostView(_ ghost: DragGhost) -> some View {
        if previewStyle == .windowList {
            SpaceWindowCompactRow(
                window: ghost.window,
                appearance: appearance,
                backgroundAppearance: backgroundAppearance,
                width: ghost.size.width,
                forceHighlighted: true
            )
        } else {
            SpaceWindowThumbnail(window: ghost.window, width: ghost.size.width, height: ghost.size.height)
        }
    }

    /// Rows the list style sizes for on this display: enough for its busiest
    /// space, at least two so empty desktops keep some body, capped so the
    /// panel still fits the screen.
    private func listRows(for display: DisplaySpaces) -> Int {
        let busiest = display.spaces
            .map { SpaceCard.listWindows(state.model.windowsBySpace[$0.id] ?? []).count }
            .max() ?? 0
        let cap = SpaceCard.listRowsFitting(height: state.maxCardHeight, appearance: appearance)
        return min(cap, max(2, busiest))
    }

    private func updateFrames(_ anchors: [CGSSpaceID: Anchor<CGRect>], _ proxy: GeometryProxy) {
        frameStore.frames = anchors.mapValues { proxy[$0] }
    }

    private func displayRow(_ display: DisplaySpaces) -> some View {
        let rows = listRows(for: display)
        return VStack(alignment: .leading, spacing: 6) {
            if showDisplayNames {
                Text(display.screen?.localizedName ?? display.identifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(display.spaces) { space in
                    SpaceCard(
                        space: space,
                        display: display,
                        windows: state.model.windowsBySpace[space.id] ?? [],
                        fullscreenAppName: SpaceSwitcherEngine.fullscreenAppName(for: space, in: state.model),
                        isSelected: state.isSelected(space),
                        onTap: { state.commit(space) },
                        onWindowDragEnded: { windowID, dropPoint in
                            frameStore.dragActive = false
                            dragGhost = nil
                            handleWindowDrop(windowID: windowID, from: space, at: dropPoint)
                        },
                        onWindowDragChanged: { window, location, size in
                            frameStore.dragActive = true
                            dragGhost = DragGhost(window: window, sourceSpaceID: space.id, location: location, size: size)
                        },
                        isDropTarget: dropTargetID == space.id,
                        maxWidth: state.maxCardWidth,
                        appearance: appearance,
                        backgroundAppearance: backgroundAppearance,
                        listRows: rows
                    )
                    .onHover { hovering in
                        if hovering, !frameStore.dragActive {
                            state.hoverSelect(space)
                        }
                    }
                }
            }
        }
    }

    private func handleWindowDrop(windowID: CGWindowID, from sourceSpace: SpaceInfo, at point: CGPoint) {
        guard let (targetID, _) = frameStore.frames.first(where: { $0.value.contains(point) }),
              targetID != sourceSpace.id,
              let target = state.model.allSpaces.first(where: { $0.id == targetID }),
              !target.isFullscreen
        else { return }
        state.moveWindow(windowID, to: target)
    }
}
