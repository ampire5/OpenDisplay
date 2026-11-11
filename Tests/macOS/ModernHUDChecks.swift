import AppKit
import SwiftUI
import DisplayDomain
import TopologyCore
@main struct Checks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let hud = OSDHUDController()
        var checkedStacking = false
        for value: Float in [0.58, 0.05, 1, 0] {
            hud.present(OSDContent(kind: .brightness, value: value), cgDisplayID: CGMainDisplayID(),
                        style: .modern, position: .topCenter, displayName: "External Display")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) else {
                preconditionFailure("Modern app HUD must appear")
            }
            if !checkedStacking {
                // Reproduce an already-visible overlay occupying the HUD's position.
                let existing = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
                existing.level = .statusBar
                existing.orderFrontRegardless()
                hud.present(OSDContent(kind: .brightness, value: value), cgDisplayID: CGMainDisplayID(),
                            style: .modern, position: .topCenter, displayName: "External Display")
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
                let orderedIDs = windows?.compactMap { $0[kCGWindowNumber as String] as? Int } ?? []
                guard let hudIndex = orderedIDs.firstIndex(of: panel.windowNumber),
                      let existingIndex = orderedIDs.firstIndex(of: existing.windowNumber) else {
                    preconditionFailure("Both test panels must be visible in WindowServer")
                }
                precondition(hudIndex < existingIndex, "Modern HUD must appear above an existing overlay")
                existing.orderOut(nil)
                checkedStacking = true
            }
            func findHosting(_ view: NSView) -> NSHostingView<OSDHUDView>? {
                (view as? NSHostingView<OSDHUDView>) ?? view.subviews.compactMap { findHosting($0) }.first
            }
            precondition(panel.contentView.flatMap({ findHosting($0) })?.rootView.displayName == "External Display",
                         "The HUD must retain the selected display name")
            var materialLayer: CALayer?
            if #available(macOS 26, *) {
                func findGlass(_ view: NSView) -> NSGlassEffectView? {
                    (view as? NSGlassEffectView) ?? view.subviews.compactMap { findGlass($0) }.first
                }
                guard let glass = panel.contentView.flatMap({ findGlass($0) }) else {
                    preconditionFailure("Modern HUD must use native glass")
                }
                materialLayer = glass.layer
                precondition(materialLayer != nil, "Glass must have a live material layer")
                precondition(glass.style == .clear)
                precondition(glass.tintColor == nil, "Modern glass must not apply a dark tint")
            }
            // Inspect the renderer after it has materialized, rather than trusting the public style flag.
            func nativeValue(_ key: String, in layer: CALayer) -> Double? {
                for case let filter as NSObject in layer.filters ?? [] {
                    let selector = NSSelectorFromString("inputKeys")
                    guard filter.responds(to: selector),
                          let keys = filter.perform(selector)?.takeUnretainedValue() as? [String],
                          keys.contains("inputInnerRefractionAmount"), keys.contains(key) else { continue }
                    return (filter.value(forKey: key) as? NSNumber)?.doubleValue
                }
                return layer.sublayers?.compactMap { nativeValue(key, in: $0) }.first
            }
            if let layer = materialLayer, let blur = nativeValue("inputBlurRadius", in: layer) {
                precondition(blur <= 3, "Modern glass must preserve backdrop detail so its optical distortion is visible")
                if let fill = nativeValue("inputBlurFillNormalOpacity", in: layer) {
                    precondition(fill <= 0.001, "A second translucent fill must not mask the clear glass")
                }
                if let white = nativeValue("inputFaceColorMatrixWhite", in: layer),
                   let black = nativeValue("inputFaceColorMatrixBlack", in: layer) {
                    precondition(white >= 0.7 && white <= 1 && black >= 0 && black <= 0.25,
                                 "Glass must retain backdrop contrast without a smoked face")
                }
            }
            precondition(panel.frame.width == 308 && panel.frame.height == 66)
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }!
            precondition(abs(panel.frame.maxX - (screen.visibleFrame.maxX - 16)) < 1,
                         "Modern HUD belongs at the selected screen's top-right")
            precondition(abs(panel.frame.maxY - (screen.visibleFrame.maxY - 8)) < 1)
            hud.hide(animated: false)
            precondition(!panel.isVisible, "Hidden HUD must leave the window server, not stay parked at 1% alpha")
        }
        print("PASS: Modern HUD preserves optical detail across repeated presentations and fully hides")
    }
}
