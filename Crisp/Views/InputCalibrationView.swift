import AppKit
import SwiftUI

// The input-source calibration wizard.
//
// It exists because input codes cannot be looked up. The VESA MCCS table calls
// code 19 "DVI-10"; the BenQ MA320U this fork was built for reports 19 and has
// no DVI port. The only way to learn the mapping is to switch to a code and have
// a person say whether the picture came back — and that is also the operation
// that can leave them staring at a black screen with no way back except the
// monitor's own buttons.
//
// So the window is built around one rule: **the user is never asked to do
// anything they can only do while they can see.** Confirming is the *optional*
// action; doing nothing reverts. The countdown lives in
// `InputCalibrationService`, on a dispatch timer that does not care whether this
// window is drawing, is on the blank display, or exists at all.
//
// Two consequences worth stating, because they look like omissions:
//
// - **No modal sheet or `NSAlert` anywhere.** A modal spins its own run loop,
//   and a countdown that a run-loop mode can starve is not a safety net.
// - **The window opens on the display being calibrated.** Asking "can you see
//   this?" on the *other* monitor would collect a yes for a panel that is black.

// MARK: - Window

/// Owns the single calibration window and puts it on the right screen.
@MainActor
final class InputCalibrationWindowController: NSObject, NSWindowDelegate {
    static let shared = InputCalibrationWindowController()

    private var window: NSWindow?

    /// Opens the wizard for `display`, or does nothing if a session is already
    /// running (for this display or another one). Two panels being switched at
    /// once is not a scenario with a safe revert.
    func show(for display: DisplayInfo) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard InputCalibrationService.shared.begin(for: display) else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Calibrate Input Sources")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: InputCalibrationView(display: display, service: InputCalibrationService.shared)
        )
        window.delegate = self
        self.window = window

        centre(window, on: display)
        // LSUIElement app: without an explicit activation the window opens behind
        // whatever the user was looking at — on the display whose picture is
        // about to be taken away, which is the worst possible place to hide it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Centres on the display under test. `NSScreen.screen(for:)` can miss during
    /// a reconfiguration storm; falling back to the main screen is better than
    /// not showing the window, because the countdown is running either way.
    private func centre(_ window: NSWindow, on display: DisplayInfo) {
        guard let frame = (NSScreen.screen(for: display.displayID) ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        ))
    }

    func close() {
        window?.close()
    }

    /// The close button is a *request*, not a dismissal: mid-trial the service
    /// reverts first and the window goes when the monitor is back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let service = InputCalibrationService.shared
        guard service.isCalibrating else { return true }
        service.close()
        return !service.isCalibrating
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - View

struct InputCalibrationView: View {
    @ObservedObject var display: DisplayInfo
    @ObservedObject var service: InputCalibrationService

    @State private var portName: String = ""
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // A closed session renders as `.choosing`: the window can
                    // outlive the session by a frame, and the candidate list is
                    // the one step that is meaningful with nothing in flight.
                    step(service.session?.phase ?? .choosing)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        // The window cannot close itself while a revert is in flight
        // (`windowShouldClose` refuses), so the close has to be re-tried once the
        // session actually ends. Without this, a Done pressed mid-countdown
        // reverts correctly and then leaves an empty window on screen.
        .onChange(of: service.session == nil) { _, ended in
            if ended { InputCalibrationWindowController.shared.close() }
        }
    }

    @ViewBuilder
    private func step(_ phase: InputCalibrationPhase) -> some View {
        switch phase {
        case .switching(let code):
            switchingStep(code: code)
        case .confirming(let code, _):
            confirmStep(code: code)
        case .reverting(_, let reason, _):
            revertingStep(reason: reason)
        case .revertFailed:
            revertFailedStep
        case .naming(let code):
            namingStep(code: code)
        case .interrupted:
            interruptedStep
        case .choosing, .finished:
            chooseStep
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calibrate Input Sources")
                .font(.headline)
            Text(verbatim: display.name)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Steps

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Each of these stays a single-line literal even where it runs long:
            // the key SwiftUI extracts from a multi-line literal depends on where
            // the continuations fall, so a reflowed string is a key a translator
            // can no longer find.
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("Crisp switches the monitor to the code you pick, then waits 15 seconds for you to confirm you can still see this window. If you do not, it switches back by itself.")
                .font(.callout)
                .foregroundColor(.secondary)

            if let reverted = service.lastRevert {
                Label(revertMessage(reverted), systemImage: "arrow.uturn.backward")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            ForEach(service.session?.candidates ?? [], id: \.self) { code in
                candidateRow(code)
            }
        }
    }

    private func candidateRow(_ code: UInt16) -> some View {
        let confirmed = service.calibratedInputs(for: display.stateUUID).first { $0.code == code }
        let isCurrent = code == display.inputSource
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(code)")
                    .font(.body.monospacedDigit())
                Text(verbatim: subtitle(for: code, confirmed: confirmed?.label, isCurrent: isCurrent))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if confirmed != nil {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Confirmed")
            }
            Button("Test") { service.test(code) }
                .disabled(service.session?.phase != .choosing)
        }
        .padding(.vertical, 4)
    }

    private func switchingStep(code: UInt16) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
            Text("Switching to input \(String(code))…")
                .font(.callout)
        }
    }

    private func confirmStep(code: UInt16) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Can you see this?")
                .font(.title2.bold())
            Text("The monitor is now on input \(String(code)). If this window is on screen, click Keep. Doing nothing switches the monitor back in \(String(service.secondsRemaining)) seconds.")
                .font(.callout)

            ProgressView(
                value: Double(service.secondsRemaining),
                total: service.session?.confirmWindow ?? 15
            )
            .progressViewStyle(.linear)

            HStack(spacing: 10) {
                Button("Keep") { service.keep() }
                    .keyboardShortcut(.defaultAction)
                Button("Switch Back Now") { service.revertNow() }
            }
        }
    }

    private func revertingStep(reason: InputCalibrationRevertReason) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView()
            Text(revertMessage(reason))
                .font(.callout)
            Text("Switching back to input \(String(service.session?.originalCode ?? 0))…")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var revertFailedStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Could not switch the monitor back", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.orange)
            Text("The monitor did not acknowledge the switch back to input \(String(service.session?.originalCode ?? 0)). If the screen is blank, use the monitor's own buttons to change its input. Crisp will try again the next time it can reach this monitor.")
                .font(.callout)
        }
    }

    private func namingStep(code: UInt16) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What is plugged into input \(String(code))?")
                .font(.headline)
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("Use the name printed on the monitor, e.g. USB-C or HDMI 2. This is the only thing Crisp treats as confirmed: you saw the picture on this code.")
                .font(.callout)
                .foregroundColor(.secondary)
            TextField("Port name", text: $portName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") {
                    service.name(portName)
                    portName = ""
                }
                .keyboardShortcut(.defaultAction)
                Button("Skip") {
                    service.name("")
                    portName = ""
                }
            }
        }
    }

    private var interruptedStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The monitor was disconnected", systemImage: "cable.connector.slash")
                .font(.headline)
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("Calibration stopped. Crisp remembers the input this monitor was on and switches it back when the monitor is next connected.")
                .font(.callout)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Copy Quirks Entry") { copyReport() }
                .disabled(service.calibratedInputs(for: display.stateUUID).isEmpty)
            Button("Done") { InputCalibrationWindowController.shared.close() }
        }
        .padding(16)
    }

    private func copyReport() {
        let subject = service.report(for: display)
        do {
            let json = try InputCalibrationReport.json(for: subject)
            let body = InputCalibrationReport.issueBody(for: subject, json: json)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
            notice = String(localized: "Copied — paste it into a new issue or pull request.")
        } catch {
            notice = String(localized: "Nothing has been confirmed yet, so there is nothing to report.")
        }
    }

    // MARK: Text

    private func subtitle(for code: UInt16, confirmed: String?, isCurrent: Bool) -> String {
        var parts: [String] = []
        if let confirmed { parts.append(confirmed) }
        if isCurrent { parts.append(String(localized: "in use now")) }
        if confirmed == nil {
            let resolved = DDCFeatureService.shared.resolvedInput(code, for: display)
            if resolved.labelSource == .database || resolved.labelSource == .standard {
                parts.append(resolved.displayLabel)
            }
        }
        return parts.isEmpty ? String(localized: "not mapped yet") : parts.joined(separator: " · ")
    }

    private func revertMessage(_ reason: InputCalibrationRevertReason) -> String {
        switch reason {
        case .timedOut:
            return String(localized: "Nobody confirmed the last switch, so it was undone — that input is probably not showing this Mac.")
        case .userCancelled:
            return String(localized: "The last switch was undone at your request.")
        case .writeNotAcknowledged:
            return String(localized: "The monitor did not acknowledge the last switch, so it was undone.")
        }
    }
}
