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

/// Proof that the panel is carrying out the user's own decision about a
/// destructive DDC write, in the form `DDCFeatureDiscovery` will accept
/// (`DestructiveWriteConsent`).
///
/// Its initialisers are `fileprivate`, so this file — the one that owns the
/// app's destructive-write dialog and its input menu — is the only place in the
/// module that can produce one. A write path can therefore ask for a
/// `PanelConfirmation` and know it did not come from a caller that merely said
/// so. There are exactly two ways to get one, and both are below.
struct PanelConfirmation: DestructiveWriteConsent {
    let consentSite: String

    fileprivate init(consentSite: String) { self.consentSite = consentSite }

    /// The user answered `DestructiveDDCWriteConfirmation`'s alert with its
    /// destructive button. Minted inside that button's action, so it cannot
    /// exist unless the alert was on screen and was agreed to.
    fileprivate static let dialogAnswered = PanelConfirmation(
        consentSite: "you confirmed it in Crisp's panel"
    )

    /// The other half of what "confirmed" has always meant here: the user picked
    /// a value from the app's own control and the resolver could already vouch
    /// for it — they chose this code before, or the monitor is on it right now,
    /// or a human verified it on this model (`MonitorQuirkResolver.input`). No
    /// dialog is shown for those, and none should be.
    ///
    /// Failable rather than trusting the branch that calls it: the check that
    /// decides whether to ask lives *in* the proof, so a call site cannot ask
    /// one question and mint consent for another.
    fileprivate init?(vouchedFor option: ResolvedInput) {
        guard !option.needsConfirmation else { return nil }
        self.init(consentSite: "you picked an input Crisp can already vouch for")
    }
}

/// The confirmation gate for a destructive DDC write.
///
/// There is exactly one of these in the app, and `DDCFeatureDiscovery.authorize`
/// refuses every destructive write that did not come through it — not because
/// the write path remembers to say `.userConfirmed`, but because it has to hand
/// over a `PanelConfirmation`, and the only one in existence is the one this
/// alert's own button hands to `confirm`. It is written as a modifier over an
/// arbitrary payload rather than as part of the input menu so that the next
/// destructive feature — power mode, OSD lock, restore factory defaults, all of
/// which are in `DDCFeatureRegistry` and none of which has a control yet —
/// reuses this dialog instead of growing a second one that is subtly more
/// permissive.
///
/// The caller supplies the wording because the wording is the whole value of the
/// dialog: "are you sure?" tells a user nothing, while "if nothing is attached to
/// that port the screen goes blank and only the monitor's buttons can bring it
/// back" tells them exactly what they are deciding.
struct DestructiveDDCWriteConfirmation<Payload>: ViewModifier {
    let title: LocalizedStringKey
    let confirmLabel: LocalizedStringKey
    @Binding var pending: Payload?
    let message: (Payload) -> String
    /// Takes the consent as well as the payload: the write it performs needs
    /// one, and this is the only place it can come from.
    let confirm: (Payload, PanelConfirmation) -> Void

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { payload in
            Button(confirmLabel, role: .destructive) {
                confirm(payload, .dialogAnswered)
                pending = nil
            }
            // The name is a literal, it just lives at the call site ("Switch"),
            // which is also where it has to be for the string catalog to extract
            // it. Restated here so the button carries a name of its own rather
            // than relying on a value the static gate cannot follow.
            .accessibilityLabel(Text(confirmLabel))
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { payload in
            Text(message(payload))
        }
    }
}

extension View {
    /// Asks before a destructive DDC write. See `DestructiveDDCWriteConfirmation`.
    func destructiveDDCWriteConfirmation<Payload>(
        title: LocalizedStringKey,
        confirmLabel: LocalizedStringKey,
        pending: Binding<Payload?>,
        message: @escaping (Payload) -> String,
        confirm: @escaping (Payload, PanelConfirmation) -> Void
    ) -> some View {
        modifier(DestructiveDDCWriteConfirmation(
            title: title, confirmLabel: confirmLabel,
            pending: pending, message: message, confirm: confirm
        ))
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
                    Divider()
                    // The only way to turn a "?" into a fact. Deliberately in
                    // the same menu as the guesses it replaces: a user who has
                    // just been asked to confirm an unverified code is exactly
                    // the user who should be offered the safe way to find out.
                    Button("Calibrate…") {
                        InputCalibrationWindowController.shared.show(for: display)
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
        // The app's one destructive-write dialog, not a copy of it: the same
        // modifier is what a future power-mode or OSD-lock control has to use,
        // and `DDCFeatureDiscovery.authorize` refuses anything that skipped it.
        .destructiveDDCWriteConfirmation(
            title: "Switch input?",
            confirmLabel: "Switch",
            pending: $pendingInput,
            message: confirmationMessage(for:),
            confirm: { option, confirmation in
                DDCFeatureService.shared.setInputSource(
                    option.code, for: display, confirmedBy: confirmation
                )
            }
        )
    }

    /// Applies a verified code straight away; anything else asks first.
    ///
    /// "Verified" means the user already chose this code themselves, or the
    /// monitor is on it right now, or a human confirmed it on this model — see
    /// `MonitorQuirkResolver.input`. A label that merely came from a `reported`
    /// database entry or from the generic VESA table is a guess, and this is the
    /// one DDC write the user cannot undo from the Mac.
    ///
    /// The question and the answer are the same expression: a code the resolver
    /// can vouch for yields a `PanelConfirmation`, and a code it cannot yields
    /// nothing to write with, only a dialog to show.
    private func select(_ option: ResolvedInput) {
        guard let vouched = PanelConfirmation(vouchedFor: option) else {
            pendingInput = option
            return
        }
        DDCFeatureService.shared.setInputSource(option.code, for: display, confirmedBy: vouched)
    }

    private func confirmationMessage(for input: ResolvedInput) -> String {
        // One-line literal on purpose: a multi-line literal's extracted key
        // depends on where the continuations fall, and the catalog key has to be
        // something a translator can find by searching for it.
        // `displayLabel` is a String, so this extracts as a %@ specifier; a raw
        // UInt16 would generate a numeric key that never matches the catalog.
        let warning = String(localized: "Input \(input.displayLabel) is not confirmed on this monitor. If nothing is attached to it the screen goes blank, and the only way back is the monitor's own buttons.")
        let alternative = String(localized: "Calibrate… switches with a countdown that undoes itself, which is the safe way to find out.")
        // The contributor's note, when there is one, says *why* it is unconfirmed.
        let body = input.notes.map { "\(warning)\n\n\($0)" } ?? warning
        return "\(body)\n\n\(alternative)"
    }
}
