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

/// DDC input-source selector (VCP 0x60). Shows the current input — labelled from
/// the monitor quirks database where a human has mapped this model's codes, and
/// otherwise from the VESA table or the raw code — plus a per-display "reapply on
/// reconnect" toggle (off by default: switching input blanks the screen, and a
/// stale saved code can point at an empty port).
///
/// Codes the app cannot vouch for are marked with a trailing "?" and require a
/// confirmation before they are written. Being wrong here is expensive in a way
/// no other DDC feature is: the panel switches to a port with nothing attached
/// and the only way back is the monitor's own physical buttons.
struct InputSourceMenuRow: View {
    @ObservedObject var display: DisplayInfo
    /// Non-nil while an unverified input code is waiting for confirmation.
    @State private var pendingInput: ResolvedInput?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: "rectangle.connected.to.line.below", color: .blue)
                Text("Input Source")
                    .font(.body)
                Spacer()
                Text(DDCFeatureService.shared.inputLabel(for: display))
                    .font(.body)
                    .foregroundColor(.secondary)
                Menu {
                    ForEach(DDCFeatureService.shared.inputOptions(for: display), id: \.code) { option in
                        Button {
                            select(option)
                        } label: {
                            if option.code == display.inputSource {
                                Label(option.displayLabel, systemImage: "checkmark")
                            } else {
                                Text(option.displayLabel)
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
                get: { DDCFeatureService.shared.reapplyInputEnabled(for: display.stateUUID) },
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
        .alert(
            "Switch input?",
            isPresented: Binding(get: { pendingInput != nil }, set: { if !$0 { pendingInput = nil } }),
            presenting: pendingInput
        ) { input in
            Button("Switch", role: .destructive) {
                DDCFeatureService.shared.setInputSource(input.code, for: display)
                pendingInput = nil
            }
            Button("Cancel", role: .cancel) { pendingInput = nil }
        } message: { input in
            Text(confirmationMessage(for: input))
        }
    }

    /// Applies a verified code straight away; anything else asks first.
    ///
    /// "Verified" means the user already chose this code themselves, or the
    /// monitor is on it right now, or a human confirmed it on this model — see
    /// `MonitorQuirkResolver.input`. A label that merely came from a `reported`
    /// database entry or from the generic VESA table is a guess, and this is the
    /// one DDC write the user cannot undo from the Mac.
    private func select(_ option: ResolvedInput) {
        if option.needsConfirmation {
            pendingInput = option
        } else {
            DDCFeatureService.shared.setInputSource(option.code, for: display)
        }
    }

    private func confirmationMessage(for input: ResolvedInput) -> String {
        // One-line literal on purpose: a multi-line literal's extracted key
        // depends on where the continuations fall, and the catalog key has to be
        // something a translator can find by searching for it.
        // `displayLabel` is a String, so this extracts as a %@ specifier; a raw
        // UInt16 would generate a numeric key that never matches the catalog.
        let warning = String(localized: "Input \(input.displayLabel) is not confirmed on this monitor. If nothing is attached to it the screen goes blank, and the only way back is the monitor's own buttons.")
        // The contributor's note, when there is one, says *why* it is unconfirmed.
        return input.notes.map { "\(warning)\n\n\($0)" } ?? warning
    }
}
