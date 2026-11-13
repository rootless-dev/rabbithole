import AppKit
import SwiftUI

/// Colors from the approved mockups (`design/mockups`). Every color has a light and a dark
/// value and follows the effective appearance of the view that draws it.
enum Theme {
    // Text
    static let ink = dynamic(0x161A26, 0xF1F3FA)
    /// Secondary text on solid surfaces (main window).
    static let muted = dynamic(0x62697E, 0x9AA1B8)
    /// Secondary text on glass (tray window, small windows).
    static let glassMuted = dynamic(0x161A26, 0xF1F3FA, 0.62, 0.62)
    static let smallWindowMuted = dynamic(0x161A26, 0xF1F3FA, 0.66, 0.66)
    /// Disabled text.
    static let off = dynamic(0x161A26, 0xF1F3FA, 0.34, 0.32)

    // Surfaces
    static let main = dynamic(0xFBFBFD, 0x1A1D2B)
    static let card = dynamic(0xFFFFFF, 0x222638)
    /// Tint laid over the blurred backdrop of glass surfaces.
    static let glass = dynamic(0xFAFBFF, 0x1A1D2C, 0.58, 0.55)
    static let glassEdge = dynamic(0xFFFFFF, 0xFFFFFF, 0.7, 0.16)
    /// Highlight of the selected sidebar row.
    static let hot = dynamic(0xFFFFFF, 0xFFFFFF, 0.6, 0.12)
    /// Highlight of the hovered tray menu row.
    static let glassHot = dynamic(0xFFFFFF, 0xFFFFFF, 0.55, 0.13)
    /// Drop area background while a file is held over the tray window.
    static let tint = dynamic(0xECEAFD, 0x2F2B55)

    // Lines and tracks
    static let line = dynamic(0x161A26, 0xFFFFFF, 0.11, 0.10)
    static let glassLine = dynamic(0x161A26, 0xFFFFFF, 0.12, 0.13)
    static let track = dynamic(0x161A26, 0xFFFFFF, 0.12, 0.14)
    static let glassTrack = dynamic(0x161A26, 0xFFFFFF, 0.14, 0.16)
    /// Track of switches and the first-launch menu bar picture.
    static let strongTrack = dynamic(0x161A26, 0xFFFFFF, 0.16, 0.18)

    // Meaning
    static let accent = dynamic(0x4A3FD0, 0xA99BFF)
    /// Text on an accent background.
    static let onAccent = dynamic(0xFFFFFF, 0x14162A)
    static let ok = dynamic(0x1C8F63, 0x5FD0A0)
    static let bad = dynamic(0xC2372F, 0xFF8A80)
    static let bannerBad = dynamic(0xB3261E, 0xFF9B92)
    static let bannerBadBackground = dynamic(0xFDE7E4, 0xFF5A50, 1, 0.15)
    /// Background of the note that deleting from the bucket cannot be undone.
    static let badSoft = dynamic(0xC2372F, 0xFF8A80, 0.09, 0.12)
    /// Background of the file row under the pointer.
    static let hover = dynamic(0x161A26, 0xFFFFFF, 0.045, 0.05)
    /// Border of the upload row under the pointer: the accent mixed 45% into the line color.
    static let hoverLine = dynamic(0x443BBC, 0xB2A6FF, 0.51, 0.505)
    /// Shadow under the actions menu and the confirmation sheets.
    static let shadow = dynamic(0x14183C, 0x000000, 0.32, 0.55)
    /// A paused upload: its ring and its progress line.
    static let hold = dynamic(0x9A6A12, 0xF0C267)
    /// A download: its ring and its progress line.
    static let down = dynamic(0x1479A8, 0x6CC8EE)
    /// Background of the box that says why a bucket could not be created.
    static let badTint = dynamic(0xC2372F, 0xFF8A80, 0.10, 0.10)
    /// The glow around the focused, or refused, name field of "Create a new bucket".
    static let accentGlow = dynamic(0x4A3FD0, 0xA99BFF, 0.25, 0.25)
    static let badGlow = dynamic(0xC2372F, 0xFF8A80, 0.18, 0.18)
    static let warn = dynamic(0x8A5A00, 0xFFD98A)
    static let warnBackground = dynamic(0xFFF3D6, 0xFFBE46, 1, 0.14)

    // The same ink, muted and bad for text that AppKit draws.
    static let inkNS = dynamicNS(0x161A26, 0xF1F3FA)
    static let mutedNS = dynamicNS(0x62697E, 0x9AA1B8)
    static let badNS = dynamicNS(0xC2372F, 0xFF8A80)

    static func dynamic(
        _ light: UInt32, _ dark: UInt32, _ lightAlpha: Double = 1, _ darkAlpha: Double = 1
    ) -> Color {
        Color(nsColor: dynamicNS(light, dark, lightAlpha, darkAlpha))
    }

    static func dynamicNS(
        _ light: UInt32, _ dark: UInt32, _ lightAlpha: Double = 1, _ darkAlpha: Double = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

/// The app's light, dark or system appearance choice.
enum ThemeChoice: String, CaseIterable, Sendable {
    case light, dark, system

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Match system"
        }
    }

    /// The appearance to force on the app, or nil to follow the system.
    var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

extension EnvironmentValues {
    /// True when views are drawn offscreen for comparison with the mockups. System blur
    /// materials do not render there, so glass surfaces draw a flat stand-in instead.
    @Entry var flatMaterials = false
}
