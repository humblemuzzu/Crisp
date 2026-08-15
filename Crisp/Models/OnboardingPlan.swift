import Foundation

// The first-run guide's decision core: which screens it shows, what the attached
// displays mean, and when it is done with the user.
//
// Why this exists at all. Crisp is an `LSUIElement` app whose most valuable
// feature — F1/F2 on an external monitor — does nothing until Accessibility is
// granted, and this fork started with hours lost to exactly that (AGENTS.md §2:
// System Settings showed the toggle ON while macOS refused the tap). A new user
// who is handed a menu-bar icon and no explanation repeats that afternoon.
//
// Two rules shape the file:
//
//  1. **It decides, it does not act.** No permission is read, requested or
//     cached here: the guide is handed `keysAlreadyWorking`, which the view
//     derives from the one publisher that already owns that fact
//     (`BrightnessKeyService.interceptionState`). A second permission flow that
//     can disagree with the first is worse than no guide.
//  2. **The step the user is reading is never yanked away.** Granting access
//     mid-flow satisfies the accessibility step, and a plan that simply
//     recomputed itself would delete the screen under the cursor. `keeping:`
//     is that guarantee, and it is why re-planning is a function rather than a
//     re-initialisation.
//
// Pure Foundation, so it compiles into the headless `CrispTests` target the same
// way `BrightnessRung` does (AGENTS.md §3.6). The window, the prose and the
// permission button live in `Crisp/Views/OnboardingView.swift`.

// MARK: - Steps

/// One screen of the first-run guide.
///
/// Four, deliberately: what the app does, the one permission that is not optional
/// if you want the keys, what Crisp actually found attached, and where the app
/// lives from now on. Anything longer is a product tour, and a product tour is
/// skipped — which would take the accessibility screen with it.
enum OnboardingStep: String, Equatable, CaseIterable, Sendable {
    /// Hardware brightness / contrast / volume / input over DDC, for externals.
    case whatItDoes
    /// The Accessibility grant the brightness keys need.
    case accessibility
    /// What was detected, including displays Crisp cannot drive over DDC.
    case displays
    /// Menu-bar icon, where settings live, how to reopen this guide.
    case done
}

// MARK: - Displays

/// What one attached display means for the "what was detected" screen.
///
/// Derived from `BrightnessRung`, which is already the app's single answer to
/// "what is actually dimming this display" — so a monitor listed here as software
/// dimmed is precisely one whose slider will move the GPU colour table later. The
/// alternative, re-deciding DDC support from raw IOKit facts, would be a second
/// source of truth that can disagree with the slider the user sees ten seconds on.
enum OnboardingDisplayVerdict: Equatable, Sendable {
    /// The Mac's own panel. macOS already owns its keys and its backlight; Crisp
    /// is not what makes it work, so the guide never counts it as a monitor.
    case builtIn
    /// An external monitor whose real backlight Crisp drives over DDC/CI. The
    /// case this app exists for.
    case hardwareDDC
    /// An external monitor with no usable DDC channel: dimming falls back to the
    /// GPU colour table or a black overlay. Said here, on day one, rather than
    /// left for the user to infer from a control that never brightens the panel.
    case softwareOnly(BrightnessRung.Reason)
    /// Nothing can dim this display at all.
    case noControl(BrightnessRung.Reason)
}

/// The facts one display contributes to the guide. Every field is copied from
/// `DisplayInfo`; nothing is computed here that the app does not already know.
struct OnboardingDisplayFact: Equatable, Sendable {
    let name: String
    let isBuiltin: Bool
    let rung: BrightnessRung

    /// Defaults describe a plain external monitor with a working DDC channel, so
    /// a test (or a call site) states only the field it cares about.
    init(name: String, isBuiltin: Bool = false, rung: BrightnessRung = .ddcHardware) {
        self.name = name
        self.isBuiltin = isBuiltin
        self.rung = rung
    }
}

/// One row of the "what was detected" screen.
struct OnboardingDisplayRow: Equatable, Sendable {
    let name: String
    let verdict: OnboardingDisplayVerdict
}

/// The detection screen's whole content, decided in one place.
struct OnboardingSurvey: Equatable, Sendable {
    /// External monitors only, in the order they were given. The built-in panel
    /// is not a row: listing it invites "why is there no DDC on my MacBook".
    let rows: [OnboardingDisplayRow]
    /// Built-in panels seen. Counted, not listed, so the no-monitor screen can
    /// say "only your Mac's own display" instead of "no displays", which would
    /// be false.
    let builtInCount: Int

    var externalCount: Int { rows.count }

    /// The laptop-user case: Crisp installed before the dock is plugged in. It
    /// is a real state, not an error, and it gets said plainly rather than
    /// rendered as an empty setup screen.
    var hasExternalDisplays: Bool { !rows.isEmpty }

    /// Externals Crisp can drive over DDC right now.
    var hardwareCount: Int {
        rows.filter { $0.verdict == .hardwareDDC }.count
    }

    /// At least one external is attached and not one of them has a DDC channel.
    /// Guarded on `hasExternalDisplays` on purpose: with no monitors at all the
    /// "none of them work" phrasing would be vacuously true and badly wrong.
    var externalsAllLackDDC: Bool {
        hasExternalDisplays && hardwareCount == 0
    }
}

// MARK: - Plan

enum OnboardingPlan {
    /// The screens in the only order they make sense in. The plan filters this
    /// list; it never builds a different one, so a step cannot silently move.
    static let canonicalOrder: [OnboardingStep] = [.whatItDoes, .accessibility, .displays, .done]

    /// Whether the guide opens itself at launch.
    ///
    /// One app-level flag, deliberately not per-display: the guide is about the
    /// app and one system permission, and a user who plugs in a second monitor
    /// has not become a new user. Re-opening it later is a menu action, not an
    /// automatic event — an app that re-explains itself is a nag.
    static func shouldPresentAtLaunch(hasCompletedOnboarding: Bool) -> Bool {
        !hasCompletedOnboarding
    }

    /// The screens to show.
    ///
    /// - Parameters:
    ///   - keysAlreadyWorking: the brightness-key tap is armed, i.e. Accessibility
    ///     is granted *and* macOS honours it. Only `.armed` counts: the
    ///     `grantedButRefused` state (a stale TCC record from an earlier signature)
    ///     looks granted in System Settings and is exactly the failure this guide
    ///     exists to shorten, so it must keep its screen.
    ///   - keeping: a step to include even when the rule above would drop it —
    ///     the screen the user is currently reading.
    static func steps(keysAlreadyWorking: Bool, keeping: OnboardingStep? = nil) -> [OnboardingStep] {
        canonicalOrder.filter { step in
            if step == keeping { return true }
            switch step {
            case .accessibility: return !keysAlreadyWorking
            case .whatItDoes, .displays, .done: return true
            }
        }
    }

    /// One display's meaning for the detection screen.
    ///
    /// Built-in first and unconditionally: `BrightnessRung.resolve` reports the
    /// built-in panel as `.ddcHardware` (its IOKit backlight really is hardware),
    /// and counting that as a DDC monitor would let the guide congratulate a
    /// lidded MacBook with nothing plugged in.
    static func verdict(for fact: OnboardingDisplayFact) -> OnboardingDisplayVerdict {
        if fact.isBuiltin { return .builtIn }
        switch fact.rung {
        // A TV over the network is grouped with DDC rather than with the
        // software rungs, because the guide's question is "can Crisp move this
        // screen's actual backlight?" and for a paired LG the answer is yes.
        case .ddcHardware, .tvNetwork: return .hardwareDDC
        case .gammaTable(let reason), .overlay(let reason): return .softwareOnly(reason)
        case .unavailable(let reason): return .noControl(reason)
        }
    }

    /// The detection screen's content for the currently attached displays.
    static func survey(_ facts: [OnboardingDisplayFact]) -> OnboardingSurvey {
        var rows: [OnboardingDisplayRow] = []
        var builtIns = 0
        for fact in facts {
            let verdict = verdict(for: fact)
            if verdict == .builtIn {
                builtIns += 1
                continue
            }
            rows.append(OnboardingDisplayRow(name: fact.name, verdict: verdict))
        }
        return OnboardingSurvey(rows: rows, builtInCount: builtIns)
    }
}

// MARK: - Flow

/// Where the user is in the guide, as a value.
///
/// A struct rather than view state because "can I go forward", "am I on the last
/// screen" and "what happens when the permission lands while I am reading about
/// it" are decisions, and decisions in a SwiftUI body are decisions nobody tests.
struct OnboardingFlow: Equatable, Sendable {
    private(set) var steps: [OnboardingStep]
    private(set) var index: Int

    /// An empty plan would mean a window with nothing in it and no way out, so
    /// the flow degrades to the closing screen instead. Not reachable from
    /// `OnboardingPlan.steps` today; cheap insurance against a future filter.
    init(steps: [OnboardingStep]) {
        self.steps = steps.isEmpty ? [.done] : steps
        self.index = 0
    }

    init(keysAlreadyWorking: Bool) {
        self.init(steps: OnboardingPlan.steps(keysAlreadyWorking: keysAlreadyWorking))
    }

    var current: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    /// 1-based position, for the "2 of 4" dots.
    var position: Int { index + 1 }
    var count: Int { steps.count }

    mutating func advance() {
        index = min(index + 1, steps.count - 1)
    }

    mutating func back() {
        index = max(index - 1, 0)
    }

    /// Re-plans around a fact that changed while the guide is open — in practice,
    /// Accessibility being granted on the screen that asks for it.
    ///
    /// The user stays on the screen they are reading (`keeping:`), so the grant
    /// shows up as the status line turning green under them rather than as the
    /// window jumping a page. Every other screen is re-planned normally, so a
    /// grant that lands one screen early still removes the step the user has not
    /// reached yet.
    mutating func replan(keysAlreadyWorking: Bool) {
        let current = self.current
        steps = OnboardingPlan.steps(keysAlreadyWorking: keysAlreadyWorking, keeping: current)
        // `keeping:` guarantees the current step survived the filter; the fallback
        // is there so a future filter change cannot produce an out-of-range index.
        index = steps.firstIndex(of: current) ?? 0
    }
}
