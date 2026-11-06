#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import TopologyCore

/// Captures the hardware brightness/volume media keys and routes them to OpenDisplay (Batch-3 #3).
///
/// macOS delivers these as `systemDefined` (`NX_SYSDEFINED`) events, which a Carbon hotkey can't see —
/// so this uses a `CGEventTap`. An *active* tap (not listen-only) is required so OpenDisplay can
/// **consume** a handled key, suppressing the system's own HUD (we draw our own via `OSDHUDController`).
/// That capability needs the **Accessibility** permission; `start()` returns false when it isn't
/// granted, leaving the keys to behave normally. The decode→action mapping is the pure, unit-tested
/// `MediaKeyAction`; this is only the OS plumbing.
@MainActor
final class MediaKeyTap {
    /// Handle a key. Return `true` if OpenDisplay acted on it (the event is then swallowed), `false` to
    /// let it pass through to macOS (e.g. a volume key with no DDC-audio-capable target). Invoked on the
    /// main actor (the tap runs on the main run loop), so it can touch `AppModel`.
    private let handler: @MainActor (MediaKeyAction, _ fineStep: Bool) -> Bool

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var sessionProbe: CFMachPort?
    private var probeSource: CFRunLoopSource?
    private var handledPresses: Set<MediaKeyAction> = []
    private var rawPresses: Set<MediaKeyAction> = []
    private struct RawDown {
        var action: MediaKeyAction
        var timestamp: CGEventTimestamp
        var result: Bool?
    }
    private var rawDowns: [UUID: RawDown] = [:]
    private var systemDowns: [UUID: KeyInput] = [:]
    private var systemPresses: Set<MediaKeyAction> = []
    private var stopGeneration: UInt64 = 0

    init(handler: @escaping @MainActor (MediaKeyAction, _ fineStep: Bool) -> Bool) {
        self.handler = handler
    }

    /// Whether the process currently holds the Accessibility (TCC) grant the tap needs.
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Show the system Accessibility prompt (the one-time grant request). Called only when the user
    /// turns the feature on, so a user who never enables it is never prompted.
    static func promptForAccessibility() {
        // Use the documented constant's literal value rather than the imported global `var`
        // `kAXTrustedCheckOptionPrompt`, which Swift 6 flags as not concurrency-safe to reference.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Create + enable the tap. Returns false (a no-op) when Accessibility isn't granted or the tap
    /// can't be created — the keys then reach macOS unchanged.
    @discardableResult
    func start() -> Bool {
        if let eventTap {
            if !CGEvent.tapIsEnabled(tap: eventTap) { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return CGEvent.tapIsEnabled(tap: eventTap)
        }
        guard Self.isAccessibilityTrusted else { return false }

        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        func create(at location: CGEventTapLocation) -> CFMachPort? {
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: mask, callback: mediaKeyTapCallback, userInfo: refcon)
        }
        guard let tap = create(at: .cghidEventTap) ?? create(at: .cgSessionEventTap) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        if Self.tracing, let probe = CGEvent.tapCreate(tap: .cgSessionEventTap,
            place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(1 << 14),
            callback: mediaKeySessionProbe, userInfo: refcon) {
            sessionProbe = probe
            let probeRunLoop = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, probe, 0)
            probeSource = probeRunLoop
            CFRunLoopAddSource(CFRunLoopGetMain(), probeRunLoop, .commonModes)
        }
        return true
    }

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let sessionProbe { CGEvent.tapEnable(tap: sessionProbe, enable: false) }
        if let probeSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), probeSource, .commonModes) }
        sessionProbe = nil
        probeSource = nil
        eventTap = nil
        runLoopSource = nil
        handledPresses.removeAll()
        rawPresses.removeAll()
        rawDowns.removeAll()
        systemDowns.removeAll()
        systemPresses.removeAll()
        stopGeneration &+= 1
    }

    /// Re-arm the tap if the system disabled it (timeout / user input). Called from the C callback.
    func reEnableIfNeeded() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Dispatch a decoded media key to the handler; returns whether it was consumed.
    func dispatch(_ action: MediaKeyAction, fineStep: Bool, isDown: Bool = true) -> Bool {
        if !isDown { return handledPresses.remove(action) != nil }
        trace("dispatch-begin action=\(action)")
        let started = DispatchTime.now().uptimeNanoseconds
        let consumed = handler(action, fineStep)
        trace("dispatch-end action=\(action) consumed=\(consumed) "
              + "duration-ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)")
        if consumed { handledPresses.insert(action) } else { handledPresses.remove(action) }
        return consumed
    }

    nonisolated static let tracing = ProcessInfo.processInfo.environment["OPENDISPLAY_KEY_TRACE"] == "1"
    private var traceRemaining = 128
    private var lastTraceAt: UInt64 = 0

    func trace(_ line: @autoclosure () -> String) {
        guard Self.tracing else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // Retain the first events after each idle spell, even in a process running for days.
        // A held key still has a bounded budget; ordinary typing is never recorded.
        if lastTraceAt == 0 || now &- lastTraceAt > 30_000_000_000 { traceRemaining = 128 }
        lastTraceAt = now
        guard traceRemaining > 0 else { return }
        traceRemaining -= 1
        FileHandle.standardError.write(Data(("t=\(Date().timeIntervalSince1970) " + line() + "\n").utf8))
    }

    nonisolated static func traceDescription(type: CGEventType, event: CGEvent) -> String? {
        if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
            return "brightness-input system subtype=\(ns.subtype.rawValue) data1=\(ns.data1) flags=\(event.flags.rawValue)"
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard [107, 113, 120, 122, 144, 145].contains(code) else { return nil }
        return "brightness-input type=\(type.rawValue) keycode=\(code) flags=\(event.flags.rawValue)"
    }

    struct KeyInput: Sendable {
        var action: MediaKeyAction
        var fine: Bool
        var down: Bool
        var timestamp: CGEventTimestamp
        var isSystem: Bool
    }

    nonisolated static func input(type: CGEventType, event: CGEvent) -> KeyInput? {
        if type.rawValue == 14 {
            guard let key = decode(event) else { return nil }
            return KeyInput(action: key.action, fine: key.fineStep, down: key.isDown,
                            timestamp: event.timestamp, isSystem: true)
        }
        guard type == .keyDown || type == .keyUp else { return nil }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let action: MediaKeyAction
        switch code {
        // Third-party keyboards may encode their brightness legends as F14/F15.
        // secondaryFn is normal on these events and does not make them plain F1/F2.
        case 144, 113: action = .brightnessUp
        case 145, 107: action = .brightnessDown
        case 122, 120:
            guard type == .keyUp || !event.flags.contains(.maskSecondaryFn) else { return nil }
            action = code == 122 ? .brightnessDown : .brightnessUp
        default: return nil
        }
        guard type == .keyUp || (!event.flags.contains(.maskCommand) && !event.flags.contains(.maskControl)) else { return nil }
        return KeyInput(action: action,
            fine: event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate),
            down: type == .keyDown, timestamp: event.timestamp, isSystem: false)
    }

    func consume(type: CGEventType, event: CGEvent) -> Bool {
        guard let key = Self.input(type: type, event: event) else { return false }
        return consume(key)
    }

    /// Pair each plain and NX down at most once. Keep already-delivered plain downs briefly:
    /// a late NX twin must still be suppressed after the fallback timer has fired.
    func consume(_ key: KeyInput) -> Bool {
        let action = key.action
        func nearby(_ lhs: UInt64, _ rhs: UInt64) -> Bool {
            (lhs > rhs ? lhs - rhs : rhs - lhs) < 80_000_000
        }
        if key.isSystem {
            if !key.down {
                let consumed = systemPresses.remove(action) != nil
                _ = dispatch(action, fineStep: key.fine, isDown: false)
                return consumed
            }
            let pair = rawDowns.filter { $0.value.action == action && nearby($0.value.timestamp, key.timestamp) }
                .min { $0.value.timestamp < $1.value.timestamp }
            let consumed: Bool
            if let pair {
                rawDowns[pair.key] = nil
                consumed = pair.value.result ?? dispatch(action, fineStep: key.fine)
            } else {
                consumed = dispatch(action, fineStep: key.fine)
                let id = UUID()
                systemDowns[id] = key
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.systemDowns[id] = nil }
            }
            if consumed { systemPresses.insert(action) }
            return consumed
        }
        if !key.down {
            guard rawPresses.remove(action) != nil else { return false }
            let generation = stopGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self, self.stopGeneration == generation else { return }
                _ = self.dispatch(action, fineStep: key.fine, isDown: false)
            }
            return true
        }
        rawPresses.insert(action)
        if let pair = systemDowns.filter({ $0.value.action == action && nearby($0.value.timestamp, key.timestamp) })
            .min(by: { $0.value.timestamp < $1.value.timestamp }) {
            systemDowns[pair.key] = nil
            return true
        }
        let id = UUID()
        rawDowns[id] = RawDown(action: action, timestamp: key.timestamp)
        let generation = stopGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.stopGeneration == generation, var pending = self.rawDowns[id] else { return }
            self.trace("raw-fallback action=\(action) "
                       + "event-age-ms=\(Double(DispatchTime.now().uptimeNanoseconds &- key.timestamp) / 1_000_000)")
            pending.result = self.dispatch(action, fineStep: key.fine)
            self.rawDowns[id] = pending
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.rawDowns[id]?.result == nil, self?.rawDowns[id] != nil {
                self?.trace("raw-expired-before-dispatch action=\(action)")
            }
            self?.rawDowns[id] = nil
        }
        return true
    }

    /// Decode a systemDefined CGEvent into a media-key action (+ fine-step modifier), or nil if it isn't
    /// a media-key *press* we care about. `nonisolated` + pure of actor state — returns only Sendable
    /// values, so the C callback can do this outside the main-actor hop (CGEvent isn't Sendable).
    nonisolated static func decode(_ cgEvent: CGEvent) -> (action: MediaKeyAction, fineStep: Bool, isDown: Bool)? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent), nsEvent.subtype.rawValue == 8 else { return nil }
        let data1 = nsEvent.data1
        let keyCode = Int((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard let action = MediaKeyAction.from(nxKeyType: keyCode) else { return nil }
        let fineStep = nsEvent.modifierFlags.contains(.shift) && nsEvent.modifierFlags.contains(.option)
        return (action, fineStep, isKeyDown)
    }
}

/// Top-level C callback (must not capture) for the media-key event tap. Recovers the owning
/// `MediaKeyTap` from `refcon` and consumes the event when handled. The tap runs on the main run loop,
/// so it's safe to hop onto the main actor; only Sendable decoded values cross that hop (not the
/// non-Sendable `CGEvent`).
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            tap.trace("tap-disabled type=\(type.rawValue)")
            tap.reEnableIfNeeded()
            tap.trace("tap-rearmed enabled=\(tap.isRunning)")
        }
        return Unmanaged.passUnretained(event)
    }

    let began = DispatchTime.now().uptimeNanoseconds
    let input = MediaKeyTap.input(type: type, event: event)
    if MediaKeyTap.tracing, let input {
        MainActor.assumeIsolated {
            tap.trace("capture-begin action=\(input.action) down=\(input.down) "
                      + "event-age-ms=\(Double(began &- input.timestamp) / 1_000_000)")
        }
    }
    let consumed = input.map { key in MainActor.assumeIsolated { tap.consume(key) } } ?? false
    if MediaKeyTap.tracing, let line = MediaKeyTap.traceDescription(type: type, event: event) {
        let decision = input.map { "action=\($0.action) down=\($0.down)" } ?? "action=none"
        MainActor.assumeIsolated {
            tap.trace("\(line) \(decision) consumed=\(consumed) "
                      + "callback-ms=\(Double(DispatchTime.now().uptimeNanoseconds &- began) / 1_000_000)")
        }
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}
private func mediaKeySessionProbe(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon, let line = MediaKeyTap.traceDescription(type: type, event: event) {
        let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { tap.trace("session-probe " + line) }
    }
    return Unmanaged.passUnretained(event)
}
#endif
