#if os(macOS)
import AppKit
import QuartzCore

/// Optional calibration of the native material used by a small, noninteractive level indicator.
/// The renderer's parameter names are SPI: check its advertised inputs and leave stock glass
/// untouched when they are unavailable. This changes only the supplied view's material.
@MainActor
public enum HUDGlassOptics {
    private static let values: [String: Double] = [
        "inputBlurRadius": 2,
        "inputBlurFillNormalOpacity": 0,
        "inputFaceColorMatrixWhite": 0.86,
        "inputFaceColorMatrixBlack": 0.12,
        "inputInnerRefractionAmount": -20,
        "inputInnerRefractionHeight": 10
    ]
    private static let fillKey = "inputFaceColorMatrixFillColor"

    @discardableResult
    public static func configure(in view: NSView) -> Bool {
        guard let layer = view.layer else { return false }
        return configure(layer)
    }

    private static func configure(_ layer: CALayer) -> Bool {
        var applied = false
        for case let filter as NSObject in layer.filters ?? [] {
            let selector = NSSelectorFromString("inputKeys")
            guard String(describing: filter) == "glassBackground", filter.responds(to: selector),
                  let keys = filter.perform(selector)?.takeUnretainedValue() as? [String],
                  keys.contains(fillKey), values.keys.allSatisfy({ keys.contains($0) }) else { continue }
            // Set through the owning layer so Core Animation sends the updated filter to the renderer.
            for (key, value) in values {
                layer.setValue(NSNumber(value: value), forKeyPath: "filters.glassBackground." + key)
            }
            layer.setValue(NSColor.clear.cgColor, forKeyPath: "filters.glassBackground." + fillKey)
            applied = true
        }
        for child in layer.sublayers ?? [] {
            if configure(child) { applied = true }
        }
        return applied
    }
}
#endif
