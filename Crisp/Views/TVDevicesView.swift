import SwiftUI

// Smart TVs, in the panel's Settings section.
//
// One collapsed row until it is opened, like groups, presets and schedules —
// this is a menu-bar panel someone opens to nudge a slider, and a feature nobody
// has set up must cost one line of height and no attention. Someone who owns no
// television sees "TVs — None added" and nothing else ever happens, on screen or
// on their network.
//
// No decisions live here. What a platform can reach is `TVFeatureRegistry`,
// whether an action may happen is `TVActionRequest.plan` and `TVWriteGate`, and
// what a certificate means is `TVTrust` — all pure and tested headlessly. This
// file names things, shows the reason next to a control that cannot work, and
// routes the two destructive actions through the app's **existing** confirmation
// dialog so no new consent type had to be invented for them.

// MARK: - Section

struct TVDevicesSection: View {
    @ObservedObject private var tvs = TVDeviceService.shared
    @Binding var isExpanded: Bool

    /// Non-nil while the "add a TV" form is open.
    @State private var draft: TVDraft?
    /// The TV being renamed, and its in-progress name.
    @State private var renaming: (id: TVDeviceID, name: String)?
    /// Non-nil while a destructive TV action is waiting for the one dialog.
    @State private var pendingAction: PendingTVAction?
    /// The last refusal, shown inline rather than as an alert: a TV that is off
    /// is the ordinary case and does not deserve a modal.
    @State private var lastMessage: String?

    private var subtitle: String {
        tvs.devices.isEmpty
            ? String(localized: "None added")
            : String(localized: "\(tvs.devices.count) added")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "tv",
                iconColor: .teal,
                iconActive: !tvs.devices.isEmpty,
                label: "TVs",
                subtitle: subtitle,
                isExpanded: $isExpanded
            )
            if isExpanded {
                ForEach(tvs.devices) { device in
                    deviceRow(device)
                }
                if let draft {
                    TVAddForm(
                        draft: draft,
                        onChange: { self.draft = $0 },
                        onCancel: { self.draft = nil },
                        onPair: { pair($0) }
                    )
                } else {
                    Button("Add a TV…") {
                        draft = TVDraft()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .padding(.leading, 46)
                    .padding(.trailing, 12)
                    .padding(.vertical, 3)
                }
                if let lastMessage {
                    Text(lastMessage)
                        .font(.caption)
                        .foregroundColor(.secondaryReadable)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 46)
                        .padding(.trailing, 12)
                        .padding(.bottom, 4)
                }
            }
        }
        // The app's one destructive-write dialog, reused rather than copied. It
        // mints a `PanelConfirmation`, which is what `TVWriteGate.approve` needs
        // — so turning a television off from this panel is authorised by exactly
        // the token a VCP 0xD6 write would be, and no fourth
        // `DestructiveWriteConsent` conformer exists anywhere in this feature.
        .destructiveDDCWriteConfirmation(
            title: "Change this TV?",
            confirmLabel: "Continue",
            pending: $pendingAction,
            message: { $0.hazard },
            confirm: { pending, confirmation in
                Task {
                    let approval = TVWriteGate.approve(
                        pending.write, authorization: .confirmed(by: confirmation)
                    )
                    guard case .approved(let approved) = approval else {
                        lastMessage = approval.refusalReason
                        return
                    }
                    lastMessage = await tvs.perform(approved).message
                }
            }
        )
    }

    // MARK: One TV

    @ViewBuilder
    private func deviceRow(_ device: TVDevice) -> some View {
        if let renaming, renaming.id == device.id {
            TVNameField(
                text: renaming.name,
                onCommit: { committed in
                    tvs.rename(device.id, to: committed)
                    self.renaming = nil
                },
                onCancel: { self.renaming = nil },
                onChange: { self.renaming = (id: device.id, name: $0) }
            )
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name).font(.callout)
                        Text(verbatim: "\(device.platform.title) · \(device.host)")
                            .font(.caption)
                            .foregroundColor(.secondaryReadable)
                    }
                    Spacer()
                    Menu {
                        Button("Refresh") {
                            Task { lastMessage = await tvs.refresh(device.id).message }
                        }
                        Button("Rename…") {
                            renaming = (id: device.id, name: device.name)
                        }
                        // Binding a TV to one of the Mac's screens is what
                        // promotes that display's brightness ladder from gamma to
                        // `.tvNetwork`. Only the user can make this connection: a
                        // display and a device on the LAN share no identifier, and
                        // inferring one from resolution or EDID name would be a
                        // guess that sends commands to a television in another
                        // room.
                        Divider()
                        ForEach(DisplayManagerAccessor.shared.displays.filter { !$0.isBuiltin }) { display in
                            Button {
                                let bound = tvs.boundDevice(forDisplay: display.stateUUID)?.id == device.id
                                tvs.bind(bound ? nil : device.id, toDisplay: display.stateUUID)
                            } label: {
                                if tvs.boundDevice(forDisplay: display.stateUUID)?.id == device.id {
                                    Label(display.name, systemImage: "checkmark")
                                } else {
                                    Text(verbatim: display.name)
                                }
                            }
                        }
                        Divider()
                        Button("Remove", role: .destructive) {
                            tvs.remove(device.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("TV actions")
                }
                controls(for: device)
            }
            .padding(.leading, 46)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private func controls(for device: TVDevice) -> some View {
        let brightness = TVFeatureRegistry.support(.brightness, on: device.platform)

        // The Tizen case, stated rather than hidden. A control that is simply
        // absent reads as a bug; a disabled one with the sentence next to it is
        // an answer, and it is the same sentence `BrightnessRung`'s badge shows
        // for a TV-backed display (`Reason.tvBrightnessNotRemote`).
        if let reason = brightness.unsupportedReason {
            Slider(value: .constant(0), in: 0...100)
                .controlSize(.mini)
                .disabled(true)
                .accessibilityLabel("TV brightness")
                .accessibilityValue(Text("Not available on this TV"))
            Text(reason.text)
                .font(.caption2)
                .foregroundColor(.secondaryReadable)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TVPercentSlider(
                label: "TV brightness",
                value: tvs.states[device.id]?.backlight ?? 50,
                onCommit: { percent in
                    apply(device, .brightness, .percent(percent))
                }
            )
        }

        TVPercentSlider(
            label: "TV volume",
            value: tvs.states[device.id]?.volume ?? 50,
            onCommit: { percent in
                apply(device, .volume, .percent(percent))
            }
        )
        if let note = tvs.states[device.id]?.externalAudioNote {
            Text(note)
                .font(.caption2)
                .foregroundColor(.secondaryReadable)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 10) {
            Button("Mute") {
                apply(device, .mute, .flag(true))
            }
            .buttonStyle(.link)
            .font(.caption)

            Button("Input…") {
                // On webOS the identifiers come from the TV's own input list; on
                // Tizen nothing local can be read back, so `KEY_SOURCE` opens the
                // source list and the user picks on the television. Both go
                // through the confirmation below, because both can end in a black
                // screen the Mac cannot read.
                let code = tvs.states[device.id]?.inputs.first?.id
                    ?? TizenRemote.Key.source.rawValue
                apply(device, .input, .code(code))
            }
            .buttonStyle(.link)
            .font(.caption)

            Button("Turn Off") {
                apply(device, .power, .flag(false))
            }
            .buttonStyle(.link)
            .font(.caption)

            Spacer()
        }
        .padding(.top, 1)
    }

    /// Plans an action and either performs it or opens the one dialog.
    ///
    /// The question and the answer are the same expression, exactly as
    /// `InputSourceMenuRow.select` is: a non-destructive action yields an
    /// approval to act on, and a destructive one yields nothing to act with —
    /// only a payload for the alert.
    private func apply(_ device: TVDevice, _ feature: TVFeatureID, _ value: TVActionValue) {
        let request = TVActionRequest(
            origin: .panel, device: device.id, feature: feature, value: value
        )
        switch request.plan(known: tvs.knownPlatforms) {
        case .rejected(let reason):
            lastMessage = reason
        case .needsConfirmation(let write, let hazard):
            pendingAction = PendingTVAction(write: write, hazard: hazard, deviceName: device.name)
        case .ready(let write):
            let approval = TVWriteGate.approve(write, authorization: .automatic)
            guard case .approved(let approved) = approval else {
                lastMessage = approval.refusalReason
                return
            }
            Task { lastMessage = await tvs.perform(approved).message }
        }
    }

    private func pair(_ draft: TVDraft) {
        Task {
            let outcome = await tvs.pair(
                host: draft.host, platform: draft.platform,
                name: draft.name.isEmpty ? nil : draft.name
            )
            switch outcome {
            case .paired(let device):
                self.draft = nil
                lastMessage = String(localized: "Paired with \(device.name).")
            case .refused(let reason):
                lastMessage = reason
            }
        }
    }
}

// MARK: - Pieces

/// A destructive TV action waiting for the one dialog.
struct PendingTVAction: Equatable {
    let write: TVWrite
    /// The registry's own words. "Are you sure?" tells a user nothing; "the
    /// control connection goes down with the TV, so Crisp cannot turn it back
    /// on" tells them exactly what they are deciding.
    let hazard: String
    let deviceName: String
}

/// The in-progress "add a TV" form.
struct TVDraft: Equatable {
    var host: String = ""
    var name: String = ""
    var platform: TVPlatform = .webOS
}

/// A 0–100 slider that writes on release only.
///
/// Release-only, unlike the DDC sliders: every value here is a network round
/// trip to a device that may be on the other side of a Wi-Fi link, and a live
/// drag would queue behind itself. The TV service coalesces underneath as well,
/// so this is belt and braces on the one path where the belt is a router.
private struct TVPercentSlider: View {
    let label: LocalizedStringKey
    let value: Double
    let onCommit: (Double) -> Void

    @State private var local: Double = 50

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $local, in: 0...100) { editing in
                if !editing { onCommit(local) }
            }
            .controlSize(.mini)
            .accessibilityLabel(Text(label))
            .accessibilityValue("\(Int(local))%")

            Text("\(Int(local))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .onAppear { local = value }
        .onChange(of: value) { _, newValue in local = newValue }
    }
}

/// The add-a-TV form. A form in the panel rather than a window, for the reason
/// `NameField` gives: a popover that opens a window to ask for a string has lost
/// the user's place.
private struct TVAddForm: View {
    let draft: TVDraft
    let onChange: (TVDraft) -> Void
    let onCancel: () -> Void
    let onPair: (TVDraft) -> Void

    @ObservedObject private var discovery = TVDiscoveryService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("TV type", selection: Binding(
                get: { draft.platform },
                set: { var copy = draft; copy.platform = $0; onChange(copy) }
            )) {
                ForEach(TVPlatform.allCases, id: \.self) { platform in
                    Text(verbatim: platform.title).tag(platform)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("TV type")

            TextField("TV address", text: Binding(
                get: { draft.host },
                set: { var copy = draft; copy.host = $0; onChange(copy) }
            ))
            .accessibilityLabel("TV address")
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.callout)

            TextField("TV name", text: Binding(
                get: { draft.name },
                set: { var copy = draft; copy.name = $0; onChange(copy) }
            ))
            .accessibilityLabel("TV name")
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .font(.callout)

            HStack(spacing: 6) {
                // Discovery is a button and only a button: nothing multicasts on
                // the user's network unless they press this (see
                // `TVDiscoveryService`). Typing an address stays first-class,
                // because a TV on a guest VLAN will never answer a search.
                Button("Find TVs") {
                    Task { await discovery.search() }
                }
                .controlSize(.small)
                .disabled(discovery.isSearching)

                Button("Pair") { onPair(draft) }
                    .controlSize(.small)
                    .disabled(draft.host.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }

            if discovery.isSearching {
                Text("Looking for TVs on this network…")
                    .font(.caption2)
                    .foregroundColor(.secondaryReadable)
            }
            ForEach(discovery.candidates) { candidate in
                Button {
                    var copy = draft
                    copy.host = candidate.host
                    copy.platform = candidate.platform
                    onChange(copy)
                } label: {
                    Text(verbatim: "\(candidate.host) — \(candidate.platform.title)")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            Text("Pairing puts a prompt on the TV. Accept it there, then Crisp remembers this TV.")
                .font(.caption2)
                .foregroundColor(.secondaryReadable)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
    }
}

/// Renaming a TV. A near-copy of `GroupsPresetsView`'s `NameField`, which is
/// `private` to that file; sharing it would mean promoting a naming affordance
/// into a general component before there is a second real use for it.
private struct TVNameField: View {
    let text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let onChange: (String) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("TV name", text: Binding(get: { text }, set: onChange))
                .accessibilityLabel("TV name")
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.callout)
                .focused($isFocused)
                .onSubmit(commit)

            Button("Save", action: commit)
                .controlSize(.small)
                .disabled(trimmed.isEmpty)

            Button("Cancel", action: onCancel)
                .controlSize(.small)
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .onAppear { isFocused = true }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }
}
