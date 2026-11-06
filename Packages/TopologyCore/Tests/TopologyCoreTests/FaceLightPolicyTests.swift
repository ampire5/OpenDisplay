import XCTest
@testable import TopologyCore

final class FaceLightPolicyTests: XCTestCase {
    private typealias Policy = FaceLightPolicy

    func testActivationNeverChangesContrast() {
        let outcome = Policy.toggle(owedPriorState: nil, liveBrightness: 0.4, liveContrast: 0.5)
        XCTAssertTrue(outcome.isNowActive)
        XCTAssertEqual(outcome.brightnessWrite, 1.0)
        XCTAssertNil(outcome.contrastWrite)
        XCTAssertEqual(outcome.priorStateToPersist, Policy.PriorState(brightness: 0.4))
    }

    func testActivatingWithNoDDCContrastSkipsTheContrastWrite() {
        // No-DDC (or DDC-without-contrast) displays get the overlay-only version: brightness still
        // maxes out, but there is no contrast channel to max or remember.
        let outcome = Policy.toggle(owedPriorState: nil, liveBrightness: 0.6, liveContrast: nil)
        XCTAssertEqual(outcome.brightnessWrite, 1.0)
        XCTAssertNil(outcome.contrastWrite)
        XCTAssertNil(outcome.priorStateToPersist?.contrast)
    }

    func testDeactivatingRetainsDebtUntilVerifiedRestore() {
        let owed = Policy.PriorState(brightness: 0.4, contrast: 0.5)
        let outcome = Policy.toggle(owedPriorState: owed, liveBrightness: 1.0, liveContrast: 1.0)
        XCTAssertFalse(outcome.isNowActive)
        XCTAssertEqual(outcome.brightnessWrite, 0.4)
        XCTAssertEqual(outcome.contrastWrite, 0.5)
        XCTAssertEqual(outcome.priorStateToPersist, owed)
    }

    func testDeactivatingWithNoOwedContrastRestoresBrightnessOnly() {
        let owed = Policy.PriorState(brightness: 0.7, contrast: nil)
        let outcome = Policy.toggle(owedPriorState: owed, liveBrightness: 1.0, liveContrast: nil)
        XCTAssertEqual(outcome.brightnessWrite, 0.7)
        XCTAssertNil(outcome.contrastWrite)
    }

    func testOverlayKelvinIsTheColorTemperatureCurvesWarmestStop() {
        XCTAssertEqual(Policy.overlayKelvin, ColorTemperatureCurve.minKelvin)
    }

    func testOverlayAlphaIsAStrongButTranslucentWash() {
        // Opaque (1.0) would blind the panel underneath — including the video call itself on a
        // single-monitor setup — and too faint (below 0.4) wouldn't read as a fill light.
        XCTAssertGreaterThanOrEqual(Policy.overlayAlpha, 0.4)
        XCTAssertLessThanOrEqual(Policy.overlayAlpha, 0.6)
        XCTAssertLessThan(Policy.overlayAlpha, 1.0)
    }

    func testPriorStateRoundTripsThroughJSON() throws {
        let priorState = Policy.PriorState(brightness: 0.42, contrast: 0.73)
        let encoded = try JSONEncoder().encode(priorState)
        let decoded = try JSONDecoder().decode(Policy.PriorState.self, from: encoded)
        XCTAssertEqual(decoded, priorState)
    }
    func testLegacyContrastDebtSurvivesFailedOrUnknownRestoration() {
        let prior = Policy.PriorState(brightness: 0.4, contrast: 0.7)
        XCTAssertEqual(Policy.debtAfterRestore(prior, brightnessVerified: true, contrastVerified: false), prior)
        XCTAssertEqual(Policy.debtAfterRestore(prior, brightnessVerified: false, contrastVerified: true), prior)
        XCTAssertNil(Policy.debtAfterRestore(prior, brightnessVerified: true, contrastVerified: true))
        let brightnessOnly = Policy.PriorState(brightness: 0.4)
        XCTAssertNil(Policy.debtAfterRestore(brightnessOnly, brightnessVerified: true, contrastVerified: false))
    }

    func testRestoreTargetUsesFreshNon100MaximumAndRejectsUnknownScale() {
        XCTAssertEqual(Policy.restoreTarget(level: 0.7, maximum: 200), 140)
        XCTAssertNil(Policy.restoreTarget(level: 0.7, maximum: nil))
        XCTAssertNil(Policy.restoreTarget(level: 0.7, maximum: 0))
        XCTAssertNil(Policy.restoreTarget(level: .nan, maximum: 100))
    }

    func testLegacyStateDecodesWithoutInventingARoute() throws {
        let legacy = Data(#"{"brightness":0.4,"contrast":0.7}"#.utf8)
        let prior = try JSONDecoder().decode(Policy.PriorState.self, from: legacy)
        XCTAssertNil(prior.brightnessRoute)
        XCTAssertEqual(prior.contrast, 0.7)
        for route in [Policy.BrightnessRoute.hardware, .native, .software] {
            let saved = Policy.PriorState(brightness: 0.4, brightnessRoute: route)
            XCTAssertEqual(try JSONDecoder().decode(Policy.PriorState.self, from: JSONEncoder().encode(saved)), saved)
        }
    }

    @MainActor
    func testRapidTransitionsSerializeAndRetainOriginalBaseline() async {
        let queue = FaceLightTransitionQueue<String>()
        var live: Float = 0.4
        var debt: Policy.PriorState?
        var captured: [Float] = []
        for _ in 0..<3 {
            queue.enqueue(for: "display") {
                await Task.yield()
                let result = Policy.toggle(owedPriorState: debt, liveBrightness: live, liveContrast: 0.7)
                debt = result.priorStateToPersist
                if result.isNowActive { captured.append(debt!.brightness) }
                live = result.brightnessWrite!
                if !result.isNowActive {
                    debt = Policy.debtAfterRestore(debt!, brightnessVerified: true, contrastVerified: true)
                }
            }
        }
        XCTAssertTrue(queue.contains("display"))
        await queue.drain()
        XCTAssertEqual(captured, [0.4, 0.4])
        XCTAssertEqual(debt?.brightness, 0.4)
        XCTAssertEqual(live, 1)
        XCTAssertFalse(queue.contains("display"))
    }
    func testFailedWriteMissingReadbackAndMismatchedReadbackKeepDebt() {
        let prior = Policy.PriorState(brightness: 0.4, contrast: 0.7)
        for (wrote, actual) in [(false, Optional(140)), (true, nil), (true, Optional(200))] {
            let verified = Policy.hardwareWriteVerified(succeeded: wrote, target: 140, readback: actual)
            XCTAssertFalse(verified)
            XCTAssertEqual(Policy.debtAfterRestore(prior, brightnessVerified: true, contrastVerified: verified), prior)
        }
        XCTAssertTrue(Policy.hardwareWriteVerified(succeeded: true, target: 140, readback: 140))
        XCTAssertTrue(Policy.hardwareWriteVerified(succeeded: true, target: 140, readback: 141))
    }
    func testLegacyExternalSoftwareFallbackCannotReleaseHardwareDebt() {
        let legacy = Policy.PriorState(brightness: 0.4)
        let route = Policy.restoreRoute(for: legacy, isBuiltIn: false, currentRoute: .software)
        XCTAssertEqual(route, .hardware)
        let hardwareUnavailable = false
        XCTAssertEqual(Policy.debtAfterRestore(legacy, brightnessVerified: hardwareUnavailable,
                                               contrastVerified: true), legacy)
        XCTAssertEqual(Policy.restoreRoute(for: legacy, isBuiltIn: false, currentRoute: nil), .hardware)
        XCTAssertEqual(Policy.restoreRoute(for: legacy, isBuiltIn: false, currentRoute: .native), .native)
        XCTAssertEqual(Policy.restoreRoute(for: legacy, isBuiltIn: true, currentRoute: .software), .native)
    }

    func testSavedSoftwareRouteStillRestoresSoftwareBrightness() {
        let saved = Policy.PriorState(brightness: 0.4, brightnessRoute: .software)
        XCTAssertEqual(Policy.restoreRoute(for: saved, isBuiltIn: false, currentRoute: .hardware), .software)
        XCTAssertNil(Policy.debtAfterRestore(saved, brightnessVerified: true, contrastVerified: false))
    }
}
