#if os(macOS)
import AppKit
import DisplayDomain
import OpenDisplayDesignSystem
import SwiftUI
import TopologyCore

/// The menu-bar popover (primary surface), styled after the design kit's `MBDisplay`: a compact
/// per-display row that expands to the *fast, frequent* controls — one unified brightness slider,
/// volume when the panel reports it, status chips, and a few quick actions. Everything detailed
/// (resolution, colour, rotation, hardware/DDC, rename, info) lives one click away in Settings, so the
/// popover stays lean. See `Docs/InterfaceRedesign.md`.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedID: DisplayRecordID?
    @State private var hasSelectedInitialDisplay = false
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: ODSpacing.sm) {
            header
            DisplayChangeConfirmation()
            ScrollView {
                menuContent
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        contentHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight > 0 ? contentHeight : 420, 420))
        }
        .padding(ODSpacing.md)
        .frame(width: 344)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.displays.filter(\.isActive).map(\.recordID), initial: true) { _, activeIDs in
            if let expandedID, activeIDs.contains(expandedID) { return }
            guard expandedID != nil || !hasSelectedInitialDisplay else { return }
            expandedID = model.displays.first { $0.isMain && $0.isActive }?.recordID ?? activeIDs.first
            hasSelectedInitialDisplay = expandedID != nil
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: ODSpacing.xs) {
            if model.isDegraded {
                ODInlineBanner(tone: .orange, systemImage: "exclamationmark.triangle.fill",
                               title: "Some display controls are unavailable",
                               message: "See Health & Recovery for diagnostic details.") {
                    Button("Open Health & Recovery") {
                        model.settingsNavigation.open(.health)
                        showSettings()
                    }
                    .controlSize(.small)
                }
            }
            if let error = model.faceLightError {
                ODInlineBanner(tone: .orange, systemImage: "exclamationmark.triangle.fill",
                               title: "FaceLight needs attention", message: error)
            }
            #if !PUBLIC_API_ONLY
            if let error = model.appPresetError {
                ODInlineBanner(tone: .orange, systemImage: "exclamationmark.triangle.fill",
                               title: "App preset needs attention", message: error)
            }
            #endif
            content
            #if !PUBLIC_API_ONLY
            ODDivider(inset: 0).padding(.vertical, ODSpacing.xs)
            ODSectionLabel("System")
            SystemColourActions()
            #endif
            ODDivider(inset: 0).padding(.vertical, ODSpacing.xs)
            toolsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ODGlyphTile("display", glyphSize: 15)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Displays").font(.headline).accessibilityAddTraits(.isHeader)
                Text(model.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button {
                model.settingsNavigation.open(model.settingsNavigation.section)
                showSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Open Settings")
            .help("Open Settings at the last section")
            Menu {
                Toggle("Keep displays awake while external connected", isOn: Binding(
                    get: { model.settings.preventDisplaySleepWithExternal },
                    set: { model.setPreventDisplaySleepWithExternal($0) }
                ))
                Toggle("Turn built-in off when an external connects", isOn: Binding(
                    get: { model.settings.autoDisconnectBuiltInOnExternal },
                    set: { model.setAutoDisconnectBuiltInOnExternal($0) }
                ))
                Divider()
                Button("About OpenDisplay") {
                    NotificationCenter.default.post(name: .openDisplayShowAbout, object: nil)
                }
                Divider()
                Button("Quit OpenDisplay") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).foregroundStyle(.secondary)
            .menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, ODSpacing.xs)
    }

    @ViewBuilder
    private var content: some View {
        if model.phase == .scanning {
            HStack(spacing: ODSpacing.sm) {
                ProgressView().controlSize(.small)
                Text("Scanning displays…").foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        } else if model.displays.isEmpty && model.managedOffline.isEmpty {
            ODInlineBanner(systemImage: "display.trianglebadge.exclamationmark",
                           title: "No displays detected",
                           message: "If you turned a display off in OpenDisplay, use Reconnect all below.")
        } else {
            ForEach(model.displays, id: \.recordID) { display in
                DisplayCard(display: display, expandedID: $expandedID) { focus in
                    model.selectedDisplayID = display.recordID
                    model.settingsNavigation.openDisplay(display.recordID.rawValue, focus: focus)
                    showSettings()
                }
            }
            ForEach(model.managedOffline) { offline in
                OfflineDisplayCard(offline: offline)
            }
        }
    }

    private var toolsSection: some View {
        VStack(spacing: 2) {
            ODSectionLabel("Tools")
            MenuActionRow(title: "Reconnect all",
                          systemImage: "arrow.triangle.2.circlepath", showChevron: false,
                          enabled: !model.busy) { Task { await model.reconnectAll() } }
            MenuActionRow(title: "Displays & arrangement…", systemImage: "rectangle.3.group",
                          showChevron: true) {
                model.settingsNavigation.open(.arrange)
                showSettings()
            }
            updatesRow
        }
    }

    /// The updates row reflects the updater's live phase — idle, checking, up to date, a badged
    /// version, or an install in flight — and every clickable variant does the same one thing: hand
    /// over to Sparkle, which downloads, verifies, installs, and relaunches. Wording, icon, and
    /// badge come from `SoftwareUpdatePolicy` so this row and the About window can't drift apart.
    private var updatesRow: some View {
        let presentation = SoftwareUpdatePolicy.presentation(for: model.updatePhase)
        return MenuActionRow(title: presentation.title, systemImage: presentation.systemImage,
                             badge: presentation.badge, showChevron: false,
                             enabled: !presentation.showsProgress) { model.checkForUpdates() }
    }

    /// Asks the app delegate to open Settings. The delegate owns that window (AppKit, not SwiftUI's
    /// `Settings` scene) and places it on the screen the user is looking at — opening it through the
    /// responder chain from this `NSPopover` was unreliable and often appeared to do nothing.
    private func showSettings() {
        NotificationCenter.default.post(name: .openDisplayShowSettings, object: nil)
    }
}

/// Keeps the timed recovery controls visible while displays or settings scroll.
struct DisplayChangeConfirmation: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let pending = model.pendingRevert {
            ODInlineBanner(tone: .orange, systemImage: "clock.arrow.circlepath",
                           title: "Keep these display settings?",
                           message: pending.message, countdown: pending.secondsRemaining) {
                Button("Keep") { model.confirmArrangementChange() }
                    .keyboardShortcut(.defaultAction)
                Button("Revert now") { Task { await model.revertArrangementChange() } }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One display: a tappable header (glyph · name · sub · state badge · chevron) that expands to the
/// fast controls — unified brightness, volume (when reported), status chips, and quick actions.
private struct DisplayCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let display: DisplayObservation
    @Binding var expandedID: DisplayRecordID?
    let onOpenSettings: (SettingsNavigation.DisplayFocus) -> Void
    @State private var probedHardware = false

    private var isExpanded: Bool { expandedID == display.recordID }
    private var id: DisplayRecordID { display.recordID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded && display.isActive {
                brightnessRow
                if let volume = model.ddcControl(.volume, for: display) { volumeRow(volume) }
                quickActions
                MenuActionRow(title: "Resolution & refresh rate…", systemImage: "rectangle.expand.vertical",
                              showChevron: true) { onOpenSettings(.resolution) }
                MenuActionRow(title: "Colour & profile…", systemImage: "paintpalette",
                              showChevron: true) { onOpenSettings(.colour) }
            }
        }
        .padding(isExpanded ? 8 : 4)
        .background(isExpanded ? ODColor.cardBackground : .clear,
                    in: RoundedRectangle(cornerRadius: ODRadius.popover))
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: ODRadius.popover).strokeBorder(ODColor.separator, lineWidth: 0.5)
            }
        }
        .onAppear { Task { await model.refreshBrightness(for: display) } }
        .task(id: isExpanded) {
            guard isExpanded, display.displayClass != .builtIn, !probedHardware else { return }
            await model.refreshHardwareControls(for: display)
            probedHardware = true
        }
    }

    private var header: some View {
        Button {
            if reduceMotion { expandedID = isExpanded ? nil : id }
            else { withAnimation(.easeInOut(duration: 0.15)) { expandedID = isExpanded ? nil : id } }
        } label: {
            HStack(spacing: 9) {
                ODGlyphTile(display.displayClass == .builtIn ? "laptopcomputer" : "display",
                            tone: display.isMain ? .accent : .neutral)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName(for: display))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                        .help(model.displayName(for: display))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                trailingBadge
                if display.isActive {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!display.isActive)
        .accessibilityHint(display.isActive
                           ? (isExpanded ? "Hides display controls" : "Shows display controls") : "")
    }

    private var subtitle: String {
        guard display.isActive else { return "Inactive" }
        guard let mode = display.mode else { return "Display mode unavailable" }
        return "\(mode.pointWidth) × \(mode.pointHeight) · \(Int(mode.refreshHz.rounded())) Hz"
    }

    @ViewBuilder private var trailingBadge: some View {
        if model.isBlackedOut(display) {
            ODBadge("Blacked Out", tone: .neutral)
        } else if display.isMain {
            ODBadge("Main")
        } else if display.isMirrored {
            ODBadge("Mirrored")
        } else if display.isActive {
            ODDot(ODColor.connected)
        }
    }

    private var faceLightNeedsRestore: Bool {
        model.settings.faceLightPriorStateByDisplay[id.rawValue] != nil
    }

    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ODSliderRow(
                    systemImage: "sun.min", trailingSystemImage: "sun.max",
                    value: Binding(get: { Double(model.brightness[id] ?? 0.5) },
                                   set: { model.setBrightness(Float($0), for: display) }),
                    valueText: model.brightness[id].map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    accessibilityLabel: "Brightness")
                .disabled(faceLightNeedsRestore || model.brightness[id] == nil)
                .help(faceLightNeedsRestore ? "Turn off FaceLight before changing brightness" : "Brightness")
                if model.xdrCapable(display) { xdrBoostToggle }
            }
            if faceLightNeedsRestore {
                brightnessCaption("Turn off FaceLight to adjust brightness.")
            } else if model.brightness[id] == nil {
                brightnessCaption("Reading brightness…")
            } else {
                ForEach(brightnessCaptions, id: \.self) { caption in
                    brightnessCaption(caption)
                }
            }
        }
    }

    private func brightnessCaption(_ caption: String) -> some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 32)
            .padding(.bottom, 2)
    }

    /// What is worth saying under the slider: how brightness reaches this panel ("Hardware · DDC"),
    /// and — for a grouped display — that moving it moves the rest of its group (Issue #39).
    private var brightnessCaptions: [String] {
        [model.brightnessCaption(for: display), model.groupSyncCaption(for: display)].compactMap { $0 }
    }

    /// XDR Brightness (Labs, Issue #35): a compact sun badge at the end of the brightness row that
    /// boosts SDR content to 2× the panel's SDR maximum while on. Binary on purpose — a second
    /// slider read as over-designed, and "brighter than max" is a yes/no want; the ramp follower
    /// already eases the transition. Only offered on the built-in XDR panel with the Labs toggle on.
    private var xdrBoostToggle: some View {
        Button {
            let isOn = (model.xdrBoostFraction[id] ?? 0) > 0
            model.setXDRBoost(isOn ? 0 : XDRBrightnessPolicy.defaultBoostFraction, for: display)
        } label: {
            Image(systemName: (model.xdrBoostFraction[id] ?? 0) > 0 ? "sun.max.fill" : "sun.max")
                .foregroundStyle((model.xdrBoostFraction[id] ?? 0) > 0 ? ODColor.accent : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("XDR boost — drive SDR content to 2× the panel's normal maximum")
        .accessibilityLabel("XDR boost")
        .accessibilityValue((model.xdrBoostFraction[id] ?? 0) > 0 ? "on" : "off")
    }

    private func volumeRow(_ volume: Float) -> some View {
        ODSliderRow(
            systemImage: "speaker.fill", trailingSystemImage: "speaker.wave.3.fill",
            value: Binding(get: { Double(model.ddcControl(.volume, for: display) ?? volume) },
                           set: { model.setHardwareControl(.volume, Float($0), for: display) }),
            valueText: "\(Int((volume * 100).rounded()))%",
            accessibilityLabel: "Volume")
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ODQuickAction(display.isMain ? "Main Display" : "Set as Main", systemImage: "star",
                          enabled: !model.busy && !display.isMain) {
                // Close before set-main moves the status item.
                NotificationCenter.default.post(name: .openDisplayDismissMenu, object: nil)
                Task { await model.setMain(for: display) }
            }
            ODQuickAction(model.isBlackedOut(display) ? "Show Display" : "Black Out",
                          systemImage: model.isBlackedOut(display) ? "sun.max.fill" : "moon.fill") {
                model.toggleBlackOut(for: display)
            }
            ODQuickAction(faceLightNeedsRestore ? "Turn Off FaceLight" : "FaceLight",
                          systemImage: faceLightNeedsRestore ? "video.slash.fill" : "video.fill",
                          isOn: model.isFaceLightActive(display)) {
                model.toggleFaceLight(for: display)
            }
            ODQuickAction("Turn Off", systemImage: "power", tone: .red,
                          enabled: !model.busy && model.activeDisplayCount > 1) {
                Task { await model.setDisplayActive(false, for: display) }
            }
        }
        .padding(.horizontal, 8).padding(.top, 2)
    }
}

#if !PUBLIC_API_ONLY
private struct SystemColourActions: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ODQuickAction("Night Shift", systemImage: "moon.stars.fill",
                              enabled: model.systemColorState.nightShift != nil,
                              isOn: model.systemColorState.nightShift) {
                    let value = !(model.systemColorState.nightShift ?? false)
                    Task { await model.setGlobalNightShift(value) }
                }
                .help("Toggle macOS Night Shift for all supported displays")
                ODQuickAction("True Tone", systemImage: "sun.max.circle.fill",
                              enabled: model.systemColorState.trueTone != nil,
                              isOn: model.systemColorState.trueTone) {
                    let value = !(model.systemColorState.trueTone ?? false)
                    Task { await model.setGlobalTrueTone(value) }
                }
                .help("Toggle macOS True Tone for all supported displays")
            }
            Text("System-wide · affects supported displays")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if let error = model.systemColorError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 8)
        .task { await model.refreshSystemColors() }
    }
}
#endif

/// A display the app has turned off: stays visible (dimmed) with a Reconnect affordance. The OS no
/// longer enumerates it, so its data comes from AppModel's managed-offline list.
private struct OfflineDisplayCard: View {
    @EnvironmentObject private var model: AppModel
    let offline: AppModel.OfflineDisplay

    var body: some View {
        HStack(spacing: 9) {
            ODGlyphTile(offline.displayClass == .builtIn ? "laptopcomputer" : "display", tone: .neutral)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(offline.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .help(offline.name)
                if offline.reconnectFailedAt == nil {
                    Text("Turned off").font(.caption).foregroundStyle(.secondary)
                } else {
                    // Issue #40: macOS accepted the reconnect and no display appeared. Say so, and
                    // keep the way out one click away — the usual controls can't fix this state.
                    Text("Didn\u{2019}t come back on").font(.system(size: 11)).foregroundStyle(.orange)
                    Button("Recovery steps\u{2026}") {
                        NSWorkspace.shared.open(ReconnectVerification.recoveryGuideURL)
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
            }
            Spacer(minLength: 6)
            Button {
                Task { await model.reconnectOffline(offline) }
            } label: {
                Label(offline.reconnectFailedAt == nil ? "Reconnect" : "Try again",
                      systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11))
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(model.busy)
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
    }
}

/// A single full-width menu row: leading icon, title, and a trailing chevron (push), "Soon" pill, or
/// nothing (immediate action). Used for the Tools section and the per-card "Display settings…" link.
private struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var soon = false
    var badge: String?
    var showChevron = true
    var enabled = true
    var action: () -> Void = {}
    @State private var hovering = false

    private var active: Bool { enabled && !soon }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 14)).frame(width: 18)
                    .foregroundStyle(active ? .secondary : .tertiary)
                Text(title).font(.system(size: 13)).foregroundStyle(active ? .primary : .secondary)
                Spacer()
                if soon {
                    ODBadge("Soon")
                } else if let badge {
                    ODBadge(badge, tone: .accent, solid: true)
                } else if showChevron {
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && active ? ODColor.rowHover : .clear,
                        in: RoundedRectangle(cornerRadius: ODRadius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .onHover { hovering = $0 }
    }
}
#endif
