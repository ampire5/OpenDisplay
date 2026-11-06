import Foundation
import AutomationSchema

/// FaceLight raises brightness and adds a warm overlay. New activations never change contrast.
/// Persist the baseline before applying anything, and retain it until every owed channel is verified.
public enum FaceLightPolicy {
    public enum BrightnessRoute: String, Hashable, Sendable, Codable {
        case hardware, native, software
    }

    public struct PriorState: Hashable, Sendable, Codable {
        public var brightness: Float
        /// Only older activations owe contrast. Preserve this field for crash recovery.
        public var contrast: Float?
        /// Missing on legacy entries; the caller must resolve the route conservatively.
        public var brightnessRoute: BrightnessRoute?

        public init(brightness: Float, contrast: Float? = nil, brightnessRoute: BrightnessRoute? = nil) {
            self.brightness = brightness
            self.contrast = contrast
            self.brightnessRoute = brightnessRoute
        }
    }

    public struct ToggleResult: Hashable, Sendable {
        public var isNowActive: Bool
        public var brightnessWrite: Float?
        public var contrastWrite: Float?
        /// Restore requests retain the debt. Only `debtAfterRestore` can release it.
        public var priorStateToPersist: PriorState?

        public init(isNowActive: Bool, brightnessWrite: Float?, contrastWrite: Float?,
                    priorStateToPersist: PriorState?) {
            self.isNowActive = isNowActive
            self.brightnessWrite = brightnessWrite
            self.contrastWrite = contrastWrite
            self.priorStateToPersist = priorStateToPersist
        }
    }

    public static let overlayKelvin: Float = ColorTemperatureCurve.minKelvin
    /// A warm wash that keeps the call window visible.
    public static let overlayAlpha: Float = 0.5

    public static func toggle(owedPriorState: PriorState?, liveBrightness: Float,
                              liveContrast: Float?) -> ToggleResult {
        if let owedPriorState {
            return ToggleResult(isNowActive: false, brightnessWrite: owedPriorState.brightness,
                                contrastWrite: owedPriorState.contrast, priorStateToPersist: owedPriorState)
        }
        return ToggleResult(isNowActive: true, brightnessWrite: 1, contrastWrite: nil,
                            priorStateToPersist: PriorState(brightness: liveBrightness))
    }

    /// An old entry has no reliable software provenance. A transient DDC failure must not
    /// turn owed backlight restoration into a successful gamma write and erase its ledger.
    public static func restoreRoute(for prior: PriorState, isBuiltIn: Bool,
                                    currentRoute: BrightnessRoute?) -> BrightnessRoute {
        if let saved = prior.brightnessRoute { return saved }
        if prior.contrast != nil { return .hardware }
        if isBuiltIn || currentRoute == .native { return .native }
        return .hardware
    }

    /// No guessed maximum: an unreadable channel must leave its restore debt intact.
    public static func restoreTarget(level: Float, maximum: Int?) -> Int? {
        guard level.isFinite, (0...1).contains(level), let maximum, maximum > 0 else { return nil }
        return Int((level * Float(maximum)).rounded())
    }

    public static func hardwareWriteVerified(succeeded: Bool, target: Int, readback: Int?) -> Bool {
        guard succeeded, let readback, target >= 0, readback >= 0 else { return false }
        return DDCWriteVerification.outcome(target: target, readback: readback, tolerance: 1) == .applied
    }

    public static func debtAfterRestore(_ prior: PriorState, brightnessVerified: Bool,
                                         contrastVerified: Bool) -> PriorState? {
        brightnessVerified && (prior.contrast == nil || contrastVerified) ? nil : prior
    }
}

/// Main-actor callers enqueue before their first suspension. Each display retains its ordering,
/// including rapid on/off/on gestures, while unrelated displays can progress independently.
@MainActor
public final class FaceLightTransitionQueue<Key: Hashable & Sendable> {
    private var tasks: [Key: Task<Void, Never>] = [:]
    private var revisions: [Key: UUID] = [:]

    public init() {}
    public func contains(_ key: Key) -> Bool { tasks[key] != nil }
    public var keys: Set<Key> { Set(tasks.keys) }

    public func enqueue(for key: Key, operation: @escaping @MainActor () async -> Void) {
        let previous = tasks[key]
        let revision = UUID()
        revisions[key] = revision
        tasks[key] = Task {
            await previous?.value
            await operation()
            if revisions[key] == revision {
                tasks[key] = nil
                revisions[key] = nil
            }
        }
    }

    public func drain() async {
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            for task in pending { await task.value }
        }
    }
}
