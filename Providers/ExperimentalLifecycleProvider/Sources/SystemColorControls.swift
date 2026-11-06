#if os(macOS)
import Foundation
import ObjectiveC

internal enum SystemColorChannel {
    case nightShift, trueTone
}

/// The actor owns this synchronous transport; none of its clients escape actor isolation.
internal protocol SystemColorControlsTransport {
    func isSupported(_ channel: SystemColorChannel) -> Bool?
    func isEnabled(_ channel: SystemColorChannel) -> Bool?
    func setEnabled(_ enabled: Bool, for channel: SystemColorChannel) -> Bool
}

/// Serializes the optional CoreBrightness clients and keeps their XPC connections alive. No polling.
public actor SystemColorControls {
    public struct State: Sendable {
        public var nightShift: Bool?
        public var trueTone: Bool?
    }
    public struct WriteResult: Sendable {
        /// Only the requested channel is populated; nil means no observation was available.
        public let state: State
        public let succeeded: Bool
    }
    private let transport: any SystemColorControlsTransport
    public init() { transport = CoreBrightnessColorTransport() }
    internal init(transport: sending any SystemColorControlsTransport) { self.transport = transport }

    /// Unrequested channels perform no support or state reads and remain nil in the result.
    public func snapshot(nightShift: Bool = true, trueTone: Bool = true) -> State {
        State(nightShift: nightShift ? observed(.nightShift) : nil,
              trueTone: trueTone ? observed(.trueTone) : nil)
    }
    private func observed(_ channel: SystemColorChannel) -> Bool? {
        transport.isSupported(channel) == true ? transport.isEnabled(channel) : nil
    }
    @discardableResult
    public func setNightShift(_ enabled: Bool) async -> Bool {
        await verifiedSetNightShift(enabled).succeeded
    }
    @discardableResult
    public func setTrueTone(_ enabled: Bool) async -> Bool {
        await verifiedSetTrueTone(enabled).succeeded
    }
    public func verifiedSetNightShift(_ enabled: Bool) async -> WriteResult {
        await verifiedSet(enabled, channel: .nightShift)
    }
    public func verifiedSetTrueTone(_ enabled: Bool) async -> WriteResult {
        await verifiedSet(enabled, channel: .trueTone)
    }
    private func verifiedSet(_ enabled: Bool, channel: SystemColorChannel) async -> WriteResult {
        let unavailable = WriteResult(state: State(nightShift: nil, trueTone: nil), succeeded: false)
        guard !Task.isCancelled, transport.isSupported(channel) == true,
              !Task.isCancelled, transport.setEnabled(enabled, for: channel) else { return unavailable }
        if channel == .nightShift {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return unavailable }
        }
        guard !Task.isCancelled else { return unavailable }
        let observed = transport.isEnabled(channel)
        let state = State(nightShift: channel == .nightShift ? observed : nil,
                          trueTone: channel == .trueTone ? observed : nil)
        return WriteResult(state: state, succeeded: observed == enabled)
    }
}

private final class CoreBrightnessColorTransport: SystemColorControlsTransport {
    private lazy var night = Self.client("CBBlueLightClient")
    private lazy var tone = Self.client("CBTrueToneClient")
    private func client(for channel: SystemColorChannel) -> NSObject? {
        channel == .nightShift ? night : tone
    }
    private static func client(_ name: String) -> NSObject? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString(name) as? NSObject.Type else { return nil }
        return type.init()
    }
    private func get(_ client: NSObject?, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard let client, client.responds(to: selector), let imp = client.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(imp, to: Getter.self)(client, selector)
    }
    func isSupported(_ channel: SystemColorChannel) -> Bool? {
        get(client(for: channel), "supported")
    }
    func isEnabled(_ channel: SystemColorChannel) -> Bool? {
        channel == .nightShift ? NightShiftStatusReader().isActive() : get(tone, "enabled")
    }
    func setEnabled(_ enabled: Bool, for channel: SystemColorChannel) -> Bool {
        let selector = NSSelectorFromString("setEnabled:")
        guard let client = client(for: channel), client.responds(to: selector),
              let imp = client.method(for: selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Bool
        return unsafeBitCast(imp, to: Setter.self)(client, selector, enabled)
    }
}
#endif
