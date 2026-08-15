import AppKit
import ApplicationServices
import Combine
import SwiftUI

// The first-run guide: four short screens, shown once, skippable at any point.
//
// Crisp is an `LSUIElement` app, so a new user gets a menu-bar icon and no other
// signal — and its most valuable feature, F1/F2 on an external monitor, does
// nothing at all until Accessibility is granted. This fork exists because that
// exact gap cost hours (AGENTS.md §2), made worse by macOS showing the permission
// as granted while refusing it. A guide that says which permission, opens the
// pane, and then shows live whether macOS actually honoured it is the cheapest
// possible fix for the most expensive first-run failure.
//
// It owns no state of its own: the plan comes from `OnboardingPlan` (pure,
// tested headlessly), the permission truth comes from
// `BrightnessKeyService.interceptionState`, and the per-display verdicts come
// from the same `BrightnessRung` the sliders render. Nothing here can disagree
// with the app the user sees ten seconds later.

// MARK: - Model

/// Live state behind the guide: where the user is, and what is attached.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var flow: OnboardingFlow
    @Published private(set) var survey: OnboardingSurvey

    private let displayManager: DisplayManager
    private var cancellables: Set<AnyCancellable> = []
    /// Per-display subscriptions, replaced wholesale whenever the display list
    /// changes so a disconnected monitor's publisher is simply dropped.
    private var displayObservers: [AnyCancellable] = []

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
        flow = OnboardingFlow(keysAlreadyWorking: Self.keysAreWorking)
        survey = OnboardingPlan.survey(Self.facts(from: displayManager.displays))

        // The one source of truth for the permission. Observing it (rather than
        // polling `AXIsProcessTrusted` on a timer of our own) is what makes the
        // grant land in this window the moment the tap arms, and is why the guide
        // cannot claim a different permission state than the panel does.
        BrightnessKeyService.shared.$interceptionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.flow.replan(keysAlreadyWorking: state == .armed)
            }
            .store(in: &cancellables)

        displayManager.$displays
            .receive(on: DispatchQueue.main)
            .sink { [weak self] displays in
                self?.observe(displays)
                self?.refreshSurvey()
            }
            .store(in: &cancellables)
        observe(displayManager.displays)
    }

    /// Only `.armed` counts as working. `grantedButRefused` — the stale TCC record
    /// that reads as granted in System Settings — is precisely the case this guide
    /// must not skip past.
    private static var keysAreWorking: Bool {
        BrightnessKeyService.shared.interceptionState == .armed
    }

    func advance() { flow.advance() }
    func back() { flow.back() }

    /// A display's brightness rung is resolved a beat after it is discovered (the
    /// first DDC read has to come back), and it can degrade later, so follow each
    /// display's own publisher rather than sampling once at open.
    private func observe(_ displays: [DisplayInfo]) {
        displayObservers = displays.map { display in
            display.objectWillChange
                // objectWillChange fires *before* the property is updated; hopping
                // through the main queue re-reads it on the next turn, once the new
                // value is actually there.
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshSurvey() }
        }
    }

    private func refreshSurvey() {
        let fresh = OnboardingPlan.survey(Self.facts(from: displayManager.displays))
        // Rungs republish on every brightness refresh; only redraw on real change.
        if fresh != survey { survey = fresh }
    }

    /// Crisp's own virtual screens are excluded: they are something the user
    /// created inside this app, not a monitor it found, and listing them as
    /// "software dimmed only" in a first-run report reads as a fault.
    private static func facts(from displays: [DisplayInfo]) -> [OnboardingDisplayFact] {
        displays
            .filter { !VirtualDisplayService.shared.isVirtualDisplay($0.displayID) }
            .map {
                OnboardingDisplayFact(name: $0.name, isBuiltin: $0.isBuiltin, rung: $0.brightnessRung)
            }
    }
}

// MARK: - Window

/// Owns the single guide window. A second "Setup Guide" click raises the existing
/// one instead of stacking copies (the `DiagnosticsWindowController` idiom).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    /// Launch hook. Silent for everyone who has been through the guide once.
    func presentIfFirstRun(displayManager: DisplayManager) {
        guard OnboardingPlan.shouldPresentAtLaunch(
            hasCompletedOnboarding: SettingsService.shared.onboardingCompleted
        ) else { return }
        show(displayManager: displayManager)
    }

    func show(displayManager: DisplayManager) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let model = OnboardingModel(displayManager: displayManager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            // Not resizable: four fixed screens, and a guide that can be dragged
            // to 200pt wide is a guide nobody can read.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Crisp")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.finish()
        })
        window.center()
        window.delegate = self
        self.window = window

        // LSUIElement app: without an explicit activation the window opens behind
        // whatever the user was looking at — which, on a first launch, is whatever
        // they were doing when the installer finished.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Records that the guide is done and closes it.
    ///
    /// Finishing and skipping are the same outcome on purpose: the user has seen
    /// it, and an app that re-explains itself every launch until you press the
    /// right button is a nag. Reopening it stays one click away in Settings.
    func finish() {
        SettingsService.shared.onboardingCompleted = true
        window?.close()
    }

    /// Closing the window with the red button counts as skipping — same rule.
    func windowWillClose(_ notification: Notification) {
        SettingsService.shared.onboardingCompleted = true
        window = nil
    }
}

// MARK: - View

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Called for Skip and Done. The window controller owns what that means.
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    step
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 460)
    }

    @ViewBuilder
    private var step: some View {
        switch model.flow.current {
        case .whatItDoes: WhatItDoesStep()
        case .accessibility: AccessibilityStep()
        case .displays: DetectedDisplaysStep(survey: model.survey)
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Available on every screen but the last, where Done already does the
            // same thing. Nothing here blocks the app: it works (minus the keys)
            // whether or not this window is ever read.
            if !model.flow.isLast {
                Button("Skip") { onFinish() }
                    .buttonStyle(.borderless)
            }

            Spacer()

            Text("Step \(model.flow.position) of \(model.flow.count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            if !model.flow.isFirst {
                Button("Back") { model.back() }
            }
            if model.flow.isLast {
                Button("Done") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Next") { model.advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Step 1: what it does

private struct WhatItDoesStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                icon: "display",
                title: "Control your external monitor",
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                subtitle: "Crisp talks to the monitor itself over DDC/CI, the control channel built into the display cable. The controls move the monitor's own settings, exactly as its buttons would."
            )

            BulletRow(icon: "sun.max", title: "Brightness",
                      detail: "The real backlight, not a dark filter drawn over the image.")
            BulletRow(icon: "circle.lefthalf.filled", title: "Contrast",
                      detail: "The monitor's own contrast setting, when it exposes one.")
            BulletRow(icon: "speaker.wave.2", title: "Volume",
                      detail: "The monitor's built-in speakers, for the monitors that have them.")
            BulletRow(icon: "cable.connector", title: "Input source",
                      detail: "Switch which machine the monitor is showing, without reaching for its buttons.")

            // The honest footnote: what a monitor answers is the monitor's
            // business, and a guide that promises four controls on every display
            // creates the "dead control" confusion it is supposed to prevent.
            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("Every one of these depends on what your monitor answers. Crisp shows a control only for the ones it confirmed, and the next screen lists what it found.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2: accessibility

private struct AccessibilityStep: View {
    @ObservedObject private var keyService = BrightnessKeyService.shared
    /// Hides the primary button once it has done its job, so the live status row
    /// below (which carries its own, smaller "Open Accessibility Settings") is the
    /// only thing left to follow.
    @State private var didRequest = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                icon: "keyboard",
                title: "Let the brightness keys reach your monitor",
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                subtitle: "macOS sends F1 and F2 to your Mac's own screen and nowhere else. To redirect them to the monitor under the pointer, Crisp has to watch for those two keys, and macOS only allows that with Accessibility access."
            )

            // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
            Text("This is the one permission Crisp asks for, and it is only for the keys. Sliders, contrast, volume and input all work without it.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if keyService.interceptionState != .armed && !didRequest {
                Button("Grant Accessibility Access") { requestAccess() }
                    .buttonStyle(.borderedProminent)
            }

            // The live truth, from the service that owns it: green once macOS
            // actually honours the grant, and — for the case that started this
            // whole project — a one-click reset when System Settings shows the
            // permission as granted while macOS refuses it anyway.
            BrightnessKeyStatusView()

            Text("You can also turn this on later: the panel's Settings section has the same switch.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The same three calls, in the same order, as the panel's Brightness Keys
    /// toggle. Deliberately not a second flow: the prompt is what puts Crisp in
    /// the Accessibility list at all (a fresh install that has never asked is
    /// simply not there, and an empty list is where first-run time goes), and
    /// `start()` is what arms the tap and drives the status row above.
    private func requestAccess() {
        didRequest = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        BrightnessKeyService.shared.start()
    }
}

// MARK: - Step 3: what was detected

private struct DetectedDisplaysStep: View {
    let survey: OnboardingSurvey

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                icon: "sparkle.magnifyingglass",
                title: "What Crisp found",
                subtitle: headline
            )

            if survey.hasExternalDisplays {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(survey.rows.enumerated()), id: \.offset) { _, row in
                        DetectedRow(row: row)
                    }
                }
            }

            if survey.externalsAllLackDDC {
                // Said here rather than left for the user to discover as a slider
                // that dims the picture but never the panel.
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                Text("Crisp can still dim these, but by darkening the image rather than the backlight. That is usually a cable or hub in the way (DisplayLink adapters and some MST hubs carry no DDC), or DDC/CI switched off in the monitor's own menu.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !survey.hasExternalDisplays {
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                Text("Nothing is broken — plug a monitor in and its controls appear in the menu bar panel by themselves. Crisp deliberately leaves the rest of your displays alone.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The no-monitor case is a real state, not an empty list: a laptop user who
    /// installs Crisp before plugging in the dock deserves a sentence, and the
    /// sentence has to name the built-in panel rather than claim "no displays".
    private var headline: LocalizedStringKey {
        guard survey.hasExternalDisplays else {
            return survey.builtInCount > 0
                ? "Crisp controls external monitors, and right now only your Mac's own display is connected."
                : "Crisp controls external monitors, and there are none connected right now."
        }
        return "These are the monitors Crisp can see. The menu bar panel gets one section for each."
    }
}

private struct DetectedRow: View {
    let row: OnboardingDisplayRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.name)
                    .font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch row.verdict {
        case .hardwareDDC: return "checkmark.circle.fill"
        case .softwareOnly: return "exclamationmark.triangle.fill"
        case .noControl: return "xmark.circle.fill"
        // Built-in panels never become rows (OnboardingPlan.survey counts them
        // instead), so this arm exists only to keep the switch exhaustive.
        case .builtIn: return "laptopcomputer"
        }
    }

    private var color: Color {
        switch row.verdict {
        case .hardwareDDC: return .green
        case .softwareOnly: return .orange
        case .noControl: return .red
        case .builtIn: return .secondary
        }
    }

    /// Degraded displays carry the ladder's own explanation, so this screen and
    /// the slider's badge always give the same reason.
    private var detail: String {
        switch row.verdict {
        case .hardwareDDC:
            return String(localized: "DDC/CI is working — brightness moves the monitor's backlight.")
        case .softwareOnly(let reason), .noControl(let reason):
            return reason.text
        case .builtIn:
            return String(localized: "Your Mac's own display.")
        }
    }
}

// MARK: - Step 4: done

private struct DoneStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(
                icon: "checkmark.seal",
                title: "That's it",
                // swiftlint:disable:next line_length - localized literal, splitting would change its catalog key
                subtitle: "Crisp lives in the menu bar. Click the screen-and-sparkles icon to open the panel; there is no Dock icon and no window to keep track of."
            )

            BulletRow(icon: "slider.horizontal.3", title: "The panel",
                      detail: "One section per monitor, with the controls that monitor actually supports.")
            BulletRow(icon: "gearshape", title: "Settings",
                      detail: "At the bottom of the panel: brightness keys, reconnect behaviour, launch at login.")
            BulletRow(icon: "stethoscope", title: "Diagnostics",
                      detail: "Also in Settings. It explains why any control is missing, and copies a bug report.")

            Text("You can reopen this guide any time from Settings › Setup Guide.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared pieces

private struct StepHeader: View {
    let icon: String
    let title: LocalizedStringKey
    /// `LocalizedStringKey`, not `String`: a plain `String` parameter takes the
    /// literal verbatim, so every subtitle in this window would ship English-only
    /// and never appear in the catalog at all.
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BulletRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Panel entry point

/// Reopens the first-run guide from the panel's Settings section.
///
/// Support needs it (walking someone back through the permission is most of the
/// support load an app like this generates), and so does anyone who pressed Skip
/// on day one and later wonders why F1 does nothing. Styled as a normal menu row,
/// like Diagnostics, which is the other "something is unclear" entry point.
struct SetupGuideRow: View {
    @EnvironmentObject var displayManager: DisplayManager
    @State private var isHovered = false

    var body: some View {
        HStack {
            MenuItemIcon(systemName: "sparkles", color: .indigo, active: false)
            Text("Setup Guide")
                .font(.body)
            Spacer()
            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            OnboardingWindowController.shared.show(displayManager: displayManager)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("Setup Guide")
        .accessibilityHint("Opens the first-run guide: what Crisp controls, the Accessibility permission "
            + "the brightness keys need, and what it detected on your displays")
        .accessibilityAddTraits(.isButton)
    }
}
