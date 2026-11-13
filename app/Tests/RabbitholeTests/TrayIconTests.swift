import AppKit
import XCTest

@testable import Rabbithole

@MainActor
final class TrayIconTests: XCTestCase {
    func testOnlyAnUploadInProgressShowsProgress() {
        XCTAssertEqual(TrayIcon.progress(for: .uploading(remaining: 2, total: 5, fraction: 0.4)), 0.4)
        for state in [TrayState.idle, .finished, .failed("No internet connection"), .starting, .notConfigured] {
            XCTAssertNil(TrayIcon.progress(for: state), "\(state) shows the plain icon")
        }
    }

    func testProgressIsCutIntoStepsAndClamped() {
        XCTAssertNil(TrayIcon.step(for: nil))
        XCTAssertEqual(TrayIcon.step(for: 0), 0)
        XCTAssertEqual(TrayIcon.step(for: 0.5), 16)
        XCTAssertEqual(TrayIcon.step(for: 1), 32)
        XCTAssertEqual(TrayIcon.step(for: -3), 0)
        XCTAssertEqual(TrayIcon.step(for: 7), 32)
        XCTAssertEqual(TrayIcon.step(for: 0.5), TrayIcon.step(for: 0.51), "a change too small to see keeps the step")
    }

    func testTheIconIsATemplateOfEighteenPoints() {
        for step in [nil, 0, 16, 32] as [Int?] {
            let image = TrayIcon.image(step: step)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        }
    }

    func testThePlainIconHasNoBar() throws {
        let pixels = try Self.render(step: nil)
        // Where the bar would be, far from the ears and the rim of the hole.
        XCTAssertEqual(pixels.alpha(x: 1.5, y: 16.6), 0, accuracy: 0.02)
        XCTAssertEqual(pixels.alpha(x: 16.5, y: 16.6), 0, accuracy: 0.02)
    }

    func testTheBarIsSolidUpToTheProgressAndFaintAfterIt() throws {
        let pixels = try Self.render(step: 16)
        XCTAssertEqual(pixels.alpha(x: 5, y: 16.6), 1, accuracy: 0.05, "sent part")
        XCTAssertEqual(pixels.alpha(x: 13, y: 16.6), 0.3, accuracy: 0.05, "part still to send")
    }

    func testAFullBarIsSolidFromEndToEnd() throws {
        let pixels = try Self.render(step: 32)
        XCTAssertEqual(pixels.alpha(x: 3, y: 16.6), 1, accuracy: 0.05)
        XCTAssertEqual(pixels.alpha(x: 15, y: 16.6), 1, accuracy: 0.05)
    }

    func testAnEmptyBarShowsOnlyTheTrack() throws {
        let pixels = try Self.render(step: 0)
        XCTAssertEqual(pixels.alpha(x: 3, y: 16.6), 0.3, accuracy: 0.05)
        XCTAssertEqual(pixels.alpha(x: 15, y: 16.6), 0.3, accuracy: 0.05)
    }

    /// Writes the icon large, on a light and a dark menu bar, to compare with the mockup.
    func testWritesRendersForComparison() throws {
        for (name, step) in [("idle", nil), ("35", 11), ("80", 26)] as [(String, Int?)] {
            for (theme, background, ink) in [
                ("light", NSColor(white: 0.9, alpha: 1), NSColor.black),
                ("dark", NSColor(white: 0.15, alpha: 1), NSColor.white),
            ] {
                let scale: CGFloat = 8
                let side = Int(TrayIcon.side * scale)
                let rep = try XCTUnwrap(Self.bitmap(side: side))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let frame = NSRect(x: 0, y: 0, width: side, height: side)
                background.setFill()
                frame.fill()
                // A template image is a mask: tint it the way the menu bar does.
                let tinted = NSImage(size: frame.size, flipped: false) { rect in
                    TrayIcon.image(step: step).draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try FileManager.default.createDirectory(at: Offscreen.directory, withIntermediateDirectories: true)
                try data.write(to: Offscreen.directory.appending(path: "tray-icon-\(name)-\(theme).png"))
            }
        }
    }

    // MARK: - Rendering

    private static func bitmap(side: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    }

    /// The icon drawn at 4 pixels per point on a transparent background.
    private static func render(step: Int?) throws -> Pixels {
        let scale = 4
        let side = Int(TrayIcon.side) * scale
        let rep = try XCTUnwrap(bitmap(side: side))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        TrayIcon.image(step: step).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return Pixels(rep: rep, scale: CGFloat(scale))
    }

    private struct Pixels {
        let rep: NSBitmapImageRep
        let scale: CGFloat

        /// The opacity at a point given in the icon's own coordinates, y growing downwards.
        func alpha(x: CGFloat, y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? -1
        }
    }
}
