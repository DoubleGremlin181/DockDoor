import Defaults
import SwiftUI

/// Accepts the first click even when the panel isn't key, so drags and taps
/// work immediately in stay-open mode.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

final class SpaceSwitcherPanelCoordinator: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: NSPanel.overlayStyleMask,
            backing: .buffered,
            defer: false
        )
        // A new panel is created per session and close()d afterwards.
        isReleasedWhenClosed = false
        applyOverlayStyling()
    }

    @MainActor
    func show(state: SpaceSwitcherState, on screen: NSScreen) {
        // Cap card height so every display row fits when stacked
        let rowCount = max(1, state.model.displays.count)
        let verticalChrome: CGFloat = 120 + CGFloat(rowCount) * 44 // labels + row spacing
        state.maxCardHeight = max(80, (screen.visibleFrame.height - verticalChrome) / CGFloat(rowCount))

        // Cap card width so the widest row fits horizontally…
        let maxCardsPerRow = state.model.displays.map(\.spaces.count).max() ?? 1
        if maxCardsPerRow > 0 {
            let chrome: CGFloat = 120 // container + dockStyle padding and margins
            let spacing = CGFloat(max(0, maxCardsPerRow - 1)) * 10
            let available = screen.visibleFrame.width - chrome - spacing
            var widthCap = available / CGFloat(maxCardsPerRow)
            // …and, for the screen-shaped preview styles, so the stacked rows
            // also fit vertically on small screens (card height = width / aspect).
            if Defaults[.spaceSwitcherPreviewStyle] != .windowList {
                let tallestAspect = state.model.displays
                    .compactMap { $0.screen?.frame }
                    .filter { $0.height > 0 }
                    .map { $0.width / $0.height }
                    .min() ?? (16.0 / 10.0)
                widthCap = min(widthCap, state.maxCardHeight * tallestAspect)
            }
            state.maxCardWidth = max(120, widthCap)
        }

        let hostingView = FirstMouseHostingView(rootView: SpaceSwitcherContainer(state: state))
        contentView = hostingView

        var size = hostingView.fittingSize
        size.width = min(size.width, screen.visibleFrame.width)
        size.height = min(size.height, screen.visibleFrame.height)

        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
    }

    @MainActor
    func hide() {
        orderOut(nil)
        contentView = nil
    }
}
