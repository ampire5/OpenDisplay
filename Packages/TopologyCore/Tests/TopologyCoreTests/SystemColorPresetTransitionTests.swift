import XCTest
@testable import TopologyCore

@MainActor
final class SystemColorPresetTransitionTests: XCTestCase {
    typealias State = SystemColorPresetPolicy.State

    @MainActor private final class Pause {
        private var suspended: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation {
                suspended = $0
                started?.resume(); started = nil
            }
        }
        func waitUntilSuspended() async {
            if suspended != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func resume() { suspended?.resume(); suspended = nil }
    }

    @MainActor private final class Workflow {
        var current = true
        var observed = State(nightShift: true, trueTone: true)
        var verified = State(nightShift: false, trueTone: false)
        var checkpointSucceeds = true
        var masks: [State] = []
        var checkpoints: [State] = []
        var writes: [State] = []
        var pauseObserve: Pause?
        var pauseCheckpoint: Pause?
        var pauseNight: Pause?

        func run(request: State, owed: State = .init()) async {
            await SystemColorPresetTransition.reconcile(request: request, owed: owed,
                isCurrent: { self.current },
                observe: { night, tone in
                    self.masks.append(State(nightShift: night, trueTone: tone))
                    await self.pauseObserve?.wait()
                    return self.observed
                },
                checkpoint: { state in
                    self.checkpoints.append(state)
                    await self.pauseCheckpoint?.wait()
                    return self.checkpointSucceeds
                },
                apply: { channel, enabled in
                    switch channel {
                    case .nightShift:
                        self.writes.append(State(nightShift: enabled))
                        await self.pauseNight?.wait()
                        return self.verified.nightShift
                    case .trueTone:
                        self.writes.append(State(trueTone: enabled))
                        return self.verified.trueTone
                    }
                })
        }
    }

    func testEmptyRequestWithoutDebtDoesNoIO() async {
        let workflow = Workflow()
        await workflow.run(request: .init())
        XCTAssertTrue(workflow.masks.isEmpty)
        XCTAssertTrue(workflow.checkpoints.isEmpty)
        XCTAssertTrue(workflow.writes.isEmpty)
    }

    func testOnlyRequestedAndOwedChannelsAreObserved() async {
        let workflow = Workflow()
        await workflow.run(request: .init(nightShift: false))
        XCTAssertEqual(workflow.masks, [.init(nightShift: true, trueTone: false)])
        XCTAssertEqual(workflow.checkpoints, [.init(nightShift: true)])
        XCTAssertEqual(workflow.writes, [.init(nightShift: false)])
    }

    func testTwoWritesUseOneObservationAndCaptureBeforeWriting() async {
        let workflow = Workflow()
        let pause = Pause()
        workflow.pauseCheckpoint = pause
        let task = Task { await workflow.run(request: .init(nightShift: false, trueTone: false)) }
        await pause.waitUntilSuspended()
        XCTAssertEqual(workflow.checkpoints, [.init(nightShift: true, trueTone: true)])
        XCTAssertTrue(workflow.writes.isEmpty)
        pause.resume()
        await task.value
        XCTAssertEqual(workflow.masks.count, 1)
        XCTAssertEqual(workflow.writes, [.init(nightShift: false), .init(trueTone: false)])
    }

    func testSupersededWhileObservingDoesNotCaptureOrWrite() async {
        let workflow = Workflow()
        let pause = Pause()
        workflow.pauseObserve = pause
        let task = Task { await workflow.run(request: .init(nightShift: false)) }
        await pause.waitUntilSuspended()
        workflow.current = false
        pause.resume()
        await task.value
        XCTAssertTrue(workflow.checkpoints.isEmpty)
        XCTAssertTrue(workflow.writes.isEmpty)
    }

    func testSupersededWhileCheckpointingRetainsCaptureWithoutWriting() async {
        let workflow = Workflow()
        let pause = Pause()
        workflow.pauseCheckpoint = pause
        let task = Task { await workflow.run(request: .init(nightShift: false)) }
        await pause.waitUntilSuspended()
        workflow.current = false
        pause.resume()
        await task.value
        XCTAssertEqual(workflow.checkpoints, [.init(nightShift: true)])
        XCTAssertTrue(workflow.writes.isEmpty)
    }

    func testSupersededAfterNightShiftDoesNotStartTrueTone() async {
        let workflow = Workflow()
        let pause = Pause()
        workflow.pauseNight = pause
        let task = Task { await workflow.run(request: .init(nightShift: false, trueTone: false)) }
        await pause.waitUntilSuspended()
        workflow.current = false
        pause.resume()
        await task.value
        XCTAssertEqual(workflow.writes, [.init(nightShift: false)])
        XCTAssertEqual(workflow.checkpoints, [.init(nightShift: true, trueTone: true)])
    }

    func testCancellationAfterObserveDoesNotCheckpointOrWrite() async {
        let workflow = Workflow()
        let pause = Pause()
        workflow.pauseObserve = pause
        let task = Task { await workflow.run(request: .init(nightShift: false)) }
        await pause.waitUntilSuspended()
        task.cancel()
        pause.resume()
        await task.value
        XCTAssertTrue(workflow.checkpoints.isEmpty)
        XCTAssertTrue(workflow.writes.isEmpty)
    }

    func testFailedCaptureCheckpointPreventsBothWrites() async {
        let workflow = Workflow()
        workflow.checkpointSucceeds = false
        await workflow.run(request: .init(nightShift: false, trueTone: false))
        XCTAssertEqual(workflow.checkpoints, [.init(nightShift: true, trueTone: true)])
        XCTAssertTrue(workflow.writes.isEmpty)
    }

    func testPartialVerifiedRestoreClearsOnlySuccessfulDebt() async {
        let workflow = Workflow()
        workflow.observed = .init(nightShift: false, trueTone: false)
        workflow.verified = .init(nightShift: true)
        await workflow.run(request: .init(), owed: .init(nightShift: true, trueTone: true))
        XCTAssertEqual(workflow.masks, [.init(nightShift: true, trueTone: true)])
        XCTAssertEqual(workflow.writes, [.init(nightShift: true), .init(trueTone: true)])
        XCTAssertEqual(workflow.checkpoints, [.init(trueTone: true)])
    }

    func testUnavailableChannelRetainsDebtWhileAlreadyRestoredChannelClears() async {
        let workflow = Workflow()
        workflow.observed = .init(nightShift: true)
        await workflow.run(request: .init(), owed: .init(nightShift: true, trueTone: true))
        XCTAssertTrue(workflow.writes.isEmpty)
        XCTAssertEqual(workflow.checkpoints, [.init(trueTone: true)])
    }
}
