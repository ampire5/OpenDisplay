import Foundation

/// Debounce starts when the desired app is observed, even while a previous transaction verifies.
public struct AppPresetRequestClock: Sendable {
    private var observed = false
    private var desiredBundleID: String?
    private var since: Date?
    public init() {}
    public mutating func observe(_ bundleID: String?, at date: Date) {
        if !observed || desiredBundleID != bundleID {
            observed = true
            desiredBundleID = bundleID
            since = date
        }
    }
    public func seed(_ state: AppPresetPolicy.ActivationState) -> AppPresetPolicy.ActivationState {
        guard observed, desiredBundleID != state.activeBundleID else { return state }
        var next = state
        next.pendingBundleID = desiredBundleID
        next.pendingSince = since
        return next
    }
}
