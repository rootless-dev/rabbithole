import CoreGraphics
import XCTest

@testable import Rabbithole

final class TrayPanelPositionerTests: XCTestCase {
    func testFrameIsThreePointsBelowIconAndTwoThirtyTwoWide() {
        let icon = CGRect(x: 1000, y: 1056, width: 24, height: 24)
        let frame = TrayPanelPositioner.frame(statusItemFrame: icon, contentHeight: 150)
        XCTAssertEqual(frame.width, 232)
        XCTAssertEqual(frame.maxY, 1053)
        XCTAssertEqual(frame.maxX, 1024)
        XCTAssertEqual(frame.height, 150)
    }
}
