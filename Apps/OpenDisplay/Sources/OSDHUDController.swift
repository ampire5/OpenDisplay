#if os(macOS)
import AppKit
import CoreGraphics
import DisplayDomain
import SwiftUI
import TopologyCore
#if !PUBLIC_API_ONLY
import ExperimentalLifecycleProvider
#endif

/// The native-looking on-screen-display HUD (Batch-3 #4). A borderless, non-activating panel that
/// floats above everything, never takes focus, and is click-through — mirroring macOS's own
/// brightness/volume HUD. The *what to show* (`OSDContent`) is pure logic from DisplayDomain; this only
/// renders it and manages the show/auto-hide window. The pure `OSDPresentationPolicy` defines the
/// auto-hide duration so the timing stays consistent with the tested model.
@MainActor
final class OSDHUDController {
    private lazy var panel = makePanel()
    private lazy var hosting = NSHostingView(rootView: OSDHUDView(
        content: OSDContent(kind: .brightness, value: 0), style: .native))
    #if !PUBLIC_API_ONLY
    private lazy var systemOSD = SystemOSDController()
    #endif

    var nativeAvailable: Bool {
        #if PUBLIC_API_ONLY
        false
        #else
        systemOSD.isAvailable
        #endif
    }
    private var modernGlass: NSView?
    private var modernContainer: NSView?
    private var materialWorkItem: DispatchWorkItem?
    private var presentationRevision: UInt64 = 0
    private var hideWorkItem: DispatchWorkItem?
    private let autoHide = OSDPresentationPolicy().autoHide

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = hosting
        return panel
    }

    private func attachContent(for style: OSDStyle) {
        if #available(macOS 26, *), style == .modern {
            let glass: NSGlassEffectView
            if let existing = modernGlass as? NSGlassEffectView { glass = existing }
            else {
                glass = NSGlassEffectView()
                glass.style = .clear
                glass.cornerRadius = 33
                glass.tintColor = nil
                modernGlass = glass
            }
            let container: NSView
            if let existing = modernContainer { container = existing }
            else {
                container = NSView(frame: NSRect(x: 0, y: 0, width: 308, height: 66))
                glass.frame = container.bounds
                glass.autoresizingMask = [.width, .height]
                container.addSubview(glass)
                let rim = HUDLensRimView(frame: container.bounds)
                rim.autoresizingMask = [.width, .height]
                container.addSubview(rim)
                modernContainer = container
            }
            if panel.contentView !== container {
                glass.contentView = hosting
                panel.contentView = container
            }
        } else {
            if #available(macOS 26, *) { (modernGlass as? NSGlassEffectView)?.contentView = nil }
            if panel.contentView !== hosting { panel.contentView = hosting }
        }
    }

    #if !PUBLIC_API_ONLY
    private func updateModernMaterial(revision: UInt64, attempt: Int = 0) {
        guard revision == presentationRevision, panel.isVisible,
              hosting.rootView.style == .modern, let modernGlass else { return }
        modernGlass.layoutSubtreeIfNeeded()
        if HUDGlassOptics.configure(in: modernGlass) { return }
        // AppKit creates the material asynchronously. Retry briefly, never poll a hidden window.
        guard attempt < 3 else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.updateModernMaterial(revision: revision, attempt: attempt + 1)
        }
        materialWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
    }
    #endif

    /// Show (or refresh) the HUD for `content` on the screen matching `cgDisplayID` (falling back to the
    /// main screen). `external` style draws nothing — the event is broadcast for a notch app instead.
    func present(_ content: OSDContent, cgDisplayID: CGDirectDisplayID?, style: OSDStyle, position: OSDPosition) {
        if style == .native, content.kind != .input {
            #if !PUBLIC_API_ONLY
            systemOSD.present(content, displayID: cgDisplayID ?? CGMainDisplayID())
            #endif
            return
        }
        guard style != .external else { hide(animated: false); return }

        materialWorkItem?.cancel()
        presentationRevision &+= 1
        hosting.rootView = OSDHUDView(content: content, style: style,
                                     displayName: screen(for: cgDisplayID)?.localizedName)
        attachContent(for: style)
        panel.hasShadow = style != .modern
        let size = OSDHUDView.size(for: style)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        if let screen = screen(for: cgDisplayID) {
            if style == .modern {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 16,
                                             y: screen.visibleFrame.maxY - size.height - 8))
            } else {
                panel.setFrameOrigin(origin(for: position, size: size, in: screen.visibleFrame))
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        #if !PUBLIC_API_ONLY
        if style == .modern { updateModernMaterial(revision: presentationRevision) }
        #endif

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide(animated: true) }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
    }

    func hide(animated: Bool) {
        materialWorkItem?.cancel()
        materialWorkItem = nil
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard panel.isVisible else { return }
        if animated {
            let revision = presentationRevision
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard self?.presentationRevision == revision else { return }
                    panel?.orderOut(nil)
                }
            })
        } else {
            panel.orderOut(nil)
        }
    }

    private func screen(for cgDisplayID: CGDirectDisplayID?) -> NSScreen? {
        guard let cgDisplayID else { return NSScreen.main }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == cgDisplayID
        } ?? NSScreen.main
    }

    private func origin(for position: OSDPosition, size: NSSize, in frame: NSRect) -> NSPoint {
        let x = frame.midX - size.width / 2
        switch position {
        case .bottomCenter: return NSPoint(x: x, y: frame.minY + 140)
        case .topCenter: return NSPoint(x: x, y: frame.maxY - size.height - 60)
        case .center: return NSPoint(x: x, y: frame.midY - size.height / 2)
        }
    }
}

/// A passive lens edge above the material; placing it inside glass would refract its own highlight.
private final class HUDLensRimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = bounds.height / 2
        let outline = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(outline)
        context.clip()
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        context.setLineWidth(1)
        context.addPath(outline)
        context.strokePath()
        context.setBlendMode(.plusLighter)

        func reflection(in rect: CGRect, width: CGFloat, top: CGFloat, bottom: CGFloat) {
            let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                              cornerHeight: rect.height / 2, transform: nil)
            let colors = [top, top * 0.04, bottom * 0.04, bottom].map {
                CGColor(red: 1, green: 1, blue: 1, alpha: $0)
            }
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors as CFArray, locations: [0, 0.4, 0.6, 1]) else { return }
            context.saveGState()
            context.addPath(path)
            context.setLineWidth(width)
            context.replacePathWithStrokedPath()
            context.clip()
            context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: bounds.maxY),
                                       end: CGPoint(x: bounds.midX, y: bounds.minY), options: [])
            context.restoreGState()
        }
        // A narrow highlight with a smooth inward decay, rather than a broad opaque border.
        for step in 1...16 {
            let distance = CGFloat(step) * 0.5
            let topDecay = exp(-distance / 1.7)
            let bottomDecay = exp(-distance / 2.4)
            reflection(in: bounds.insetBy(dx: distance, dy: distance), width: 0.5,
                       top: 0.16 * topDecay, bottom: 0.20 * bottomDecay)
        }
        reflection(in: bounds, width: 1.35, top: 0.48, bottom: 0.48)
        context.restoreGState()
    }
}

/// The HUD's SwiftUI body. `native`/`classicTahoe` render a square glyph-over-bar HUD; `minimal` is a
/// compact pill. Materials adapt to light/dark automatically (app floor is macOS 14).
struct OSDHUDView: View {
    let content: OSDContent
    let style: OSDStyle
    var displayName: String? = nil

    static func size(for style: OSDStyle) -> NSSize {
        switch style {
        case .minimal: return NSSize(width: 240, height: 48)
        case .modern: return NSSize(width: 308, height: 66)
        default: return NSSize(width: 200, height: 200)
        }
    }

    var body: some View {
        switch style {
        case .minimal: minimalBody
        case .modern: modernBody
        default: squareBody
        }
    }

    private var modernGlyph: String {
        switch content.kind {
        case .brightness: return "sun.max.fill"
        case .volume: return content.value > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill"
        case .mute: return "speaker.slash.fill"
        case .input: return content.glyph
        }
    }

    private var modernBody: some View {
        HStack(spacing: 18.5) {
            Image(systemName: modernGlyph)
                .font(.system(size: content.kind == .brightness ? 26 : 21, weight: .regular)).frame(width: 26)
            if content.kind == .input {
                Text(content.label ?? "").font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        ForEach(0..<OSDContent.segmentCount, id: \.self) { index in
                            Rectangle().fill(.white.opacity(index < content.filledSegments ? 1 : 0.2))
                                .frame(width: max(0, (proxy.size.width - 15) / 16))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 18)
        .padding(.trailing, 31.5)
        .frame(width: 308, height: 66)
        .background {
            if #unavailable(macOS 26) {
                Capsule().fill(.ultraThinMaterial)
                    .clipShape(Capsule())
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var squareBody: some View {
        VStack(spacing: 18) {
            Image(systemName: content.glyph)
                .font(.system(size: 78, weight: .regular))
                .frame(height: 90)
            levelIndicator(segmentWidth: 9, segmentHeight: 9, segmentSpacing: 3)
        }
        .padding(24)
        .frame(width: 200, height: 200)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: style == .classicTahoe ? 10 : 18, style: .continuous))
    }

    private var minimalBody: some View {
        HStack(spacing: 12) {
            Image(systemName: content.glyph).font(.system(size: 18)).frame(width: 22)
            levelIndicator(segmentWidth: 8, segmentHeight: 8, segmentSpacing: 3)
        }
        .padding(.horizontal, 16)
        .frame(width: 240, height: 48)
        .background(.regularMaterial, in: Capsule())
    }

    /// The segmented level bar for brightness/volume/mute, or the switched-to input's name for
    /// `.input` — an input has no meaningful 0...1 level, so it gets a text confirmation instead.
    private func levelIndicator(segmentWidth: CGFloat, segmentHeight: CGFloat, segmentSpacing: CGFloat) -> some View {
        Group {
            if content.kind == .input {
                Text(content.label ?? "").font(.system(size: 15, weight: .medium)).lineLimit(1)
            } else {
                segments(width: segmentWidth, height: segmentHeight, spacing: segmentSpacing)
            }
        }
    }

    private func segments(width: CGFloat, height: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<OSDContent.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < content.filledSegments ? Color.primary : Color.primary.opacity(0.18))
                    .frame(width: width, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
