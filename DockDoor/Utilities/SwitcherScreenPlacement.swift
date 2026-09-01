import AppKit
import ApplicationServices
import Defaults

/// Resolves the screen a switcher panel (Window or Space) opens on for the
/// shared Placement strategy setting.
enum SwitcherScreenPlacement {
    /// Screen for the given strategy, or nil when it cannot be resolved
    /// (disconnected pinned display, no focused window) or when
    /// `.screenWithLastActiveWindow` is deferred to the caller
    /// (`resolveLastActiveWindow: false` — the Window Switcher resolves it
    /// later inside `showWindow`). Callers fall back to `mouseScreen()`.
    static func resolve(
        strategy: WindowSwitcherPlacementStrategy,
        pinnedIdentifier: String,
        resolveLastActiveWindow: Bool
    ) -> NSScreen? {
        switch strategy {
        case .pinnedToScreen:
            NSScreen.findScreen(byIdentifier: pinnedIdentifier)
        case .screenWithLastActiveWindow:
            resolveLastActiveWindow ? screenOfFocusedWindow() : nil
        case .screenWithMouse:
            nil
        }
    }

    /// The screen under the mouse — the shared placement fallback.
    static func mouseScreen() -> NSScreen {
        NSScreen.screenFromQuartzPoint(DockObserver.getMousePosition())
    }

    /// Screen showing the largest part of the frontmost app's focused window.
    static func screenOfFocusedWindow() -> NSScreen? {
        guard let frame = focusedWindowFrame() else { return nil }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let r = screen.frame.intersection(frame)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
        return best
    }

    /// Frame (AppKit coordinates) of the frontmost app's focused window, via AX.
    static func focusedWindowFrame() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appAX = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let window = focused as! AXUIElement
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID(),
              let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return nil }
        // AX is top-left Quartz space; convert to AppKit bottom-left.
        return NSRect(x: position.x, y: primaryMaxY - position.y - size.height, width: size.width, height: size.height)
    }
}
