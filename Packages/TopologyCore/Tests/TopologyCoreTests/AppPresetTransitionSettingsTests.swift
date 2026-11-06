import Foundation
import XCTest
@testable import TopologyCore

final class AppPresetTransitionSettingsTests: XCTestCase {
    func testOldSettingsDefaultToOneSecond() throws {
        let settings = try JSONDecoder().decode(OpenDisplaySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.appPresetBrightnessTransitionSeconds, 1)
    }
    func testDurationRoundTripsAndClampsOnDecode() throws {
        var settings = OpenDisplaySettings()
        settings.appPresetBrightnessTransitionSeconds = 2.5
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(OpenDisplaySettings.self, from: data).appPresetBrightnessTransitionSeconds, 2.5)
        let oversized = try JSONDecoder().decode(OpenDisplaySettings.self,
            from: Data("{\"appPresetBrightnessTransitionSeconds\":100}".utf8))
        XCTAssertEqual(oversized.appPresetBrightnessTransitionSeconds, 5)
    }
}
