import SwiftUI

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    var compact: Bool = false  // Compact mode: badge sits inline instead of on its own row
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row (roomy layout only; the compact one carries the
            // same badge inline, next to the percentage).
            if !compact {
                HStack(spacing: 4) {
                    Spacer()
                    BrightnessRungBadge(rung: display.brightnessRung, isBuiltin: display.isBuiltin)
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            HStack(spacing: 8) {
                // Native macOS slider, exactly as in the system Display panel.
                // One control, no step buttons: drags and clicks write the value
                // immediately (the coalescing DDC writer paces the I2C bus).
                Slider(value: $localBrightness, in: 0...max(100.0, display.maxBrightness)) { editing in
                    isDragging = editing
                    if !editing {
                        Task { @MainActor in
                            // Flush the final value; the coalescing writer already tracked the drag.
                            // setBrightness re-resolves the rung, so the badge follows a
                            // mid-drag fallback (DDC gave up) without polling for it.
                            await BrightnessService.shared.setBrightness(localBrightness, for: display)
                        }
                    }
                }
                .modifier(BoostTintModifier(progress: localBrightness > 100.5 ? 1 : 0))
                .animation(.easeInOut(duration: 0.3), value: localBrightness > 100.5)
                .overlay {
                    if display.maxBrightness > 100 {
                        GeometryReader { geo in
                            // Notch at the 100% mark: the track to its right is
                            // the Extra Brightness region. The slider's track is
                            // inset by roughly the knob radius on each side;
                            // ponytail: 10pt eyeballed for .small controls, tune
                            // here if the notch sits visibly off the thumb
                            // center when parked at exactly 100.
                            let inset: CGFloat = 10
                            let usable = geo.size.width - inset * 2
                            let x = inset + usable * 100.0 / display.maxBrightness
                            RoundedRectangle(cornerRadius: 0.75)
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 1.5, height: 8)
                                .position(x: x, y: geo.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .controlSize(.small)
                // Nothing on this machine can dim this screen: a live-looking
                // knob that writes nowhere is worse than an honest dead one.
                .disabled(!display.brightnessRung.isControllable)
                .accessibilityLabel("Display brightness")
                .accessibilityValue("\(Int(localBrightness))%")
                .onChange(of: localBrightness) { _, newValue in
                    guard isDragging else { return }
                    // Live write during drag or click; the coalescing writer keeps the
                    // I2C bus from flooding and drops intermediate steps.
                    display.brightness = newValue
                    Task { @MainActor in
                        await BrightnessService.shared.setBrightness(newValue, for: display)
                    }
                }

                if compact {
                    BrightnessRungBadge(rung: display.brightnessRung, isBuiltin: display.isBuiltin)
                }

                Text("\(Int(localBrightness))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // The one rung whose reason is worth spending a line on: the control
            // above is disabled, so the panel has to say why without a hover.
            if let reason = unavailableReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
        .task(id: display.displayID) {
            localBrightness = display.brightness
            // Panel open is the moment the badge has to be right; the service
            // recomputes it from what it knows rather than the view guessing.
            BrightnessService.shared.refreshRung(for: display)
        }
        .onChange(of: display.brightness) { _, newValue in
            // External change (brightness keys, another app, reconnect reapply).
            // NSSlider renders value changes discretely (withAnimation does not
            // interpolate control values), so smoothness comes from the 60Hz
            // fade steps; track every one of them with a low threshold.
            if !isDragging && abs(newValue - localBrightness) >= 0.1 {
                localBrightness = newValue
            }
        }
    }

    /// Animates the slider tint between accent and boost yellow when the
    /// value crosses 100. Tint on a control does not interpolate on its own,
    /// so the blend progress is the animatable data and the mixed color is
    /// recomputed every frame of the transition.
    private struct BoostTintModifier: ViewModifier, Animatable {
        var progress: Double
        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
        func body(content: Content) -> some View {
            content.tint(boostTint)
        }

        private var boostTint: Color {
            guard progress > 0 else { return .accentColor }
            let fraction = min(1.0, progress)
            if #available(macOS 15.0, *) {
                return Color.accentColor.mix(with: .yellow, by: fraction)
            }
            // macOS 14: Color.mix is 15+; AppKit's blend interpolates in a
            // slightly different space, indistinguishable across a tint ramp.
            return Color(nsColor: NSColor.controlAccentColor
                .blended(withFraction: fraction, of: .systemYellow) ?? .controlAccentColor)
        }
    }

    private var unavailableReason: String? {
        guard case .unavailable(let reason) = display.brightnessRung else { return nil }
        return reason.text
    }
}

/// Names the mechanism currently dimming a display: a 5pt dot plus one word,
/// deliberately quiet (this is a menu-bar panel, not a diagnostics console).
/// The reason for a degraded rung is one hover away rather than on screen.
struct BrightnessRungBadge: View {
    let rung: BrightnessRung
    let isBuiltin: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(label)
                .font(.caption2)
                .foregroundColor(color)
                .lineLimit(1)
                .fixedSize()
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label). \(tooltip)"))
    }

    /// Hardware keeps the wording the two paths have always used ("System" for
    /// the built-in panel's IOKit backlight, "DDC" for a monitor's own register):
    /// both are rung 1, and both are the real backlight.
    private var label: String {
        switch rung {
        case .ddcHardware: return isBuiltin ? String(localized: "System") : String(localized: "DDC")
        case .gammaTable: return String(localized: "Gamma")
        case .overlay: return String(localized: "Overlay")
        case .unavailable: return String(localized: "Unavailable")
        }
    }

    private var color: Color {
        switch rung {
        case .ddcHardware: return isBuiltin ? .blue : .green
        case .gammaTable, .overlay: return .orange
        case .unavailable: return .secondary
        }
    }

    private var tooltip: String {
        if let reason = rung.reason { return reason.text }
        return isBuiltin
            ? String(localized: "The built-in panel's own backlight, through IOKit.")
            : String(localized: "The monitor's own backlight, over DDC/CI.")
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double = 50
    @State private var isDragging: Bool = false

    private var averageBrightness: Double {
        guard !displays.isEmpty else { return 50 }
        // Proportional: each display contributes its position within its own
        // range, so a boosted display at 160/160 and a plain one at 100/100
        // both read as 100%.
        return displays.map { $0.brightness / $0.maxBrightness * 100.0 }.reduce(0, +) / Double(displays.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Bold title matching the per-display name rows (DisplayRowView), so the
            // combined control reads as another titled row rather than a separate
            // widget. Aligned to the display titles' 14pt inset; the slider below
            // keeps the sliders' 12pt inset.
            Text("Combined")
                .fontWeight(.semibold)
                .lineLimit(1)
                .padding(.horizontal, 14)

            HStack(spacing: 8) {
                Slider(value: $combinedBrightness, in: 0...100) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag/click ended, flush final value to all displays.
                        Task { @MainActor in
                            for display in displays {
                                await BrightnessService.shared.setBrightness(
                                    combinedBrightness / 100.0 * display.maxBrightness, for: display)
                            }
                        }
                    }
                }
                .tint(Color.accentColor)
                .controlSize(.small)
                .accessibilityLabel("Combined brightness")
                .accessibilityValue("\(Int(combinedBrightness))%")
                .onChange(of: combinedBrightness) { _, newValue in
                    guard isDragging else { return }
                    // Live write during drag or click.
                    Task { @MainActor in
                        for display in displays {
                            let target = newValue / 100.0 * display.maxBrightness
                            display.brightness = target
                            await BrightnessService.shared.setBrightness(target, for: display)
                        }
                    }
                }

                Text("\(Int(combinedBrightness))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background {
            // Track the displays' real brightness so the combined handle glides in
            // exact sync with the per-display handles (they read the same source
            // that setBrightnessSmooth updates per-frame). Invisible; skipped while
            // dragging, when the drag itself is driving the displays.
            ForEach(displays) { display in
                BrightnessProbe(display: display) {
                    if !isDragging { combinedBrightness = averageBrightness }
                }
            }
        }
        .onAppear {
            combinedBrightness = averageBrightness
        }
    }
}

/// Invisible observer of one display's brightness. Lets an aggregate control (the
/// combined slider) react to the displays' real per-frame fade without owning a
/// separate animation. Zero-sized, so it adds nothing to layout.
private struct BrightnessProbe: View {
    @ObservedObject var display: DisplayInfo
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: display.brightness) { _, _ in onChange() }
    }
}
