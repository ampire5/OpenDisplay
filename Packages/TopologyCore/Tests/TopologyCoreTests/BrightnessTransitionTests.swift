import XCTest
@testable import TopologyCore

final class BrightnessTransitionTests: XCTestCase {
    func testDurationClampsFiniteValuesAndDefaultsNonfiniteValues() {
        XCTAssertEqual(BrightnessTransition.duration(-1), 0)
        XCTAssertEqual(BrightnessTransition.duration(0), 0)
        XCTAssertEqual(BrightnessTransition.duration(2.5), 2.5)
        XCTAssertEqual(BrightnessTransition.duration(8), 5)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(BrightnessTransition.duration(invalid), 1)
        }
    }

    func testZeroDurationAppliesOnlyChangedClampedTargetImmediately() {
        let steps = BrightnessTransition.steps(from: -10, to: 150, seconds: 0, maximum: 100)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.offset, 0)
        XCTAssertEqual(steps.first?.value, 100)
        XCTAssertTrue(BrightnessTransition.steps(from: 120, to: 100, seconds: 0, maximum: 100).isEmpty)
    }

    func testUnchangedOrInvalidHardwareRangeDoesNotWrite() {
        XCTAssertTrue(BrightnessTransition.steps(from: 40, to: 40, seconds: 1, maximum: 100).isEmpty)
        for maximum in [0, -1] {
            XCTAssertTrue(BrightnessTransition.steps(from: 0, to: 100, seconds: 1, maximum: maximum).isEmpty)
        }
    }

    func testSubIntervalTransitionHasOnlyOneFinalWrite() {
        let steps = BrightnessTransition.steps(from: 0, to: 100, seconds: 0.05, maximum: 100)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.offset, 0.05)
        XCTAssertEqual(steps.first?.value, 100)
    }

    func testSmoothstepEasesBothEndsWithExactEndpoint() {
        let steps = BrightnessTransition.steps(from: 0, to: 100, seconds: 1, maximum: 100)
        XCTAssertEqual(steps.map(\.value), [3, 10, 22, 35, 50, 65, 78, 90, 97, 100])
        XCTAssertEqual(steps.last?.offset, 1)
    }

    func testDecreasingTransitionIsMonotonicAndDoesNotRepeatStart() {
        let steps = BrightnessTransition.steps(from: 100, to: 0, seconds: 1, maximum: 100)
        XCTAssertEqual(steps.map(\.value), [97, 90, 78, 65, 50, 35, 22, 10, 3, 0])
        XCTAssertEqual(steps.last?.offset, 1)
    }

    func testSmallDeltaSkipsDuplicateValuesAndKeepsFinalAtDeadline() {
        for (start, target) in [(49, 50), (50, 49)] {
            let steps = BrightnessTransition.steps(from: start, to: target, seconds: 5, maximum: 100)
            XCTAssertEqual(steps.count, 1)
            XCTAssertEqual(steps.first?.value, target)
            XCTAssertEqual(steps.first?.offset, 5)
        }
    }

    func testFractionalDurationsKeepEveryWriteAtLeast100MillisecondsApart() {
        for duration in [0.1, 0.11, 0.19, 0.25, 0.99, 1.01, 4.99, 5.0] {
            let steps = BrightnessTransition.steps(from: 0, to: 10_000, seconds: duration, maximum: 10_000)
            XCTAssertEqual(steps.last?.offset, duration)
            XCTAssertEqual(steps.last?.value, 10_000)
            var previousOffset = 0.0
            var previousValue = 0
            for step in steps {
                XCTAssertGreaterThanOrEqual(step.offset - previousOffset, 0.1 - 1e-12)
                XCTAssertGreaterThan(step.value, previousValue)
                XCTAssertLessThanOrEqual(step.value, 10_000)
                previousOffset = step.offset
                previousValue = step.value
            }
        }
    }

    func testLargeHardwareIntegersDoNotOvershootThroughFloatingPointRounding() {
        let start = Int.max - 2
        let target = Int.max - 1
        let steps = BrightnessTransition.steps(from: start, to: target, seconds: 1, maximum: Int.max)
        XCTAssertEqual(steps.map(\.value), [target])
        XCTAssertEqual(steps.last?.offset, 1)
    }

    func testHardwareClampingAndDurationNormalizationApplyToPlans() {
        let steps = BrightnessTransition.steps(from: 200, to: -5, seconds: 20, maximum: 100)
        XCTAssertEqual(steps.last?.value, 0)
        XCTAssertEqual(steps.last?.offset, 5)
        XCTAssertTrue(steps.allSatisfy { (0...100).contains($0.value) })
        XCTAssertEqual(BrightnessTransition.steps(from: 0, to: 100, seconds: .nan, maximum: 100).last?.offset, 1)
        XCTAssertEqual(BrightnessTransition.steps(from: 0, to: 100, seconds: -1, maximum: 100).first?.offset, 0)
    }
}

@MainActor
final class BrightnessTransitionExecutionTests: XCTestCase {
    @MainActor private final class Clock {
        var time = 0.0
        var current = true
        var writes: [(time: Double, value: Int)] = []
        var writeLatency = 0.0
        var failWrite = false
        var invalidateOnWait = false
        var invalidateOnWrite = false
        var cancelOnWait = false

        func run(_ steps: [BrightnessTransition.Step]) async -> Bool {
            await BrightnessTransition.run(steps: steps,
                isCurrent: { self.current }, now: { self.time },
                wait: { delay in
                    self.time += delay
                    if self.invalidateOnWait { self.current = false }
                    if self.cancelOnWait { withUnsafeCurrentTask { $0?.cancel() } }
                },
                write: { value in
                    self.writes.append((self.time, value))
                    self.time += self.writeLatency
                    if self.invalidateOnWrite { self.current = false }
                    return !self.failWrite
                })
        }
    }

    func testExecutionUsesAbsoluteOffsetsInsteadOfAccumulatingWriteLatency() async {
        let clock = Clock()
        clock.writeLatency = 0.03
        let success = await clock.run([.init(offset: 0.1, value: 10), .init(offset: 0.5, value: 20), .init(offset: 0.9, value: 30)])
        XCTAssertTrue(success)
        XCTAssertEqual(clock.writes.map(\.value), [10, 20, 30])
        for (actual, expected) in zip(clock.writes.map(\.time), [0.1, 0.5, 0.9]) {
            XCTAssertEqual(actual, expected, accuracy: 1e-12)
        }
    }

    func testSlowWritesSkipObsoleteSamplesAndAlwaysApplyFinalTarget() async {
        let clock = Clock()
        clock.writeLatency = 0.35
        let success = await clock.run([.init(offset: 0.1, value: 10), .init(offset: 0.2, value: 20),
            .init(offset: 0.3, value: 30), .init(offset: 0.4, value: 40), .init(offset: 0.5, value: 50)])
        XCTAssertTrue(success)
        XCTAssertEqual(clock.writes.map(\.value), [10, 50])
        for (before, after) in zip(clock.writes, clock.writes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.time - before.time, 0.1 - 1e-12)
        }
    }

    func testWriteCompletionStartsMinimumPauseEvenWhenBusWriteIsDelayed() async {
        let clock = Clock()
        clock.writeLatency = 0.2
        let success = await clock.run([.init(offset: 0.1, value: 10), .init(offset: 0.2, value: 20),
            .init(offset: 0.3, value: 30), .init(offset: 0.4, value: 40), .init(offset: 0.5, value: 50)])
        XCTAssertTrue(success)
        XCTAssertEqual(clock.writes.map(\.value), [10, 40, 50])
        for (before, after) in zip(clock.writes, clock.writes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.time - (before.time + 0.2), 0.1 - 1e-12)
        }
        XCTAssertEqual(clock.writes.last?.time ?? -1, 0.7, accuracy: 1e-12)
    }

    func testExecutionEnforcesSpacingEvenForCloselyPlannedSamples() async {
        let clock = Clock()
        let success = await clock.run([.init(offset: 0, value: 1), .init(offset: 0.05, value: 2), .init(offset: 0.06, value: 3)])
        XCTAssertTrue(success)
        XCTAssertEqual(clock.writes.map(\.value), [1, 3])
        XCTAssertEqual(clock.writes.last?.time ?? -1, 0.1, accuracy: 1e-12)
    }

    func testSupersededDuringWaitDoesNotWrite() async {
        let clock = Clock()
        clock.invalidateOnWait = true
        let success = await clock.run([.init(offset: 0.1, value: 1)])
        XCTAssertFalse(success)
        XCTAssertTrue(clock.writes.isEmpty)
    }

    func testSupersededDuringWriteDoesNotStartNextWrite() async {
        let clock = Clock()
        clock.invalidateOnWrite = true
        let success = await clock.run([.init(offset: 0, value: 1), .init(offset: 0.2, value: 2)])
        XCTAssertFalse(success)
        XCTAssertEqual(clock.writes.map(\.value), [1])
    }

    func testCancelledDuringWaitDoesNotWrite() async {
        let clock = Clock()
        clock.cancelOnWait = true
        let task = Task { await clock.run([.init(offset: 0.1, value: 1)]) }
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertTrue(clock.writes.isEmpty)
    }

    func testFailedWriteStopsTransition() async {
        let clock = Clock()
        clock.failWrite = true
        let success = await clock.run([.init(offset: 0, value: 1), .init(offset: 0.2, value: 2)])
        XCTAssertFalse(success)
        XCTAssertEqual(clock.writes.map(\.value), [1])
    }

    func testEmptyPlanSucceedsOnlyWhileCurrent() async {
        let clock = Clock()
        let activeResult = await clock.run([])
        XCTAssertTrue(activeResult)
        clock.current = false
        let staleResult = await clock.run([])
        XCTAssertFalse(staleResult)
        XCTAssertTrue(clock.writes.isEmpty)
    }
}
