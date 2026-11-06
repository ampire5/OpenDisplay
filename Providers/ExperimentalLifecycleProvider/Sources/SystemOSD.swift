#if os(macOS)
import AppKit
import DisplayDomain
import ObjectiveC

/// Requests the system-owned HUD. No OpenDisplay window is created. Private SPI remains confined
/// to this optional provider and is resolved lazily so ordinary startup does not load OSD.framework.
@MainActor
public final class SystemOSDController {
    private static let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY) != nil,
              let cls = NSClassFromString("OSDManager") else { return nil }
        let selector = NSSelectorFromString("sharedManager")
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        typealias Shared = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(method_getImplementation(method), to: Shared.self)(cls, selector)?
            .takeUnretainedValue() as? NSObject
    }()
    private static let selector = NSSelectorFromString(
        "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")

    public init() {}
    public var isAvailable: Bool { Self.manager?.responds(to: Self.selector) == true }

    @discardableResult
    public func present(_ content: OSDContent, displayID: CGDirectDisplayID) -> Bool {
        guard content.kind != .input, let manager = Self.manager,
              manager.responds(to: Self.selector), let method = manager.method(for: Self.selector) else { return false }
        typealias Show = @convention(c) (AnyObject, Selector, Int, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
        let image: Int = content.kind == .brightness ? 1 : (content.kind == .mute || content.value == 0 ? 4 : 3)
        unsafeBitCast(method, to: Show.self)(manager, Self.selector, image, displayID, 0, 1200,
                                           UInt32(content.filledSegments), 16, false)
        return true
    }
}
#endif
