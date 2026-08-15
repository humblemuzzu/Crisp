import Foundation
import os.log

/// Named DDC snapshots: the stored list, the CRUD the panel drives, and applying
/// one.
///
/// **Nothing about what a preset may contain is decided here.** `DDCPreset` has
/// no field for an input source, and `DDCPresetPlan.features` is the list of what
/// a preset may carry — asserted against the registry in `DDCPresetTests`, so
/// giving presets a destructive feature fails the suite rather than shipping. The
/// argument for that boundary is written out in `DDCPreset`'s own header.
///
/// **Applying goes through `AutomationService`, not straight to the transport.**
/// Every step becomes an `AutomationRequest` and is planned by the same
/// `AutomationRequest.plan` a `crisp://` URL goes through, which means:
///
///   - a display that is not attached is a no-op for that display, with a
///     reason, and the rest of the preset still applies;
///   - values are clamped once, in the layer that already owns clamping;
///   - and if a future edit ever did put a destructive feature in a preset, its
///     plan could only come back `needsConfirmation` — there is no origin, flag
///     or preference that turns it into `ready`. A preset cannot become a way
///     around the one dialog.
///
/// No private frameworks: `AutomationService` reaches the monitor through the
/// same `BrightnessService` / `DDCFeatureService` / `VolumeService` calls the
/// panel's own sliders use.
@MainActor
final class DDCPresetService: ObservableObject {
    static let shared = DDCPresetService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "DDCPresetService")

    /// The stored presets, republished for SwiftUI. The store is the source of
    /// truth; this is written through on every mutation.
    @Published private(set) var presets: [DDCPreset] = []
    /// The preset currently being applied, for a spinner. `nil` between runs.
    @Published private(set) var applyingID: String?

    private var store: DisplayStateStore { .shared }

    private init() {
        presets = store.presets
    }

    // MARK: - What one run did

    struct Outcome: Equatable, Sendable {
        /// Writes that reached a service.
        let applied: Int
        /// Steps that did not, each with the reason the plan or the gate gave.
        let refused: [String]
        /// Displays the preset names that are not attached right now. Not a
        /// failure — a preset outlives the desk it was captured on.
        let missingDisplays: [DisplayUUID]

        var didAnything: Bool { applied > 0 }
    }

    // MARK: - CRUD

    /// Captures the current DDC state of the given displays as a new preset.
    ///
    /// A display contributes only the controls it has actually answered a read
    /// for: writing a contrast a monitor never reported would be a value the app
    /// invented, and `DDCFeatureDiscovery` would refuse it at the wire anyway.
    @discardableResult
    func capture(name: String, from displays: [DisplayInfo]) -> DDCPreset {
        var settings: [DisplayUUID: DDCPresetSettings] = [:]
        for display in displays where !display.isBuiltin {
            var entry = DDCPresetSettings(brightness: min(display.brightness, 100))
            if display.contrastSupported { entry.contrast = display.contrast }
            if display.volumeSupported { entry.volume = display.volume }
            settings[display.stateUUID] = entry
        }
        let preset = DDCPreset(name: name, settings: settings).normalized()
        write(presets + [preset])
        return preset
    }

    func rename(_ id: String, to name: String) {
        write(presets.map { preset in
            guard preset.id == id else { return preset }
            var copy = preset
            copy.name = name
            return copy
        })
    }

    func delete(_ id: String) {
        write(presets.filter { $0.id != id })
        // A schedule pointing at a deleted preset is left alone deliberately: it
        // applies nothing and says so, and deleting it would throw away a time
        // the user chose because they deleted a preset they may re-create.
    }

    /// Overwrites a preset's values with what its displays are on now, keeping
    /// its name and identity — so a `crisp://preset/<id>` link that is already in
    /// a shortcut keeps working.
    func update(_ id: String, from displays: [DisplayInfo]) {
        guard let existing = presets.first(where: { $0.id == id }) else { return }
        let recaptured = capturedSettings(for: existing, from: displays)
        write(presets.map { preset in
            guard preset.id == id else { return preset }
            var copy = preset
            copy.settings = recaptured
            return copy
        })
    }

    /// Re-reads only the displays the preset already names *and* that are
    /// attached. An unplugged monitor keeps its stored values rather than being
    /// dropped from the preset, which is the difference between "save current
    /// as…" and "forget the desk I am not at".
    private func capturedSettings(
        for preset: DDCPreset, from displays: [DisplayInfo]
    ) -> [DisplayUUID: DDCPresetSettings] {
        var settings = preset.settings
        for display in displays where settings[display.stateUUID] != nil {
            var entry = DDCPresetSettings(brightness: min(display.brightness, 100))
            if display.contrastSupported { entry.contrast = display.contrast }
            if display.volumeSupported { entry.volume = display.volume }
            settings[display.stateUUID] = entry
        }
        return settings
    }

    // MARK: - Applying

    @discardableResult
    func apply(id: String, origin: AutomationOrigin) async -> Outcome {
        guard let preset = presets.first(where: { $0.id == id }) else {
            return Outcome(applied: 0, refused: ["no preset has the identifier \(id)"], missingDisplays: [])
        }
        return await apply(preset, origin: origin)
    }

    @discardableResult
    func apply(_ preset: DDCPreset, origin: AutomationOrigin) async -> Outcome {
        let attached = Set(AutomationService.shared.displays.map(\.stateUUID))
        let steps = DDCPresetPlan.steps(for: preset, attached: attached)
        let missing = DDCPresetPlan.missingDisplays(for: preset, attached: attached)

        applyingID = preset.id
        defer { applyingID = nil }

        var applied = 0
        var refused: [String] = []
        for step in steps {
            let request = AutomationRequest(
                origin: origin, display: step.display,
                feature: step.feature, value: .percent(step.percent)
            )
            let outcome = await AutomationService.shared.perform(request)
            if outcome.didApply { applied += 1 } else { refused.append(outcome.message) }
        }

        // One interpolated literal: an OSLog message cannot be assembled from
        // two, and splitting it would silently degrade to a runtime format.
        Self.log.info("preset '\(preset.name, privacy: .public)' applied \(applied, privacy: .public) of \(steps.count, privacy: .public) settings, \(missing.count, privacy: .public) display(s) not connected")
        return Outcome(applied: applied, refused: refused, missingDisplays: missing)
    }

    // MARK: - Plumbing

    private func write(_ presets: [DDCPreset]) {
        store.setPresets(presets.map { $0.normalized() })
        self.presets = store.presets
    }
}
