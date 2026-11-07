import Foundation
import XCTest
@testable import TopologyCore

final class MediaKeyTests: XCTestCase {
    func testNXKeyTypeMapping() {
        XCTAssertEqual(MediaKeyAction.from(nxKeyType: NXKeyType.brightnessUp), .brightnessUp)
        XCTAssertEqual(MediaKeyAction.from(nxKeyType: NXKeyType.brightnessDown), .brightnessDown)
        XCTAssertEqual(MediaKeyAction.from(nxKeyType: NXKeyType.soundUp), .volumeUp)
        XCTAssertEqual(MediaKeyAction.from(nxKeyType: NXKeyType.soundDown), .volumeDown)
        XCTAssertEqual(MediaKeyAction.from(nxKeyType: NXKeyType.mute), .muteToggle)
    }

    func testUnknownNXKeyTypeIsNil() {
        XCTAssertNil(MediaKeyAction.from(nxKeyType: 99))
        XCTAssertNil(MediaKeyAction.from(nxKeyType: -1))
    }

    func testVolumeVsBrightnessClassification() {
        XCTAssertTrue(MediaKeyAction.volumeUp.isVolume)
        XCTAssertTrue(MediaKeyAction.muteToggle.isVolume)
        XCTAssertTrue(MediaKeyAction.brightnessUp.isBrightness)
        XCTAssertFalse(MediaKeyAction.brightnessDown.isVolume)
    }

    func testSign() {
        XCTAssertEqual(MediaKeyAction.brightnessUp.sign, 1)
        XCTAssertEqual(MediaKeyAction.volumeDown.sign, -1)
        XCTAssertEqual(MediaKeyAction.muteToggle.sign, 0)
    }

    func testSignedDeltaCoarseAndFine() {
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: false), 0.1, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: true), 0.025, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.volumeDown.signedDelta(fineStep: false), -1.0 / 16.0, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.muteToggle.signedDelta(fineStep: false), 0, accuracy: 1e-6)
    }
    func testConfiguredBrightnessStepDoesNotChangeVolume() {
        XCTAssertEqual(MediaKeyAction.brightnessDown.signedDelta(fineStep: false, brightnessStepPercent: 20), -0.2, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: true, brightnessStepPercent: 20), 0.05, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.volumeUp.signedDelta(fineStep: false, brightnessStepPercent: 20), 1.0 / 16, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: false, brightnessStepPercent: 0), 0.01, accuracy: 1e-6)
        XCTAssertEqual(MediaKeyAction.brightnessUp.signedDelta(fineStep: false, brightnessStepPercent: 500), 1, accuracy: 1e-6)
    }

    func testBrightnessStepSettingsDefaultAndRoundTrip() throws {
        let old = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.brightnessStepPercent, 10)
        var settings = OpenDisplaySettings()
        settings.brightnessStepPercent = 7
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(OpenDisplaySettings.self, from: data).brightnessStepPercent, 7)
        let clamped = try JSONDecoder().decode(OpenDisplaySettings.self,
            from: Data("{\"brightnessStepPercent\":999}".utf8))
        XCTAssertEqual(clamped.brightnessStepPercent, 100)
    }

}
