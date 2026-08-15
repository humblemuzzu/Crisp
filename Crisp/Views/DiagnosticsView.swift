import AppKit
import SwiftUI

// The Diagnostics window: per-display facts, a copyable bug report, and a
// ready-to-submit quirks entry for the attached monitor.
//
// Why a window rather than a section in the panel. This is a menu-bar app, not a
// dashboard: the panel is for the four controls a user touches every day, and
// burying a wall of diagnostic tables in it would cost every user something to
// serve the one user with a problem. So the panel carries a single row, and the
// wall lives here.
//
// Everything shown is read-only with respect to the monitor: the window re-runs
// VCP *reads* (usually served from `DDCService`'s 5-second cache) and writes
// nothing. In particular it never writes 0x60 — input-source calibration is a
// separate, deliberate act with its own confirmation, not something a
// diagnostics screen does on your behalf.

// MARK: - Model

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var environment: DiagnosticEnvironment?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRefreshing = false
    /// Per-unit identifiers (EDID serial, display UUID) are off until asked for.
    /// See `DiagnosticReport.Privacy` for why those two and nothing else.
    @Published var includePerUnitIdentifiers = false
    /// Transient "copied" confirmation. A button that silently succeeds looks
    /// exactly like a button that silently failed.
    @Published private(set) var notice: String?

    struct Entry: Identifiable {
        let id: CGDirectDisplayID
        let display: DisplayInfo
        let diagnostics: DisplayDiagnostics
    }

    private var noticeToken = 0

    var privacy: DiagnosticReport.Privacy {
        DiagnosticReport.Privacy(includePerUnitIdentifiers: includePerUnitIdentifiers)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let displays = DisplayManagerAccessor.shared.displays
        let environment = DisplayDiagnosticsService.environment()
        let collected = await DisplayDiagnosticsService.collect(displays: displays)
        // Zip rather than index: a display can disappear mid-collection (a
        // disconnect must stay a no-op, AGENTS.md §3.4) and the two arrays would
        // no longer line up.
        self.environment = environment
        self.entries = zip(displays, collected).map {
            Entry(id: $0.displayID, display: $0, diagnostics: $1)
        }
    }

    var bugReportMarkdown: String {
        DiagnosticReport.markdown(
            environment: environment ?? DisplayDiagnosticsService.environment(),
            displays: entries.map(\.diagnostics),
            privacy: privacy
        )
    }

    func copyBugReport() {
        copy(bugReportMarkdown, notice: String(localized: "Bug report copied to the clipboard."))
    }

    /// The quirks entry plus the issue body, as one paste.
    func copyMonitorReport(for entry: Entry) async {
        let probe = await DisplayDiagnosticsService.monitorProbe(for: entry.display)
        do {
            let json = try QuirkEntryGenerator.json(for: probe)
            copy(
                QuirkEntryGenerator.issueBody(for: probe, json: json),
                notice: String(localized: "Monitor report copied — paste it into a new issue or pull request.")
            )
        } catch {
            // Cannot happen for a tree of strings and integers, but a button that
            // does nothing must still say so.
            copy("", notice: String(localized: "Could not generate the monitor report."))
        }
    }

    private func copy(_ text: String, notice: String) {
        if !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        self.notice = notice
        noticeToken &+= 1
        let token = noticeToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Only clear our own notice: a second copy while this one is waiting
            // must not have its confirmation wiped by the first one's timer.
            if self.noticeToken == token { self.notice = nil }
        }
    }
}

// MARK: - Window

/// Owns the single Diagnostics window. A second "Diagnostics" click raises the
/// existing one instead of stacking copies.
@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    static let shared = DiagnosticsWindowController()

    private var window: NSWindow?
    private let model = DiagnosticsModel()

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            Task { await model.refresh() }
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Crisp Diagnostics")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 400)
        window.contentView = NSHostingView(rootView: DiagnosticsView(model: model))
        window.center()
        window.delegate = self
        self.window = window

        // LSUIElement app: without an explicit activation the window opens behind
        // whatever the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Task { await model.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - View

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let environment = model.environment {
                        EnvironmentCard(environment: environment)
                    }
                    ForEach(model.entries) { entry in
                        DisplayDiagnosticsCard(
                            diagnostics: entry.diagnostics,
                            privacy: model.privacy
                        ) {
                            Task { await model.copyMonitorReport(for: entry) }
                        }
                    }
                    if model.entries.isEmpty && !model.isRefreshing {
                        Text("No displays are attached.")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 400)
        // Re-collect when a display is plugged, unplugged or reconfigured. A
        // diagnostic that quietly goes stale is the thing this feature exists to
        // replace, and a disconnect is exactly when someone is looking at it.
        // `refresh()` is re-entrancy-guarded, so a reconnect storm coalesces.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $model.includePerUnitIdentifiers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include per-unit display identifiers")
                    // The one place the app asks for something identifying, so it
                    // says what it is for instead of leaving the user to guess.
                    // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                    Text("Adds this monitor's EDID serial number and display UUID. They identify one physical unit, so leave this off unless a maintainer asks: they are only needed for two identical monitors whose controls get swapped, or for settings that do not survive a reconnect. Crisp never collects your Mac's serial number, user name or host name.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Button("Copy Bug Report") { model.copyBugReport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.entries.isEmpty)
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let notice = model.notice {
                    Text(verbatim: notice)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Cards

private struct DiagnosticsCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.headline)
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// One label/value line. Values are `verbatim`: they are diagnostic text built by
/// the model, never a catalog key, and a monitor name like "%s" would otherwise
/// be read as a format specifier.
private struct DiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(verbatim: value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EnvironmentCard: View {
    let environment: DiagnosticEnvironment

    var body: some View {
        DiagnosticsCard(title: "This Mac") {
            VStack(alignment: .leading, spacing: 4) {
                DiagnosticRow(label: "Crisp", value: "\(environment.appVersion) (\(environment.appBuild))")
                DiagnosticRow(label: "macOS", value: environment.osVersion)
                DiagnosticRow(label: "Mac model", value: environment.macModel)
                DiagnosticRow(label: "DDC transport", value: environment.architecture)
                DiagnosticRow(
                    label: "Quirks database",
                    value: "\(environment.quirksDatabaseModelCount) monitor model(s) loaded"
                )
                if let warning = environment.ddcMappingWarning {
                    DiagnosticRow(label: "Channel mapping", value: warning)
                }
            }
        }
    }
}

private struct DisplayDiagnosticsCard: View {
    let diagnostics: DisplayDiagnostics
    let privacy: DiagnosticReport.Privacy
    let onReportMonitor: () -> Void

    var body: some View {
        DiagnosticsCard(
            title: diagnostics.identity.name,
            subtitle: diagnostics.identity.isBuiltin ? "Built-in panel" : "External monitor"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                DiagnosticRow(label: "Vendor / product", value: diagnostics.identity.vendorProductText)
                DiagnosticRow(label: "EDID serial", value: perUnit(String(diagnostics.identity.serial)))
                DiagnosticRow(label: "Display UUID", value: perUnit(diagnostics.identity.displayUUID))
                DiagnosticRow(
                    label: "Connection",
                    value: diagnostics.identity.connection
                        ?? "unknown — macOS exposes no public link type for this display"
                )
                DiagnosticRow(
                    label: "Resolution",
                    value: diagnostics.identity.resolution ?? "unknown — macOS reported no current mode"
                )
                DiagnosticRow(label: "Brightness path", value: diagnostics.rung.reportDescription)
                DiagnosticRow(label: "DDC", value: diagnostics.ddc.availability.reportText)
                DiagnosticRow(label: "Read quarantine", value: diagnostics.ddc.quarantineReportText)
                DiagnosticRow(
                    label: "Quirks entry",
                    value: diagnostics.quirkMatch?.reportText
                        ?? "none — no contributed entry for this vendor/product, so MCCS defaults are in use"
                )
                if let input = diagnostics.currentInput {
                    DiagnosticRow(
                        label: "Current input",
                        value: "\(input.code) → \(input.displayLabel) "
                            + "(label from \(input.labelSource.reportName), \(input.labelConfidence.rawValue))"
                    )
                }
                DiagnosticRow(label: "Brightness keys", value: diagnostics.brightnessKeys.reportText)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(diagnostics.features, id: \.feature) { feature in
                    FeatureRow(feature: feature)
                }
            }

            HStack {
                Spacer()
                Button("Copy Monitor Report", action: onReportMonitor)
                    .controlSize(.small)
            }
        }
    }

    private func perUnit(_ value: String) -> String {
        privacy.includePerUnitIdentifiers ? value : "hidden — see the checkbox below"
    }
}

private struct FeatureRow: View {
    let feature: FeatureDiagnostic

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(verbatim: "\(feature.feature.reportName) (VCP \(feature.feature.vcpText))")
                    .font(.caption.weight(.semibold))
                    .frame(width: 170, alignment: .leading)
                Text(verbatim: feature.support.reportText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if feature.support.isSupported {
                Text(verbatim: "raw \(feature.probe?.reportText ?? "no answer this pass") · "
                    + "range \(feature.rangeReportText) from \(feature.rangeSourceReportText)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 14)
            }
        }
    }

    private var indicatorColor: Color {
        switch feature.support {
        case .supported: return .green
        // Orange, not red: unknown is a question, not a fault.
        case .unknown: return .orange
        case .unsupported: return .red
        case .notApplicable: return .secondary
        }
    }
}
