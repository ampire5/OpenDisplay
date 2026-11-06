/// Hardware readings that remain proof only until the next write to their control.
///
/// Capture a control's generation before starting a read, then pass it back when
/// confirming the result. Invalidate at both write scheduling and completion so
/// reads overlapping either boundary cannot restore stale proof.
public struct DDCReadConfirmation<Key: Hashable & Sendable>: Sendable {
    public struct Reading: Equatable, Sendable {
        public let current: Int
        public let maximum: Int
    }

    private struct Confirmation: Sendable {
        let generation: UInt64
        let reading: Reading
    }

    private var generations: [Key: UInt64] = [:]
    private var confirmations: [Key: Confirmation] = [:]

    public init() {}

    public func generation(for key: Key) -> UInt64 {
        generations[key, default: 0]
    }

    @discardableResult
    public mutating func confirm(
        current: Int,
        maximum: Int,
        for key: Key,
        ifGeneration expectedGeneration: UInt64
    ) -> Bool {
        guard current >= 0, maximum > 0,
              generation(for: key) == expectedGeneration else { return false }
        confirmations[key] = Confirmation(
            generation: expectedGeneration,
            reading: Reading(current: current, maximum: maximum)
        )
        return true
    }

    public func reading(for key: Key) -> Reading? {
        guard let confirmation = confirmations[key],
              confirmation.generation == generation(for: key) else { return nil }
        return confirmation.reading
    }

    public mutating func invalidate(_ key: Key) {
        generations[key] = generation(for: key) + 1
        confirmations.removeValue(forKey: key)
    }

    /// Drop cached readings without allowing an invalidated in-flight read to
    /// become current again by resetting its generation.
    public mutating func clearConfirmations() {
        confirmations.removeAll()
    }
}
