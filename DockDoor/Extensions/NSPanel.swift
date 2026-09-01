import Cocoa
import Defaults

extension NSPanel {
    /// Style mask shared by DockDoor's borderless overlay panels (hover
    /// preview, Window Switcher, Space Switcher).
    static let overlayStyleMask: NSWindow.StyleMask = [.nonactivatingPanel, .fullSizeContentView, .borderless]

    /// Shared configuration for DockDoor's overlay panels: floating,
    /// transparent, non-activating, present on every space including
    /// fullscreen. The window level honors the Raised Window Level setting
    /// as read at call time.
    func applyOverlayStyling() {
        level = Defaults[.raisedWindowLevel] ? .statusBar : .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }
}
