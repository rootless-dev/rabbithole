import CoreGraphics

/// Where the tray window goes, in AppKit screen coordinates (origin at the bottom left).
enum TrayPanelPositioner {
    static let width: CGFloat = 232
    static let gap: CGFloat = 3

    /// The window hangs `gap` points below the status item and is right-aligned to its edge.
    static func frame(statusItemFrame: CGRect, contentHeight: CGFloat) -> CGRect {
        let top = statusItemFrame.minY - gap
        return CGRect(
            x: statusItemFrame.maxX - width, y: top - contentHeight,
            width: width, height: contentHeight)
    }
}
