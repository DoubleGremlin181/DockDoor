import AppKit
import Combine

final class SpaceSwitcherState: ObservableObject {
    struct Selection: Equatable {
        var row: Int
        var col: Int
    }

    @Published var model: SpaceSwitcherEngine.Model
    @Published var selection: Selection = .init(row: 0, col: 0)

    var onCommit: ((SpaceInfo) -> Void)?
    var onMoveWindowDrop: ((CGWindowID, SpaceInfo) -> Void)?

    /// Per-card width cap so the panel fits its target screen; set by the
    /// panel before the view is created.
    var maxCardWidth: CGFloat = .infinity
    /// Per-card height cap (list style) so stacked display rows fit the screen.
    var maxCardHeight: CGFloat = .infinity

    /// Hover-selection is suppressed until the mouse actually moves, so a
    /// cursor that happens to rest over a card at open doesn't steal the
    /// keyboard-driven initial selection.
    private let mouseLocationAtOpen: NSPoint = NSEvent.mouseLocation
    private var mouseHasMoved = false

    init(model: SpaceSwitcherEngine.Model, mouseLocation: NSPoint = DockObserver.getMousePosition()) {
        self.model = model
        selectCurrentSpace(nearest: mouseLocation)
    }

    var selectedSpace: SpaceInfo? {
        guard model.displays.indices.contains(selection.row) else { return nil }
        let spaces = model.displays[selection.row].spaces
        guard spaces.indices.contains(selection.col) else { return nil }
        return spaces[selection.col]
    }

    func isSelected(_ space: SpaceInfo) -> Bool {
        selectedSpace?.id == space.id
    }

    private func selectCurrentSpace(nearest mouseLocation: NSPoint) {
        let mouseScreen = NSScreen.screenFromQuartzPoint(mouseLocation)
        let rowIndex = model.displays.firstIndex { $0.screen == mouseScreen }
            ?? model.displays.indices.first { model.displays[$0].spaces.contains(where: \.isCurrent) }
            ?? 0
        guard model.displays.indices.contains(rowIndex) else { return }
        let colIndex = model.displays[rowIndex].spaces.firstIndex(where: \.isCurrent) ?? 0
        selection = Selection(row: rowIndex, col: colIndex)
    }

    func cycleForward() {
        cycle(by: 1)
    }

    func cycleBackward() {
        cycle(by: -1)
    }

    /// Trigger-key cycling walks every Space on every display in row-major
    /// order (wrapping), symmetric forward/backward; arrow keys move within and
    /// between rows.
    private func cycle(by delta: Int) {
        let flattened = flattenedPositions()
        guard !flattened.isEmpty else { return }
        let current = flattened.firstIndex(of: selection) ?? 0
        selection = flattened[(current + delta + flattened.count) % flattened.count]
    }

    /// First advance on activation; same order as every later press so
    /// Tab then Shift+Tab always returns to the current Space.
    func advance(backward: Bool) {
        cycle(by: backward ? -1 : 1)
    }

    private func flattenedPositions() -> [Selection] {
        model.displays.enumerated().flatMap { row, display in
            display.spaces.indices.map { Selection(row: row, col: $0) }
        }
    }

    func navigate(_ direction: ArrowDirection) {
        let rows = model.displays
        guard rows.indices.contains(selection.row) else { return }

        switch direction {
        case .left, .right:
            let count = rows[selection.row].spaces.count
            guard count > 0 else { return }
            let delta = direction == .right ? 1 : -1
            selection.col = (selection.col + delta + count) % count
        case .up, .down:
            guard rows.count > 1 else { return }
            let delta = direction == .down ? 1 : -1
            let newRow = (selection.row + delta + rows.count) % rows.count
            let newCount = rows[newRow].spaces.count
            guard newCount > 0 else { return }
            // Cards are equal-width and left-aligned, so the card geometrically
            // above/below shares the same column index; clamp for shorter rows.
            selection = Selection(row: newRow, col: min(selection.col, newCount - 1))
        }
    }

    func commit(_ space: SpaceInfo) {
        onCommit?(space)
    }

    func moveWindow(_ windowID: CGWindowID, to space: SpaceInfo) {
        onMoveWindowDrop?(windowID, space)
    }

    func select(_ space: SpaceInfo) {
        for (row, display) in model.displays.enumerated() {
            if let col = display.spaces.firstIndex(where: { $0.id == space.id }) {
                selection = Selection(row: row, col: col)
                return
            }
        }
    }

    func hoverSelect(_ space: SpaceInfo) {
        if !mouseHasMoved {
            let now = NSEvent.mouseLocation
            guard abs(now.x - mouseLocationAtOpen.x) > 5 || abs(now.y - mouseLocationAtOpen.y) > 5 else { return }
            mouseHasMoved = true
        }
        select(space)
    }
}
