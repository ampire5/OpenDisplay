import AppKit
import TopologyCore
@main struct Checks {
    @MainActor static func main() {
        var changes = 0
        let tap = MediaKeyTap { _, _ in changes += 1; return true }
        precondition(tap.dispatch(.brightnessUp, fineStep: false, isDown: true))
        precondition(tap.dispatch(.brightnessUp, fineStep: false, isDown: false),
                     "Handled key-up must not escape to macOS")
        precondition(changes == 1, "Key-up must not change brightness twice")
        let passthrough = MediaKeyTap { _, _ in false }
        precondition(!passthrough.dispatch(.brightnessUp, fineStep: false, isDown: true))
        precondition(!passthrough.dispatch(.brightnessUp, fineStep: false, isDown: false))
        func raw(_ code: CGKeyCode, down: Bool, stamp: UInt64 = 10_000_000_000,
                 flags: CGEventFlags = []) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            event.flags = flags; event.timestamp = stamp
            return event
        }
        func nx(stamp: UInt64) -> CGEvent {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (2 << 16) | (0x0A << 8), data2: -1)!.cgEvent!
            event.timestamp = stamp
            return event
        }
        // External keyboards can send F14/F15 for the media functions printed on F1/F2.
        // These function-key events carry secondaryFn even when no physical Fn key is held.
        for (code, action): (CGKeyCode, MediaKeyAction) in [(107, .brightnessDown), (113, .brightnessUp)] {
            let flags = CGEventFlags(rawValue: 8_388_864)
            let event = raw(code, down: true, flags: flags)
            precondition(MediaKeyTap.input(type: .keyDown, event: event)?.action == action,
                         "Alternate media brightness codes must decode with the hardware function flag")
            var delivered: [MediaKeyAction] = []
            let alternate = MediaKeyTap { action, _ in delivered.append(action); return true }
            precondition(alternate.consume(type: .keyDown, event: event))
            precondition(alternate.consume(type: .keyUp, event: raw(code, down: false, flags: flags)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.07))
            precondition(delivered == [action], "Alternate brightness press/release must adjust exactly once")
            for modifier: CGEventFlags in [.maskCommand, .maskControl] {
                precondition(!alternate.consume(type: .keyDown, event: raw(code, down: true, flags: [flags, modifier])),
                             "Modified function-key shortcuts must remain available to other apps")
            }
        }
        for code: CGKeyCode in [122, 120, 144, 145] {
            var count = 0
            let plain = MediaKeyTap { _, _ in count += 1; return true }
            precondition(plain.consume(type: .keyDown, event: raw(code, down: true)))
            precondition(plain.consume(type: .keyUp, event: raw(code, down: false)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.07))
            precondition(count == 1, "F1/F2 and brightness keycodes must adjust exactly once")
        }
        for rawCode: CGKeyCode in [144, 113] {
            for rawFirst in [true, false] {
                var count = 0
                let paired = MediaKeyTap { _, _ in count += 1; return true }
                let systemType = CGEventType(rawValue: 14)!
                if rawFirst {
                    _ = paired.consume(type: .keyDown, event: raw(rawCode, down: true, flags: .maskSecondaryFn))
                    _ = paired.consume(type: systemType, event: nx(stamp: 10_001_000_000))
                } else {
                    _ = paired.consume(type: systemType, event: nx(stamp: 10_000_000_000))
                    _ = paired.consume(type: .keyDown, event: raw(rawCode, down: true, stamp: 10_001_000_000, flags: .maskSecondaryFn))
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.07))
                precondition(count == 1, "A keyboard emitting both event encodings must not adjust twice")
            }
        }
        var lateTwinChanges = 0
        let lateTwin = MediaKeyTap { _, _ in lateTwinChanges += 1; return true }
        _ = lateTwin.consume(type: .keyDown, event: raw(144, down: true))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(lateTwinChanges == 1)
        _ = lateTwin.consume(type: CGEventType(rawValue: 14)!, event: nx(stamp: 10_050_000_000))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(lateTwinChanges == 1, "NX arriving after the raw fallback must not double the step")
        for _ in 0..<4 {
            var repeatChanges = 0
            let repeats = MediaKeyTap { _, _ in repeatChanges += 1; return true }
            _ = repeats.consume(type: .keyDown, event: raw(144, down: true))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            _ = repeats.consume(type: .keyDown, event: raw(144, down: true, stamp: 10_050_000_000))
            _ = repeats.consume(type: CGEventType(rawValue: 14)!, event: nx(stamp: 10_050_000_000))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            _ = repeats.consume(type: CGEventType(rawValue: 14)!, event: nx(stamp: 10_100_000_000))
            precondition(repeatChanges == 2, "Overlapping repeat twins pair oldest-first, once per press")
        }
        precondition(!tap.consume(type: .keyDown, event: raw(122, down: true, flags: .maskSecondaryFn)))
        precondition(!tap.consume(type: .keyDown, event: raw(122, down: true, flags: .maskCommand)))
        precondition(!tap.consume(type: .keyDown, event: raw(99, down: true)))
        var lateChanges = 0
        let stopped = MediaKeyTap { _, _ in lateChanges += 1; return true }
        _ = stopped.consume(type: .keyDown, event: raw(144, down: true))
        stopped.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.07))
        precondition(lateChanges == 0, "Stopping capture cancels deferred key changes")
        print("PASS: handled press is consumed end-to-end; unsupported keys pass through")
    }
}
