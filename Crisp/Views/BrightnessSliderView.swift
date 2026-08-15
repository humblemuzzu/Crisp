import SwiftUI

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    var compact: Bool = false  // Compact mode: hides the mode label row (used for top-level inline sliders)
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row
            if !compact {
            HStack(spacing: 4) {
                Spacer()
                if display.isBuiltin {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("System")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if let status = ddcStatus {
                    Circle()
                        .fill(status ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(status ? "DDC" : "Software")
                        .font(.caption2)
                        .foregroundColor(status ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(
                display.isBuiltin
                    ? "Brightness control mode: System"
                    : (ddcStatus == true
                        ? "Brightness control mode: DDC hardware"
                        : "Brightness control mode: Software emulation")
            )
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
                            await BrightnessService.shared.setBrightness(localBrightness, for: display)
                            updateDDCStatus()
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

                Text("\(Int(localBrightness))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            localBrightness = display.brightness
            updateDDCStatus()
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

    private func updateDDCStatus() {
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
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
