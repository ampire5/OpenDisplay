import XCTest
@testable import TopologyCore

final class DDCReadConfirmationTests: XCTestCase {
    func testReadStartedBeforeWriteCannotConfirmAfterInvalidation() {
        var confirmations = DDCReadConfirmation<String>()
        let generation = confirmations.generation(for: "brightness")

        confirmations.invalidate("brightness")

        XCTAssertFalse(confirmations.confirm(current: 50, maximum: 100, for: "brightness", ifGeneration: generation))
        XCTAssertNil(confirmations.reading(for: "brightness"))
    }

    func testQueuedAndCompletedWritesDiscardProofAndIntermediateReads() {
        var confirmations = DDCReadConfirmation<String>()
        let initialGeneration = confirmations.generation(for: "brightness")
        XCTAssertTrue(confirmations.confirm(current: 50, maximum: 100, for: "brightness", ifGeneration: initialGeneration))
        XCTAssertEqual(confirmations.reading(for: "brightness")?.current, 50)

        confirmations.invalidate("brightness") // A write to 70 is queued.
        XCTAssertNil(confirmations.reading(for: "brightness"))
        let whileWriting = confirmations.generation(for: "brightness")
        XCTAssertTrue(confirmations.confirm(current: 50, maximum: 100, for: "brightness", ifGeneration: whileWriting))

        confirmations.invalidate("brightness") // The hardware write completes.
        XCTAssertNil(confirmations.reading(for: "brightness"))
        XCTAssertFalse(confirmations.confirm(current: 50, maximum: 100, for: "brightness", ifGeneration: whileWriting))

        let afterWrite = confirmations.generation(for: "brightness")
        XCTAssertTrue(confirmations.confirm(current: 70, maximum: 100, for: "brightness", ifGeneration: afterWrite))
        XCTAssertEqual(confirmations.reading(for: "brightness")?.current, 70)
        XCTAssertEqual(confirmations.reading(for: "brightness")?.maximum, 100)
    }

    func testInvalidationDoesNotAffectAnotherControl() {
        var confirmations = DDCReadConfirmation<String>()
        let generation = confirmations.generation(for: "contrast")
        XCTAssertTrue(confirmations.confirm(current: 60, maximum: 100, for: "contrast", ifGeneration: generation))

        confirmations.invalidate("brightness")

        XCTAssertEqual(confirmations.reading(for: "contrast")?.current, 60)
        XCTAssertTrue(confirmations.confirm(current: 65, maximum: 100, for: "contrast", ifGeneration: generation))
    }

    func testClearDropsReadingsWithoutResettingInvalidatedGenerations() {
        var confirmations = DDCReadConfirmation<String>()
        let staleGeneration = confirmations.generation(for: "brightness")
        confirmations.invalidate("brightness")
        let freshGeneration = confirmations.generation(for: "brightness")
        XCTAssertTrue(confirmations.confirm(current: 70, maximum: 100, for: "brightness", ifGeneration: freshGeneration))

        confirmations.clearConfirmations()

        XCTAssertNil(confirmations.reading(for: "brightness"))
        XCTAssertFalse(confirmations.confirm(current: 50, maximum: 100, for: "brightness", ifGeneration: staleGeneration))
        XCTAssertTrue(confirmations.confirm(current: 70, maximum: 100, for: "brightness", ifGeneration: freshGeneration))
        XCTAssertEqual(confirmations.reading(for: "brightness")?.current, 70)
    }

    func testInvalidReadingsCannotBecomeProof() {
        var confirmations = DDCReadConfirmation<String>()
        let generation = confirmations.generation(for: "brightness")

        XCTAssertFalse(confirmations.confirm(current: -1, maximum: 100, for: "brightness", ifGeneration: generation))
        XCTAssertFalse(confirmations.confirm(current: 50, maximum: 0, for: "brightness", ifGeneration: generation))
        XCTAssertFalse(confirmations.confirm(current: 50, maximum: -1, for: "brightness", ifGeneration: generation))
        XCTAssertNil(confirmations.reading(for: "brightness"))
    }

    func testDiscreteValuesMayExceedReportedMaximum() {
        var confirmations = DDCReadConfirmation<String>()
        let generation = confirmations.generation(for: "preset")

        XCTAssertTrue(confirmations.confirm(current: 11, maximum: 1, for: "preset", ifGeneration: generation))
        XCTAssertEqual(confirmations.reading(for: "preset")?.current, 11)
        XCTAssertEqual(confirmations.reading(for: "preset")?.maximum, 1)
    }
}
