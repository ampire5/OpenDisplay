import XCTest
@testable import DisplayDomain

final class OSDContentTests: XCTestCase {
    func testValueClamps() {
        XCTAssertEqual(OSDContent(kind: .brightness, value: 2).value, 1)
        XCTAssertEqual(OSDContent(kind: .brightness, value: -1).value, 0)
        XCTAssertEqual(OSDContent(kind: .volume, value: 0.5).value, 0.5, accuracy: 1e-6)
    }

    func testFilledSegments() {
        XCTAssertEqual(OSDContent(kind: .brightness, value: 0).filledSegments, 0)
        XCTAssertEqual(OSDContent(kind: .brightness, value: 1).filledSegments, 16)
        XCTAssertEqual(OSDContent(kind: .brightness, value: 0.5).filledSegments, 8)
        // 0.97 * 16 = 15.52 → rounds to 16; clamp keeps it in range.
        XCTAssertEqual(OSDContent(kind: .brightness, value: 0.97).filledSegments, 16)
        XCTAssertEqual(OSDContent(kind: .brightness, value: 2).filledSegments, 16)
    }

    func testPercent() {
        XCTAssertEqual(OSDContent(kind: .volume, value: 0.5).percent, 50)
        XCTAssertEqual(OSDContent(kind: .volume, value: 0.336).percent, 34)
    }

    func testGlyphs() {
        XCTAssertEqual(OSDContent(kind: .brightness, value: 0.5).glyph, "sun.max")
        XCTAssertEqual(OSDContent(kind: .mute, value: 0.5).glyph, "speaker.slash")
        XCTAssertEqual(OSDContent(kind: .volume, value: 0).glyph, "speaker.slash")
        XCTAssertEqual(OSDContent(kind: .volume, value: 0.2).glyph, "speaker.wave.1")
        XCTAssertEqual(OSDContent(kind: .volume, value: 0.8).glyph, "speaker.wave.2")
        XCTAssertEqual(OSDContent(kind: .input, value: 0).glyph, "arrow.triangle.swap")
    }

    func testInputKindCarriesALabel() {
        let content = OSDContent(kind: .input, value: 0, label: "HDMI 2")
        XCTAssertEqual(content.label, "HDMI 2")
        XCTAssertNil(OSDContent(kind: .brightness, value: 0.5).label)
    }
    func testPartialSegmentFillTracksExactLevel() {
        let content = OSDContent(kind: .brightness, value: 0.58)
        XCTAssertEqual(content.segmentFill(at: 8), 1)
        XCTAssertEqual(content.segmentFill(at: 9), 0.28, accuracy: 0.00001)
        XCTAssertEqual(content.segmentFill(at: 10), 0)
        XCTAssertEqual(OSDContent(kind: .brightness, value: 0.05).segmentFill(at: 0), 0.8, accuracy: 0.00001)
    }

    func testSegmentFillHandlesEndpointsAndInvalidIndices() {
        for index in 0..<OSDContent.segmentCount {
            XCTAssertEqual(OSDContent(kind: .brightness, value: 0).segmentFill(at: index), 0)
            XCTAssertEqual(OSDContent(kind: .brightness, value: 1).segmentFill(at: index), 1)
        }
        let content = OSDContent(kind: .brightness, value: 0.5)
        XCTAssertEqual(content.segmentFill(at: -1), 0)
        XCTAssertEqual(content.segmentFill(at: 16), 0)
    }

}
