import Dispatch

/// Serializes settings snapshots off the main actor, including durability checkpoints.
/// Use one instance for every write to a given store so an older queued snapshot cannot
/// overwrite a newer checkpoint. The synchronous store remains responsible for atomic JSON writes.
public final class SettingsPersistence: Sendable {
    private let store: SettingsStore
    private let queue: DispatchQueue

    public init(store: SettingsStore) {
        self.store = store
        self.queue = DispatchQueue(label: "OpenDisplay.settings-persistence", qos: .utility)
    }

    /// Submits a value snapshot immediately, preserving the caller's submission order.
    public func enqueue(_ snapshot: OpenDisplaySettings) {
        queue.async { [store] in
            try? store.save(snapshot)
        }
    }

    /// Preserves capture-before-hardware ordering for legacy synchronous callers.
    /// Waits for earlier submissions and performs this save on the same utility queue.
    public func saveSynchronously(_ snapshot: OpenDisplaySettings) -> Bool {
        queue.sync { [store] in
            do {
                try store.save(snapshot)
                return true
            } catch {
                return false
            }
        }
    }

    /// Waits until this snapshot's atomic save finishes, after all earlier submissions.
    /// Main-actor isolation submits the checkpoint before the caller first suspends;
    /// only the serialization and file I/O run on the utility queue.
    @MainActor
    public func saveAndWait(_ snapshot: OpenDisplaySettings) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [store] in
                do {
                    try store.save(snapshot)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Waits for all writes submitted before this call, including checkpoints.
    @MainActor
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }
}
