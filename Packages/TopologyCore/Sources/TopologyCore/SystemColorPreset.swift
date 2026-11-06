import Foundation

/// Night Shift and True Tone are system-wide, independent of a preset's display target.
/// A nil value means leave unchanged (or unavailable when it is an observation).
public enum SystemColorPresetPolicy {
    public struct State: Hashable, Sendable, Codable {
        public var nightShift: Bool?
        public var trueTone: Bool?
        public init(nightShift: Bool? = nil, trueTone: Bool? = nil) {
            self.nightShift = nightShift; self.trueTone = trueTone
        }
        public var isEmpty: Bool { nightShift == nil && trueTone == nil }
    }
    public struct Decision: Hashable, Sendable {
        public var baseline: State
        public var writes: State
        public var restoringNightShift: Bool
        public var restoringTrueTone: Bool
    }
    public static func plan(request: State, observed: State, owed: State) -> Decision {
        let night = channel(request: request.nightShift, observed: observed.nightShift, owed: owed.nightShift)
        let tone = channel(request: request.trueTone, observed: observed.trueTone, owed: owed.trueTone)
        return Decision(baseline: State(nightShift: night.baseline, trueTone: tone.baseline),
                        writes: State(nightShift: night.write, trueTone: tone.write),
                        restoringNightShift: night.restoring, restoringTrueTone: tone.restoring)
    }
    private static func channel(request: Bool?, observed: Bool?, owed: Bool?)
        -> (baseline: Bool?, write: Bool?, restoring: Bool) {
        guard let observed else { return (owed, nil, false) }
        if let request { return (owed ?? observed, observed == request ? nil : request, false) }
        guard let owed else { return (nil, nil, false) }
        return (owed, observed == owed ? nil : owed, true)
    }
}
