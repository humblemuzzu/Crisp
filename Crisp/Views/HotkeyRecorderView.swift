import AppKit
import SwiftUI

/// The Keyboard Shortcuts section in Settings: one row per action, each a
/// click-to-record field.
///
/// These are Carbon hot keys (`HotkeyService`), so — unlike the F1/F2 row above
/// them — they need no Accessibility grant and cannot be silently killed by a
/// stale TCC record. The caption says so, because "why are there two of these?"
/// is the first question the section raises.
///
/// Nothing is assigned by default and nothing here can assign a destructive DDC
/// write: `HotkeyAction` only names changes the panel's own sliders already make.
struct KeyboardShortcutsSection: View {
    @ObservedObject private var settings = SettingsService.shared
    @ObservedObject private var hotkeys = HotkeyService.shared

    /// The action currently listening for a key combination, if any.
    @State private var recording: HotkeyAction?
    /// The local key monitor installed while recording. Removed the moment
    /// recording stops — a monitor that outlived the field would swallow keys
    /// the rest of the panel needs.
    @State private var monitor: Any?
    /// Why the last attempt was refused. Cleared when recording restarts.
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(HotkeyAction.allCases, id: \.self) { action in
                HotkeyRecorderRow(
                    action: action,
                    binding: settings.hotkeyBindings[action],
                    isRecording: recording == action,
                    isRefusedBySystem: hotkeys.refusedBySystem.contains(action),
                    onRecord: { beginRecording(action) },
                    onClear: {
                        endRecording()
                        HotkeyService.shared.clear(action)
                    }
                )
            }

            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("These shortcuts need no Accessibility access: macOS delivers the key straight to Crisp, so they keep working even when the F1/F2 keys do not.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // A field left listening across a panel close would keep a key
            // monitor alive with nothing on screen to explain it.
            endRecording()
        }
    }

    // MARK: - Recording

    private func beginRecording(_ action: HotkeyAction) {
        refusal = nil
        recording = action
        guard monitor == nil else { return }
        // Local, not global: the panel is key while the user is clicking in it,
        // and a global monitor would need the very Accessibility grant this whole
        // mechanism exists to do without.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard let target = recording else { return event }
            return handle(event, for: target)
        }
    }

    private func endRecording() {
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Turns one key press into an assignment. Returns nil to swallow the press
    /// (it was for the recorder, not for the panel).
    private func handle(_ event: NSEvent, for action: HotkeyAction) -> NSEvent? {
        let modifiers = HotkeyModifiers(event.modifierFlags)
        // Escape alone cancels; ⌘⎋ or ⌥⎋ are legitimate shortcuts, so only the
        // bare key gets that meaning.
        if event.keyCode == Self.escapeKeyCode, modifiers.isEmpty {
            endRecording()
            return nil
        }
        let candidate = HotkeyBinding(keyCode: UInt16(event.keyCode), modifiers: modifiers)
        switch HotkeyService.shared.assign(candidate, to: action) {
        case .success:
            endRecording()
        case .failure(.needsModifier):
            // Recording stays on so the user can simply press the right thing.
            refusal = String(
                localized: "Add ⌘, ⌥ or ⌃ to the shortcut. A shortcut without one would take that key from every app."
            )
        case .failure(.alreadyAssigned(let owner)):
            refusal = String(
                localized: "\(candidate.displayString) is already the shortcut for \(Self.title(for: owner))."
            )
        }
        return nil
    }

    private static let escapeKeyCode: UInt16 = 53

    /// The user-facing name of an action. In the view rather than on
    /// `HotkeyAction` so the model stays headless and translatable strings stay
    /// where the string catalog extractor looks for them.
    static func title(for action: HotkeyAction) -> String {
        switch action {
        case .brightnessUp: return String(localized: "Brightness up")
        case .brightnessDown: return String(localized: "Brightness down")
        case .volumeUp: return String(localized: "Volume up")
        case .volumeDown: return String(localized: "Volume down")
        case .volumeMute: return String(localized: "Mute")
        }
    }
}

/// One action and its shortcut: a click-to-record field, plus a clear button
/// once something is assigned.
struct HotkeyRecorderRow: View {
    let action: HotkeyAction
    let binding: HotkeyBinding?
    let isRecording: Bool
    /// The OS refused to register this combination — almost always another app
    /// already owns it. Surfaced rather than logged: a shortcut that looks
    /// assigned and never fires is the same "looks like success" failure the
    /// brightness keys taught this app to show.
    let isRefusedBySystem: Bool
    let onRecord: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(KeyboardShortcutsSection.title(for: action))
                .font(.callout)
            Spacer()

            if isRefusedBySystem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .help(Text("Another app already uses this shortcut, so macOS would not give it to Crisp."))
                    .accessibilityLabel(Text("Another app already uses this shortcut, so macOS would not give it to Crisp."))
            }

            Button(action: onRecord) {
                Text(fieldLabel)
                    .font(.callout.monospaced())
                    .foregroundColor(isRecording ? .accentColor : .primary)
                    .frame(minWidth: 74)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(Text("Shortcut for \(KeyboardShortcutsSection.title(for: action))"))
            .accessibilityValue(Text(verbatim: binding?.displayString ?? ""))
            .accessibilityIdentifier("crisp.hotkeys.record.\(action.rawValue)")

            if binding != nil {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove the shortcut for \(KeyboardShortcutsSection.title(for: action))"))
                .accessibilityIdentifier("crisp.hotkeys.clear.\(action.rawValue)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private var fieldLabel: String {
        if isRecording { return String(localized: "Press keys…") }
        return binding?.displayString ?? String(localized: "Record")
    }
}
