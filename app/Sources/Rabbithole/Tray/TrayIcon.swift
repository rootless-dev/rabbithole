import AppKit

/// The menu bar icon: the app icon's rabbit ears over the rim of the hole, in one colour.
/// While uploads are running the ears shrink a little and a thin bar under them fills from
/// left to right, as in the approved mockup (design/mockups/tray-icon.html, option A).
enum TrayIcon {
    /// The icon's side in points.
    static let side: CGFloat = 18
    /// How many distinct bar lengths are drawn: one per pixel of the 16 point bar at 2x.
    static let steps = 32

    /// The progress the icon shows for a tray state: a fraction while uploading, nothing
    /// otherwise, so the icon is back to plain ears as soon as the uploads end.
    static func progress(for state: TrayState) -> Double? {
        if case .uploading(_, _, let fraction) = state { return fraction }
        return nil
    }

    /// The bar length for `progress`, in steps. Two progress values that give the same step
    /// draw the same icon, so the icon is only redrawn when the step changes.
    static func step(for progress: Double?) -> Int? {
        guard let progress else { return nil }
        let clamped = min(max(progress, 0), 1)
        return Int((clamped * Double(steps)).rounded(.down))
    }

    /// The icon for a bar of `step` steps, or the plain ears for nil. It is a template
    /// image: the menu bar tints it for the light, dark and highlighted states.
    static func image(step: Int?) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.set()
            if let step {
                drawEars(scale: 0.84)
                drawBar(fraction: CGFloat(step) / CGFloat(steps))
            } else {
                drawEars(scale: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Rabbithole"
        return image
    }

    /// Two ears over the rim of the hole, scaled around the top centre of the icon.
    private static func drawEars(scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shrink = NSAffineTransform()
        shrink.translateX(by: side / 2 * (1 - scale), yBy: 0)
        shrink.scale(by: scale)
        shrink.concat()

        let rim = NSBezierPath(ovalIn: NSRect(x: 9 - 6.7, y: 13.4 - 2.5, width: 13.4, height: 5))
        rim.lineWidth = 1.3
        rim.stroke()
        ear(centerX: 6.5, degrees: -10).fill()
        ear(centerX: 11.5, degrees: 10).fill()
    }

    /// One ear: an ellipse leaning away from the middle, turned around its foot in the hole.
    private static func ear(centerX: CGFloat, degrees: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: centerX - 1.95, y: 7.2 - 5.7, width: 3.9, height: 11.4))
        let lean = NSAffineTransform()
        lean.translateX(by: centerX, yBy: 12)
        lean.rotate(byDegrees: degrees)
        lean.translateX(by: -centerX, yBy: -12)
        path.transform(using: lean as AffineTransform)
        return path
    }

    /// The bar under the ears: a faint track with the sent part solid.
    private static func drawBar(fraction: CGFloat) {
        let track = NSRect(x: 1, y: 15.6, width: 16, height: 2)
        NSColor.black.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
        guard fraction > 0 else { return }
        NSColor.black.setFill()
        var sent = track
        sent.size.width = max(track.width * fraction, track.height)
        NSBezierPath(roundedRect: sent, xRadius: 1, yRadius: 1).fill()
    }
}
