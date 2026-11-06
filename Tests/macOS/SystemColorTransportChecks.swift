import Foundation

// Compiled with SystemColorControls.swift and NightShiftStatus.swift. The transport
// records requests without loading CoreBrightness or changing global settings.
private final class RecordingTransport: SystemColorControlsTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var cancellation = false
    private var support = true
    private var acceptance = true
    var cancelAfterWrite: Bool {
        get { lock.withLock { cancellation } }
        set { lock.withLock { cancellation = newValue } }
    }
    var supported: Bool {
        get { lock.withLock { support } }
        set { lock.withLock { support = newValue } }
    }
    var acceptsWrite: Bool {
        get { lock.withLock { acceptance } }
        set { lock.withLock { acceptance = newValue } }
    }
    func events() -> [String] { lock.withLock { requests } }
    private func record(_ event: String) { lock.withLock { requests.append(event) } }
    func isSupported(_ channel: SystemColorChannel) -> Bool? {
        record("support:\(channel)")
        return supported
    }
    func isEnabled(_ channel: SystemColorChannel) -> Bool? {
        record("read:\(channel)")
        return true
    }
    func setEnabled(_ enabled: Bool, for channel: SystemColorChannel) -> Bool {
        record("write:\(channel):\(enabled)")
        if cancelAfterWrite { withUnsafeCurrentTask { $0?.cancel() } }
        return acceptsWrite
    }
}

@main struct SystemColorTransportChecks {
    static func main() async {
        let selective = RecordingTransport()
        let controls = SystemColorControls(transport: selective)
        let empty = await controls.snapshot(nightShift: false, trueTone: false)
        precondition(empty.nightShift == nil && empty.trueTone == nil && selective.events().isEmpty)
        let night = await controls.snapshot(nightShift: true, trueTone: false)
        precondition(night.nightShift == true && night.trueTone == nil)
        precondition(selective.events() == ["support:nightShift", "read:nightShift"])

        let selectiveTone = RecordingTransport()
        let selectiveToneControls = SystemColorControls(transport: selectiveTone)
        let toneOnly = await selectiveToneControls.snapshot(nightShift: false, trueTone: true)
        precondition(toneOnly.nightShift == nil && toneOnly.trueTone == true)
        precondition(selectiveTone.events() == ["support:trueTone", "read:trueTone"])
        selectiveTone.supported = false
        let changedSupport = await selectiveToneControls.snapshot(nightShift: false, trueTone: true)
        precondition(changedSupport.trueTone == nil)
        precondition(selectiveTone.events() == ["support:trueTone", "read:trueTone", "support:trueTone"])

        let toneTransport = RecordingTransport()
        let toneControls = SystemColorControls(transport: toneTransport)
        let tone = await toneControls.verifiedSetTrueTone(true)
        precondition(tone.succeeded && tone.state.trueTone == true && tone.state.nightShift == nil)
        precondition(toneTransport.events() == ["support:trueTone", "write:trueTone:true", "read:trueTone"])

        let nightTransport = RecordingTransport()
        let nightControls = SystemColorControls(transport: nightTransport)
        let writtenNight = await nightControls.verifiedSetNightShift(true)
        precondition(writtenNight.succeeded && writtenNight.state.nightShift == true && writtenNight.state.trueTone == nil)
        precondition(nightTransport.events() == ["support:nightShift", "write:nightShift:true", "read:nightShift"])

        let unsupported = RecordingTransport()
        unsupported.supported = false
        let unavailable = await SystemColorControls(transport: unsupported).verifiedSetTrueTone(true)
        precondition(!unavailable.succeeded && unavailable.state.trueTone == nil)
        precondition(unsupported.events() == ["support:trueTone"])

        let rejected = RecordingTransport()
        rejected.acceptsWrite = false
        let rejectedResult = await SystemColorControls(transport: rejected).verifiedSetTrueTone(true)
        precondition(!rejectedResult.succeeded && rejectedResult.state.trueTone == nil)
        precondition(rejected.events() == ["support:trueTone", "write:trueTone:true"])

        let mismatch = RecordingTransport()
        let mismatchResult = await SystemColorControls(transport: mismatch).verifiedSetTrueTone(false)
        precondition(!mismatchResult.succeeded && mismatchResult.state.trueTone == true)

        let cancelled = RecordingTransport()
        let cancelledControls = SystemColorControls(transport: cancelled)
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cancelledControls.verifiedSetTrueTone(true)
        }.value
        precondition(!result.succeeded && cancelled.events().isEmpty)

        let cancelledDelay = RecordingTransport()
        cancelledDelay.cancelAfterWrite = true
        let delayControls = SystemColorControls(transport: cancelledDelay)
        let delayed = await Task { await delayControls.verifiedSetNightShift(true) }.value
        precondition(!delayed.succeeded && delayed.state.nightShift == nil)
        precondition(cancelledDelay.events() == ["support:nightShift", "write:nightShift:true"])
        print("PASS: selective reads, target-only verification, and cancellation")
    }
}
