import XCTest
@testable import TopologyCore

final class SettingsNavigationTests: XCTestCase {
    func testArrangementDoesNotKeepPreviouslySelectedSection() {
        var state = SettingsNavigation()
        state.section = .about
        state.open(.arrange)
        XCTAssertEqual(state.section, .arrange)
        XCTAssertNil(state.displayFocus)
    }

    func testRepeatedDisplayLinkAlwaysIssuesNewScrollRequest() {
        var state = SettingsNavigation()
        state.openDisplay("external", focus: .colour)
        let first = state.revision
        state.section = .health
        state.openDisplay("external", focus: .colour)
        XCTAssertEqual(state.section, .displays)
        XCTAssertEqual(state.displayID, "external")
        XCTAssertEqual(state.displayFocus, .colour)
        XCTAssertGreaterThan(state.revision, first)
    }

    func testResolutionAndColourAreDifferentDestinations() {
        var state = SettingsNavigation()
        state.openDisplay("first", focus: .resolution)
        state.openDisplay("second", focus: .colour)
        XCTAssertEqual(state.displayID, "second")
        XCTAssertEqual(state.displayFocus, .colour)
        state.open(.scenes)
        XCTAssertNil(state.displayFocus)
    }
}
