/// Coordinates system-wide preset changes while preserving the baseline needed for restoration.
/// The caller owns observation caches and durable checkpoints; this workflow owns their ordering.
@MainActor
public enum SystemColorPresetTransition {
    public enum Channel: Sendable { case nightShift, trueTone }
    public typealias State = SystemColorPresetPolicy.State

    public static func reconcile(
        request: State,
        owed: State,
        isCurrent: @MainActor () -> Bool,
        observe: @MainActor (Bool, Bool) async -> State,
        checkpoint: @MainActor (State) async -> Bool,
        apply: @MainActor (Channel, Bool) async -> Bool?
    ) async {
        func active() -> Bool { !Task.isCancelled && isCurrent() }
        guard active(), !request.isEmpty || !owed.isEmpty else { return }
        var observed = await observe(request.nightShift != nil || owed.nightShift != nil,
                                     request.trueTone != nil || owed.trueTone != nil)
        guard active() else { return }
        let decision = SystemColorPresetPolicy.plan(request: request, observed: observed, owed: owed)
        if decision.baseline != owed {
            guard active() else { return }
            let saved = await checkpoint(decision.baseline)
            guard active(), saved else { return }
        }
        if let enabled = decision.writes.nightShift {
            guard active() else { return }
            let actual = await apply(.nightShift, enabled)
            guard active() else { return }
            observed.nightShift = actual
        }
        if let enabled = decision.writes.trueTone {
            guard active() else { return }
            let actual = await apply(.trueTone, enabled)
            guard active() else { return }
            observed.trueTone = actual
        }
        var remaining = decision.baseline
        if decision.restoringNightShift, let baseline = remaining.nightShift,
           observed.nightShift == baseline { remaining.nightShift = nil }
        if decision.restoringTrueTone, let baseline = remaining.trueTone,
           observed.trueTone == baseline { remaining.trueTone = nil }
        if remaining != decision.baseline {
            guard active() else { return }
            _ = await checkpoint(remaining)
            guard active() else { return }
        }
    }
}
