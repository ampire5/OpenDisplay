import Foundation

/// Plans quantized brightness writes at absolute offsets from the transition's start.
public enum BrightnessTransition {
    public struct Step: Equatable, Sendable {
        public let offset: TimeInterval
        public let value: Int

        public init(offset: TimeInterval, value: Int) {
            self.offset = offset
            self.value = value
        }
    }

    public static func duration(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 1 }
        return min(5, max(0, seconds))
    }

    public static func steps(from: Int, to: Int, seconds: TimeInterval, maximum: Int) -> [Step] {
        guard maximum > 0 else { return [] }
        let start = min(maximum, max(0, from))
        let target = min(maximum, max(0, to))
        guard start != target else { return [] }
        let duration = duration(seconds)
        guard duration >= 0.1 else { return [Step(offset: duration, value: target)] }

        // Distribute intervals across the full duration so a fractional remainder
        // never puts the final write less than 100 ms after the preceding write.
        let intervals = max(1, Int((duration * 10).rounded(.down)))
        var result: [Step] = []
        var previous = start
        for index in 1..<intervals {
            let progress = Double(index) / Double(intervals)
            let eased = progress * progress * (3 - 2 * progress)
            let interpolated = (Double(start) + (Double(target) - Double(start)) * eased).rounded()
            let quantized: Int
            if interpolated >= Double(maximum) {
                quantized = maximum
            } else if interpolated <= 0 {
                quantized = 0
            } else {
                quantized = Int(interpolated)
            }
            let value = min(max(start, target), max(min(start, target), quantized))
            // Keep the exact target for the deadline, even when quantization would
            // otherwise reach it early and then emit the same hardware value again.
            guard value != previous, value != target else { continue }
            result.append(Step(offset: duration * progress, value: value))
            previous = value
        }
        result.append(Step(offset: duration, value: target))
        return result
    }

    /// Executes against one clock origin, dropping samples overtaken by a slow bus.
    @MainActor
    public static func run(
        steps: [Step],
        isCurrent: @MainActor () -> Bool,
        now: @MainActor () -> TimeInterval,
        wait: @MainActor (TimeInterval) async throws -> Void,
        write: @MainActor (Int) async -> Bool
    ) async -> Bool {
        func active() -> Bool { !Task.isCancelled && isCurrent() }
        guard active() else { return false }
        let started = now()
        var lastCompletion: TimeInterval?
        var index = 0
        while index < steps.count {
            guard active() else { return false }
            var deadline = started + steps[index].offset
            if let lastCompletion { deadline = max(deadline, lastCompletion + 0.1) }
            let delay = deadline - now()
            if delay > 0 {
                guard active() else { return false }
                do { try await wait(delay) } catch { return false }
                guard active() else { return false }
                continue
            }
            let currentTime = now()
            while index + 1 < steps.count, started + steps[index + 1].offset <= currentTime {
                index += 1
            }
            guard active() else { return false }
            let succeeded = await write(steps[index].value)
            guard active(), succeeded else { return false }
            // A write can wait for the shared bus before reaching hardware.
            // Pause after completion so that wait cannot compress physical writes.
            lastCompletion = now()
            index += 1
        }
        return active()
    }
}
