import XCTest
@testable import TopologyCore
final class AppPresetRequestClockTests: XCTestCase {
 func testTimeSpentWaitingForOldWriteCountsTowardNewDebounce() {
  var clock = AppPresetRequestClock()
  let epoch = Date(timeIntervalSince1970: 1000)
  let a = AppPresetPolicy.AppPreset(bundleIdentifier: "example.a", applicationName: "A", brightness: 0.4)
  let b = AppPresetPolicy.AppPreset(bundleIdentifier: "example.b", applicationName: "B", brightness: 0.7)
  let displays = [AppPresetPolicy.DisplaySnapshot(recordID: "display", brightness: 0.5)]
  let old = AppPresetPolicy.ActivationState(activeBundleID: a.bundleIdentifier,
    priorStateByDisplay: ["display": .init(brightness: 0.5)], appliedPreset: a)
  clock.observe(b.bundleIdentifier, at: epoch)
  let decision = AppPresetPolicy.resolve(.init(frontmostBundleID: b.bundleIdentifier,
    now: epoch.addingTimeInterval(1), presets: [a,b], displays: displays), state: clock.seed(old))
  XCTAssertNil(decision.rescheduleAfter)
  XCTAssertEqual(decision.applyWrites.first?.brightness, 0.7)
 }
 func testSameDesiredApplicationDoesNotRestartClock() {
  var clock = AppPresetRequestClock()
  let epoch = Date(timeIntervalSince1970: 1000)
  clock.observe("example.a", at: epoch)
  clock.observe("example.a", at: epoch.addingTimeInterval(0.3))
  XCTAssertEqual(clock.seed(.init()).pendingSince, epoch)
 }
 func testUnconfiguredApplicationsShareOneDeactivationWindow() {
  var clock = AppPresetRequestClock()
  let epoch = Date(timeIntervalSince1970: 1000)
  clock.observe(nil, at: epoch)
  clock.observe(nil, at: epoch.addingTimeInterval(0.3))
  let state = clock.seed(.init(activeBundleID: "example.a"))
  XCTAssertEqual(state.pendingSince, epoch)
  XCTAssertNil(state.pendingBundleID)
 }
}
