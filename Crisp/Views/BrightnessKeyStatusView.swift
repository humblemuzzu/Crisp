import AppKit
import SwiftUI

/// Live status line for the brightness-key tap, under the Brightness Keys row in Settings.
///
/// It exists because the failure that costs the most time is the one that looks like success:
/// System Settings shows Crisp's Accessibility toggle ON while macOS refuses the event tap,
/// because TCC keyed the grant to a code signature this build no longer has (a rebuild or a
/// replaced app). Before this row the only trace was a line in the unified log, so the app just
/// looked broken. Each state therefore carries the one action that actually resolves it.
struct BrightnessKeyStatusView: View {
    @ObservedObject private var keyService = BrightnessKeyService.shared

    /// Set when the reset could not be performed (no bundle id, tccutil failed to launch, or it
    /// exited non-zero). The exact command is then shown verbatim so the user is never left
    /// guessing — a silent failure here would reproduce the very problem this row fixes.
    @State private var manualCommand: String?
    /// Set after a successful reset, to point at the pane we just opened.
    @State private var didReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch keyService.interceptionState {
            case .armed, .disabled:
                EmptyView()

            case .waitingForPermission:
                Button("Open Accessibility Settings") { openAccessibilityPane() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

            case .grantedButRefused:
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                Text("macOS is refusing the keyboard tap even though the permission looks granted. That happens when Crisp was rebuilt or replaced: the old permission is recorded against the previous copy of the app. Resetting it lets you grant it again to this one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reset permission") { resetAccessibilityPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            // Both follow-ups describe work still to be done, so they clear themselves the moment
            // the tap actually arms rather than lingering as stale instructions.
            if didReset, keyService.interceptionState != .armed {
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                Text("Permission cleared. Switch Crisp back on in Privacy & Security › Accessibility — the keys arm themselves once you do, no restart.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let manualCommand, keyService.interceptionState != .armed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Could not reset it automatically. Run this in Terminal, then grant access again:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(verbatim: manualCommand)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Copy") { copyToPasteboard(manualCommand) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Presentation

    private var indicatorColor: Color {
        switch keyService.interceptionState {
        case .armed: return .green
        case .waitingForPermission: return .orange
        // Red, not orange: nothing resolves this by waiting, unlike a pending grant.
        case .grantedButRefused: return .red
        case .disabled: return .secondary
        }
    }

    private var statusText: String {
        switch keyService.interceptionState {
        case .armed:
            return String(localized: "Keys active — F1/F2 control the display under the cursor")
        case .waitingForPermission:
            return String(localized: "Waiting for Accessibility…")
        case .grantedButRefused:
            return String(localized: "Accessibility looks granted, but macOS is refusing it")
        case .disabled:
            return String(localized: "Brightness keys are off")
        }
    }

    // MARK: - Actions

    /// Clears the stale TCC record so the next grant is recorded against this build's signature.
    /// `tccutil` is the public, documented tool for exactly this; the bundle id comes from the
    /// running bundle so a renamed or re-bundled build resets its own record, never a stale
    /// hardcoded one.
    private func resetAccessibilityPermission() {
        didReset = false
        guard let bundleID = Bundle.main.bundleIdentifier else {
            // Only reachable for the bare binary (`make compile`), never for a real .app bundle.
            manualCommand = "tccutil reset Accessibility <Crisp's bundle identifier>"
            return
        }
        let command = "tccutil reset Accessibility \(bundleID)"

        Task { @MainActor in
            // Spawning and reaping a process is the one thing in this panel that can block for
            // an unbounded time (TCC database contention, disk pressure), and a stalled main
            // thread is the failure class this whole app exists to avoid — so it runs off-main
            // and only the result comes back here.
            let succeeded = await Self.resetTCCRecord(bundleID: bundleID)
            guard succeeded else {
                manualCommand = command
                return
            }

            // The reset revokes trust; the service's own watchdog tears the tap down and its
            // retry poll keeps calling tapCreate, which is what re-lists Crisp under
            // Accessibility for the user to switch on. Nothing to arm from here.
            manualCommand = nil
            didReset = true
            openAccessibilityPane()
        }
    }

    /// Runs `tccutil reset Accessibility <bundleID>` and reports whether it actually succeeded.
    ///
    /// Blocking happens on this private queue's thread only — never the main thread and never a
    /// cooperative-pool thread, which a semaphore wait would otherwise starve.
    private static func resetTCCRecord(bundleID: String) async -> Bool {
        await withCheckedContinuation { continuation in
            resetQueue.async {
                continuation.resume(returning: runTCCUtil(bundleID: bundleID))
            }
        }
    }

    /// `tccutil` edits a small local SQLite database and normally returns in milliseconds, so
    /// five seconds is several orders of magnitude of slack: past it the process is wedged, not
    /// slow. Failing then is strictly better than a row that waits forever, because the failure
    /// path shows the exact command the user can run by hand.
    private static let resetTimeout: TimeInterval = 5

    private static let resetQueue = DispatchQueue(label: "com.crisp.tccutil-reset", qos: .userInitiated)

    /// Must be called off the main thread: it blocks until `tccutil` exits or the timeout fires.
    private static func runTCCUtil(bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]

        // waitUntilExit() has no deadline, so the exit is observed through the termination
        // handler instead and the wait carries one.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return false
        }

        guard exited.wait(timeout: .now() + resetTimeout) == .success else {
            // Do not leave the child behind holding the TCC database open.
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
