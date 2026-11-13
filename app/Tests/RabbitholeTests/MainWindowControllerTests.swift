import AppKit
import XCTest

@testable import Rabbithole

@MainActor
final class MainWindowControllerTests: XCTestCase {
    private func makeController(_ fixture: UIFixture, record: @escaping (Bool) -> Void) -> MainWindowController {
        MainWindowController(
            context: fixture.context, thumbnails: fixture.thumbnails,
            makeSetup: { fatalError("the account is configured, so setup is never built") },
            setDockIconVisible: record)
    }

    func testTheDockIconIsShownWhileTheWindowIsOpenAndHiddenWhenItCloses() async {
        let fixture = await UIFixture()
        var changes: [Bool] = []
        let controller = makeController(fixture) { changes.append($0) }

        controller.show(section: .overview)
        XCTAssertEqual(changes, [true], "showing the window shows the Dock icon")

        controller.close()
        XCTAssertEqual(changes, [true, false], "closing the window hides the Dock icon")
    }

    func testTheDockIconComesBackWhenTheWindowIsShownAgain() async {
        let fixture = await UIFixture()
        var changes: [Bool] = []
        let controller = makeController(fixture) { changes.append($0) }

        controller.show(section: .overview)
        controller.close()
        controller.show(section: .history)

        XCTAssertEqual(changes.last, true)
        controller.close()
    }

    func testClosingBeforeTheWindowWasEverShownDoesNotTouchTheDockIcon() async {
        let fixture = await UIFixture()
        var changes: [Bool] = []
        let controller = makeController(fixture) { changes.append($0) }

        controller.close()

        XCTAssertEqual(changes, [])
    }
}
