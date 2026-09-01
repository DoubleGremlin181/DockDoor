import Cocoa

extension CGRect {
    /// Extends the frame by the given value on all sides.
    /// - Parameter value: The amount to extend the frame.
    /// - Returns: A new `CGRect` extended by the specified value.
    func extended(by value: CGFloat) -> CGRect {
        CGRect(
            x: origin.x - value,
            y: origin.y - value,
            width: size.width + 2 * value,
            height: size.height + 2 * value
        )
    }

    /// Converts an AppKit rect (bottom-left origin) to Quartz/CG global
    /// coordinates (top-left origin), given the primary screen's maxY.
    func flippedToQuartz(primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: origin.x, y: primaryScreenMaxY - maxY, width: width, height: height)
    }
}
