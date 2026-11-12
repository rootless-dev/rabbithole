import CoreGraphics

/// Where the tray window goes, in AppKit screen coordinates (origin at the bottom left).
enum TrayPanelPositioner {
    static let width: CGFloat = 232
    static let gap: CGFloat = 3
    /// Padding around the rows of a tray menu; the two lists line up row to row.
    static let menuPadding: CGFloat = 4

    /// The window hangs `gap` points below the status item and is right-aligned to its edge.
    static func frame(statusItemFrame: CGRect, contentHeight: CGFloat) -> CGRect {
        let top = statusItemFrame.minY - gap
        return CGRect(
            x: statusItemFrame.maxX - width, y: top - contentHeight,
            width: width, height: contentHeight)
    }

    /// The "Recent uploads" list sits `gap` points to the left of the tray window, with its
    /// first row level with the "Recent uploads" row (`rowTop` points below the window's top).
    static func recentFrame(
        trayFrame: CGRect, rowTop: CGFloat, width: CGFloat, contentHeight: CGFloat
    ) -> CGRect {
        let top = trayFrame.maxY - (rowTop - menuPadding)
        return CGRect(
            x: trayFrame.minX - gap - width, y: top - contentHeight,
            width: width, height: contentHeight)
    }
}
