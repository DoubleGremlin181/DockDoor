import Defaults
import SwiftUI

struct SpaceCard: View {
    let space: SpaceInfo
    let display: DisplaySpaces
    let windows: [SpaceSwitcherEngine.SpaceWindow]
    let fullscreenAppName: String?
    let isSelected: Bool
    let onTap: () -> Void
    /// Fired when a window thumbnail drag ends; point is in the container's
    /// named coordinate space so the container can resolve the drop target.
    let onWindowDragEnded: (CGWindowID, CGPoint) -> Void
    /// Streams drag position (in the container's named space) with the dragged
    /// window and its tile size, so the container can float an unclipped ghost.
    let onWindowDragChanged: (SpaceSwitcherEngine.SpaceWindow, CGPoint, CGSize) -> Void
    /// The card currently under a drag, drawn with a drop highlight.
    let isDropTarget: Bool
    /// Screen-fit cap computed by the panel so wide card settings never
    /// overflow the display.
    let maxWidth: CGFloat
    /// Window Switcher appearance (compact-mode metrics) shared with the
    /// Window Switcher so the list style matches it exactly.
    let appearance: PreviewAppearanceSettings
    let backgroundAppearance: BackgroundAppearance
    /// Rows the list style sizes for; uniform across a display's row so cards
    /// line up. Cards with more windows collapse the tail into an overflow row.
    let listRows: Int

    @Default(.spaceSwitcherPreviewStyle) private var previewStyle
    @Default(.spaceSwitcherCardWidth) private var cardWidth

    private var effectiveWidth: CGFloat {
        min(cardWidth, maxWidth)
    }

    @Default(.spaceSwitcherShowSpaceLabels) private var showLabels

    @State private var draggedWindowID: CGWindowID?

    private static let maxCompositeWindows = 15

    private var screenCGFrame: CGRect {
        display.screen?.cgFrame ?? CGRect(x: 0, y: 0, width: 16, height: 10)
    }

    private var cardHeight: CGFloat {
        if previewStyle == .windowList {
            return Self.listHeight(rows: listRows, appearance: appearance)
        }
        let frame = screenCGFrame
        guard frame.width > 0 else { return effectiveWidth * 10 / 16 }
        return effectiveWidth * frame.height / frame.width
    }

    // MARK: - List metrics (shared with the container's sizing)

    static let listPadding: CGFloat = 8
    static let listSpacing: CGFloat = 4

    static func listHeight(rows: Int, appearance: PreviewAppearanceSettings) -> CGFloat {
        let rows = CGFloat(max(1, rows))
        return listPadding * 2 + rows * appearance.compactModeItemSize.rowHeight + (rows - 1) * listSpacing
    }

    /// How many rows fit in `height` at the current compact item size.
    static func listRowsFitting(height: CGFloat, appearance: PreviewAppearanceSettings) -> Int {
        let rowHeight = appearance.compactModeItemSize.rowHeight
        return max(1, Int((height - listPadding * 2 + listSpacing) / (rowHeight + listSpacing)))
    }

    /// Windows shown by the list style: offscreen helper surfaces without a
    /// title or a vetted cache entry are noise, not list items.
    static func listWindows(_ windows: [SpaceSwitcherEngine.SpaceWindow]) -> [SpaceSwitcherEngine.SpaceWindow] {
        windows.filter { $0.title != nil || $0.info != nil }
    }

    var body: some View {
        let highlightColor = appearance.hoverHighlightColor ?? Color(nsColor: .controlAccentColor)
        VStack(spacing: 6) {
            cardBody
                .frame(width: effectiveWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isDropTarget || isSelected ? highlightColor : Color.primary.opacity(0.15),
                            lineWidth: isDropTarget || isSelected ? 2.5 : 1
                        )
                }
                .scaleEffect(isSelected && appearance.showAnimations ? 1.03 : 1.0)
                .animation(appearance.showAnimations ? .spring(response: 0.18, dampingFraction: 0.85) : nil, value: isSelected)

            if showLabels {
                HStack(spacing: 4) {
                    if space.isCurrent {
                        Circle()
                            .fill(highlightColor)
                            .frame(width: 5, height: 5)
                    }
                    Text(label)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                }
                .frame(maxWidth: effectiveWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .anchorPreference(key: SpaceCardFramesKey.self, value: .bounds) { [space.id: $0] }
    }

    private var label: String {
        if let fullscreenAppName {
            fullscreenAppName
        } else if space.isFullscreen {
            String(localized: "Full Screen", comment: "Label for a fullscreen space in the Space Switcher")
        } else {
            String(localized: "Desktop \(space.desktopNumber)", comment: "Label for a numbered desktop space in the Space Switcher")
        }
    }

    private var cardBody: some View {
        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(space.isCurrent ? 0.14 : 0.07))

            switch previewStyle {
            case .composite:
                compositePreview
            case .exploded:
                explodedPreview
            case .windowList:
                windowListPreview
            }
        }
    }

    private var visibleWindows: [SpaceSwitcherEngine.SpaceWindow] {
        Array(windows.prefix(Self.maxCompositeWindows))
    }

    // MARK: - Composite (real positions)

    private var compositePreview: some View {
        let screen = screenCGFrame
        let scale = screen.width > 0 ? effectiveWidth / screen.width : 0

        // Buckets are frontmost-first; draw back-to-front so z-order is right
        return ZStack(alignment: .topLeading) {
            ForEach(visibleWindows.reversed()) { window in
                let w = max(4, window.frame.width * scale)
                let h = max(4, window.frame.height * scale)
                miniWindow(window, width: w, height: h)
                    .offset(
                        x: (window.frame.minX - screen.minX) * scale,
                        y: (window.frame.minY - screen.minY) * scale
                    )
            }
        }
        .frame(width: effectiveWidth, height: cardHeight, alignment: .topLeading)
    }

    // MARK: - Exploded (Mission Control-like)

    private struct PlacedTile: Identifiable {
        let window: SpaceSwitcherEngine.SpaceWindow
        let rect: CGRect
        var id: CGWindowID {
            window.id
        }
    }

    /// Mission Control-style shelf packing: windows fill balanced rows, each
    /// tile keeps its own aspect ratio, rows are centered.
    private var explodedPreview: some View {
        let items = visibleWindows
        guard !items.isEmpty else { return AnyView(EmptyView()) }

        let pad: CGFloat = 5
        let availW = effectiveWidth - pad * 2
        let availH = cardHeight - pad * 2

        func aspect(_ window: SpaceSwitcherEngine.SpaceWindow) -> CGFloat {
            guard window.frame.height > 0 else { return 1.6 }
            return max(0.3, min(4, window.frame.width / window.frame.height))
        }

        let meanAspect = items.map(aspect).reduce(0, +) / CGFloat(items.count)
        let rowCount = max(1, min(items.count, Int(round(sqrt(Double(items.count) * meanAspect * availH / max(availW, 1))))))

        // Greedily balance rows by summed aspect (width at unit height)
        var rows: [[SpaceSwitcherEngine.SpaceWindow]] = Array(repeating: [], count: rowCount)
        var rowAspects = [CGFloat](repeating: 0, count: rowCount)
        for window in items {
            let index = rowAspects.enumerated().min(by: { $0.element < $1.element })!.offset
            rows[index].append(window)
            rowAspects[index] += aspect(window)
        }
        let filledRows = rows.filter { !$0.isEmpty }
        let rowH = (availH - pad * CGFloat(filledRows.count - 1)) / CGFloat(filledRows.count)

        var tiles: [PlacedTile] = []
        for (rowIndex, row) in filledRows.enumerated() {
            let sumAspect = row.map(aspect).reduce(0, +)
            let naturalW = sumAspect * rowH + pad * CGFloat(row.count - 1)
            let scale = min(1, availW / max(naturalW, 1))
            let tileH = rowH * scale
            var x = pad + max(0, (availW - naturalW * scale) / 2)
            let y = pad + CGFloat(rowIndex) * (rowH + pad) + (rowH - tileH) / 2
            for window in row {
                let tileW = aspect(window) * tileH
                tiles.append(PlacedTile(window: window, rect: CGRect(x: x, y: y, width: tileW, height: tileH)))
                x += tileW + pad * scale
            }
        }

        return AnyView(
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    miniWindow(tile.window, width: tile.rect.width, height: tile.rect.height)
                        .offset(x: tile.rect.minX, y: tile.rect.minY)
                }
            }
            .frame(width: effectiveWidth, height: cardHeight, alignment: .topLeading)
        )
    }

    // MARK: - Window list (Window Switcher compact-mode rows)

    private var windowListPreview: some View {
        let listWindows = Self.listWindows(windows)
        let capacity = max(1, listRows)
        let shown = Array(listWindows.prefix(listWindows.count > capacity ? max(1, capacity - 1) : capacity))
        let overflow = listWindows.count - shown.count
        let rowWidth = effectiveWidth - Self.listPadding * 2

        return VStack(alignment: .leading, spacing: Self.listSpacing) {
            if listWindows.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "menubar.dock.rectangle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(shown) { window in
                    SpaceWindowCompactRow(
                        window: window,
                        appearance: appearance,
                        backgroundAppearance: backgroundAppearance,
                        width: rowWidth
                    )
                    .opacity(draggedWindowID == window.id ? 0.25 : 1)
                    .highPriorityGesture(windowDragGesture(window, size: CGSize(width: rowWidth, height: appearance.compactModeItemSize.rowHeight)))
                }
                if overflow > 0 {
                    Text(String(localized: "+\(overflow) more", comment: "Overflow row in Space Switcher window list"))
                        .font(appearance.compactModeItemSize.secondaryFont)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, CardRadius.innerPadding)
                        .frame(height: appearance.compactModeItemSize.rowHeight, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Self.listPadding)
        .frame(width: effectiveWidth, height: cardHeight, alignment: .topLeading)
    }

    // MARK: - Shared thumbnail

    private func miniWindow(_ window: SpaceSwitcherEngine.SpaceWindow, width: CGFloat, height: CGFloat) -> some View {
        SpaceWindowThumbnail(window: window, width: width, height: height)
            .opacity(draggedWindowID == window.id ? 0.25 : 1)
            .highPriorityGesture(windowDragGesture(window, size: CGSize(width: width, height: height)))
    }

    /// Drag-to-move shared by thumbnails and list rows; `size` is what the
    /// container's floating ghost is drawn at.
    private func windowDragGesture(_ window: SpaceSwitcherEngine.SpaceWindow, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(SpaceSwitcherContainer.coordinateSpaceName))
            .onChanged { value in
                draggedWindowID = window.id
                onWindowDragChanged(window, value.location, size)
            }
            .onEnded { value in
                draggedWindowID = nil
                onWindowDragEnded(window.id, value.location)
            }
    }
}

/// Thumbnail rendering shared by cards and the container's floating drag ghost.
struct SpaceWindowThumbnail: View {
    let window: SpaceSwitcherEngine.SpaceWindow
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let cgImage = window.image {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fill)
                    // The panel opens on cached previews and swaps in fresh
                    // captures moments later; crossfade instead of a hard cut.
                    .id(ObjectIdentifier(cgImage))
                    .transition(.opacity)
            } else {
                ZStack {
                    Rectangle().fill(.thinMaterial)
                    if let icon = window.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: min(24, width * 0.6),
                                height: min(24, height * 0.6)
                            )
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .animation(Defaults[.showAnimations] ? .easeInOut(duration: 0.25) : nil, value: window.image.map { ObjectIdentifier($0) })
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
        }
    }
}

/// Card frames in the container's coordinate space, keyed by space ID, used
/// to resolve drag-and-drop targets.
struct SpaceCardFramesKey: PreferenceKey {
    static var defaultValue: [CGSSpaceID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CGSSpaceID: Anchor<CGRect>], nextValue: () -> [CGSSpaceID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
