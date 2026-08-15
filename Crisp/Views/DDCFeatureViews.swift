import SwiftUI

/// DDC contrast slider (VCP 0x12), mirroring the volume slider's structure:
/// coalesced writes through DDCFeatureService, live on drag, adopt-on-probe.
struct ContrastSliderView: View {
    @ObservedObject var display: DisplayInfo
    @State private var localContrast: Double = 50
    @State private var isDragging: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $localContrast, in: 0...100) { editing in
                isDragging = editing
                if !editing {
                    DDCFeatureService.shared.setContrast(localContrast, for: display)
                }
            }
            .controlSize(.small)
            .accessibilityLabel("Contrast")
            .accessibilityValue("\(Int(localContrast))%")
            .onChange(of: localContrast) { _, newValue in
                guard isDragging else { return }
                DDCFeatureService.shared.setContrast(newValue, for: display)
            }

            Text("\(Int(localContrast))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .task(id: display.displayID) { localContrast = display.contrast }
        .onChange(of: display.contrast) { _, newValue in
            // External change (probe adopting the OSD level, reconnect reapply).
            if !isDragging && abs(newValue - localContrast) >= 0.1 {
                localContrast = newValue
            }
        }
    }
}

/// DDC input-source selector (VCP 0x60). Shows the current input (raw code if
/// the monitor uses nonstandard numbering) plus the common VESA inputs, and a
/// per-display "reapply on reconnect" toggle (off by default — switching input
/// blanks the screen, and a stale saved code can point at an empty port).
struct InputSourceMenuRow: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "rectangle.connected.to.line.below", color: .blue)
                Text("Input Source")
                    .font(.body)
                Spacer()
                Text(DDCFeatureService.inputLabel(for: display.inputSource))
                    .font(.body)
                    .foregroundColor(.secondary)
                Menu {
                    ForEach(DDCFeatureService.inputMenuItems(current: display.inputSource), id: \.value) { item in
                        Button {
                            DDCFeatureService.shared.setInputSource(item.value, for: display)
                        } label: {
                            if item.value == display.inputSource {
                                Label(item.label, systemImage: "checkmark")
                            } else {
                                Text(item.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Toggle(isOn: Binding(
                get: { DDCFeatureService.shared.reapplyInputEnabled(for: display.displayUUID) },
                set: { DDCFeatureService.shared.setReapplyInput($0, for: display) }
            )) {
                Text("Reapply input on reconnect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }
}
