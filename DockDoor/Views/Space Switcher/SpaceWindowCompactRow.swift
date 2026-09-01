import Defaults
import SwiftUI

/// A window row in the Space Switcher's list style, drawn with the exact
/// metrics and chrome of the Window Switcher's compact mode
/// (`WindowPreviewCompact`) so both switchers feel like one product: same
/// icon size, row height, fonts, title format, overflow style, card
/// background and highlight treatment. Also used as the floating drag ghost.
struct SpaceWindowCompactRow: View {
    let window: SpaceSwitcherEngine.SpaceWindow
    let appearance: PreviewAppearanceSettings
    let backgroundAppearance: BackgroundAppearance
    let width: CGFloat
    /// Forces the highlighted look (drag ghost); otherwise hover decides.
    var forceHighlighted = false

    @State private var isHovering = false

    private var isHighlighted: Bool {
        forceHighlighted || isHovering
    }

    private var appName: String {
        window.appName ?? String(localized: "Unknown", comment: "Fallback app name in the Space Switcher window list")
    }

    private var windowTitle: String? {
        let title = window.title ?? window.info?.windowName ?? ""
        if title.isEmpty || title == appName {
            return nil
        }
        return title
    }

    private var stateIndicator: String? {
        guard appearance.showMinimizedHiddenLabels, let info = window.info else { return nil }
        if info.isMinimized {
            return String(localized: "Minimized", comment: "Window state label")
        } else if info.isHidden {
            return String(localized: "Hidden", comment: "Window state label")
        }
        return nil
    }

    private var cornerRadius: CGFloat {
        CardRadius.base + (CardRadius.innerPadding * appearance.globalPaddingMultiplier)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: appearance.compactModeItemSize.iconSize, height: appearance.compactModeItemSize.iconSize)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: appearance.compactModeItemSize.iconSize, height: appearance.compactModeItemSize.iconSize)
                    .foregroundStyle(.secondary)
            }

            CompactRowTitleStack(
                appName: appName,
                windowTitle: windowTitle,
                stateIndicator: stateIndicator,
                appearance: appearance
            )

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, CardRadius.innerPadding)
        .frame(width: width, height: appearance.compactModeItemSize.rowHeight, alignment: .leading)
        .clipped()
        .background {
            let highlightColor = appearance.hoverHighlightColor ?? Color(nsColor: .controlAccentColor)

            if !appearance.hidePreviewCardBackground {
                BlurView(cornerRadius: cornerRadius, appearance: backgroundAppearance)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .borderedBackground(.primary.opacity(0.1), lineWidth: 1.75, cornerRadius: cornerRadius)
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(highlightColor.opacity(appearance.selectionOpacity))
                        }
                    }
            }

            if isHighlighted {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(highlightColor, lineWidth: 2.5)
            }
        }
        .opacity(isHighlighted ? 1.0 : appearance.unselectedContentOpacity)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !forceHighlighted else { return }
            if appearance.showAnimations {
                withAnimation(.snappy(duration: 0.175)) { isHovering = hovering }
            } else {
                isHovering = hovering
            }
        }
    }
}
