import XCTest
@testable import TopologyCore
final class SystemColorPresetTests: XCTestCase {
    func testCapturesBeforeDisablingAndRestoresWhenAppLeaves() {
        let observed = SystemColorPresetPolicy.State(nightShift: true, trueTone: true)
        let apply = SystemColorPresetPolicy.plan(request: .init(nightShift: false), observed: observed, owed: .init())
        XCTAssertEqual(apply.baseline.nightShift, true)
        XCTAssertNil(apply.baseline.trueTone)
        XCTAssertEqual(apply.writes.nightShift, false)
        let restore = SystemColorPresetPolicy.plan(request: .init(), observed: .init(nightShift: false), owed: apply.baseline)
        XCTAssertEqual(restore.writes.nightShift, true)
        XCTAssertTrue(restore.restoringNightShift)
    }
    func testSwitchingBetweenAppsKeepsOriginalBaseline() {
        let decision = SystemColorPresetPolicy.plan(request: .init(nightShift: true, trueTone: false),
            observed: .init(nightShift: false, trueTone: true), owed: .init(nightShift: true))
        XCTAssertEqual(decision.baseline, .init(nightShift: true, trueTone: true))
        XCTAssertEqual(decision.writes, .init(nightShift: true, trueTone: false))
    }
    func testUnchangedStateDoesNotWriteAndUnavailableModeDoesNotCapture() {
        let decision = SystemColorPresetPolicy.plan(request: .init(nightShift: false, trueTone: false),
            observed: .init(nightShift: false), owed: .init())
        XCTAssertEqual(decision.writes, .init())
        XCTAssertNil(decision.baseline.trueTone)
    }
    func testUnavailableRestoreRemainsOwed() {
        let decision = SystemColorPresetPolicy.plan(request: .init(), observed: .init(), owed: .init(trueTone: true))
        XCTAssertEqual(decision.baseline.trueTone, true)
        XCTAssertFalse(decision.restoringTrueTone)
    }
    func testOldAppPresetDecodesWithoutSystemModeFields() throws {
        let preset = AppPresetPolicy.AppPreset(bundleIdentifier: "example.editor", applicationName: "Editor")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(AppPresetPolicy.AppPreset.self, from: data)
        XCTAssertNil(decoded.nightShift)
        XCTAssertNil(decoded.trueTone)
    }
}
