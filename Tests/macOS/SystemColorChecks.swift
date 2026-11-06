import AppKit
import ExperimentalLifecycleProvider

/// Read-only by default. --exercise briefly toggles supported modes and restores both before
/// asserting, so the test does not leave a user's global colour settings changed on failure.
@main struct Checks {
    @MainActor static func main() async {
        _ = NSApplication.shared
        _ = CGMainDisplayID()
        let controls = SystemColorControls()
        let before = await controls.snapshot()
        print("Night Shift supported: \(before.nightShift != nil); True Tone supported: \(before.trueTone != nil)")
        guard CommandLine.arguments.contains("--exercise") else { return }
        var checks: [Bool] = []
        if let original = before.nightShift {
            let off = await controls.setNightShift(!original)
            checks.append(off)
            FileHandle.standardError.write(Data("NightShift change=\(off), observed=\(String(describing: await controls.snapshot().nightShift))\n".utf8))
            let restored = await controls.setNightShift(original)
            checks.append(restored)
            FileHandle.standardError.write(Data("NightShift restore=\(restored)\n".utf8))
        }
        if let original = before.trueTone {
            let off = await controls.setTrueTone(!original)
            checks.append(off)
            FileHandle.standardError.write(Data("TrueTone change=\(off), observed=\(String(describing: await controls.snapshot().trueTone))\n".utf8))
            let restored = await controls.setTrueTone(original)
            checks.append(restored)
            FileHandle.standardError.write(Data("TrueTone restore=\(restored)\n".utf8))
        }
        let after = await controls.snapshot()
        precondition(after.nightShift == before.nightShift && after.trueTone == before.trueTone,
                     "Original system modes must be restored")
        precondition(checks.allSatisfy { $0 }, "Every mode change must be verified by readback")
        print("PASS: supported system modes changed and restored")
    }
}
