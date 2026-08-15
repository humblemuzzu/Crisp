import Foundation
import CoreGraphics

/// Collects the facts `DisplayDiagnostics` renders, from the services that
/// already own them.
///
/// This file is deliberately dull. Every interesting decision — which rung a
/// display is on, what raw range a write goes through, whether an input code is
/// safe to write, whether a feature counts as supported — is made somewhere else
/// and merely *read* here. That is the whole design constraint: a diagnostic that
/// can disagree with the behaviour it describes is worse than none, and the only
/// way to guarantee it cannot is to give it no opinions of its own.
///
/// **Read-only with respect to the monitor.** It re-runs the same VCP *reads* the
/// app already makes (served from `DDCService`'s 5-second cache most of the time)
/// and writes no VCP code at all — least of all 0x60, where a wrong value costs
/// the user their screen until they walk to the monitor's buttons.
///
/// No private frameworks: Foundation, CoreGraphics and the app's own services.
@MainActor
enum DisplayDiagnosticsService {

    // MARK: - Environment

    static func environment() -> DiagnosticEnvironment {
        DiagnosticEnvironment(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: osVersionText(),
            // A model *identifier* ("Mac16,8"), shared by every unit of that model.
            // Not the machine's serial number, which this app never reads.
            macModel: sysctlString("hw.model") ?? "unknown",
            architecture: architecture,
            ddcMappingWarning: DDCService.shared.mappingWarning,
            quirksDatabaseModelCount: MonitorQuirksService.shared.database.count
        )
    }

    private static var architecture: String {
#if arch(arm64)
        // Worth reporting: the two DDC transports share nothing but the seam.
        return "arm64 (IOAVService I²C)"
#else
        return "x86_64 (IOFramebuffer I²C)"
#endif
    }

    private static func osVersionText() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        guard let build = sysctlString("kern.osversion") else { return number }
        return "\(number) (\(build))"
    }

    /// `String(cString:)` on a `[CChar]` is deprecated and this repo builds with
    /// warnings as errors (AGENTS.md §3.5), so decode the bytes explicitly.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Collection

    /// One diagnostic block per attached display, in the order the display
    /// manager lists them.
    static func collect(displays: [DisplayInfo]) async -> [DisplayDiagnostics] {
        var collected: [DisplayDiagnostics] = []
        for display in displays {
            collected.append(await diagnostics(for: display, among: displays))
        }
        return collected
    }

    static func diagnostics(for display: DisplayInfo, among displays: [DisplayInfo]) async -> DisplayDiagnostics {
        let displayID = display.displayID
        let isBuiltin = display.isBuiltin

        // The built-in panel has no I²C bus to probe; asking would only burn
        // timeouts and could not answer anything the IOKit path does not already.
        let probes = isBuiltin ? Probes.none : await probeAll(displayID)
        let ddcAvailable = BrightnessService.shared.ddcAvailability(for: displayID)
        let quirks = MonitorQuirksService.shared.quirks(
            vendor: display.vendorNumber, product: display.modelNumber
        )

        return DisplayDiagnostics(
            identity: identity(for: display),
            // Not recomputed: this is the value `BrightnessService.refreshRung`
            // published, i.e. the one the slider's badge is showing right now.
            rung: display.brightnessRung,
            ddc: await ddcStatus(for: display, ddcAvailable: ddcAvailable),
            features: features(for: display, probes: probes, ddcAvailable: ddcAvailable, quirks: quirks),
            quirkMatch: quirkMatch(quirks),
            currentInput: display.inputSourceSupported
                ? DDCFeatureService.shared.resolvedInput(display.inputSource, for: display)
                : nil,
            brightnessKeys: brightnessKeys(for: display, among: displays),
            capabilities: isBuiltin ? nil : await capabilities(for: display)
        )
    }

    // MARK: - Capabilities

    /// The monitor's capabilities string, read here and nowhere else on the
    /// app's normal paths.
    ///
    /// It is twenty-odd extra I2C transactions on the bus brightness shares, so
    /// it happens when a human opens diagnostics and not on every display
    /// refresh. Still read-only with respect to the monitor: 0xF3 asks a question
    /// and changes nothing. `DDCService` caches the answer for as long as the
    /// display stays plugged in, so re-opening the sheet costs nothing.
    private static func capabilities(for display: DisplayInfo) async -> CapabilitiesDiagnostic {
        guard let parsed = await DDCFeatureService.shared.refreshCapabilities(for: display) else {
            return .unanswered(
                reason: "the monitor did not answer the VCP 0xF3 capabilities request. That is common and "
                    + "not a fault — plenty of monitors implement VCP reads and no capabilities string at "
                    + "all — and Crisp needs it for nothing: it may only add a control, never remove one"
            )
        }
        return CapabilitiesDiagnostic(parsed)
    }

    // MARK: - Identity

    private static func identity(for display: DisplayInfo) -> DisplayIdentityDiagnostic {
        var resolution: String?
        if display.pixelWidth > 0 {
            resolution = "\(display.pixelWidth) × \(display.pixelHeight)"
            if let mode = display.currentDisplayMode {
                resolution? += " @ \(mode.refreshRateString)\(mode.isHiDPI ? ", HiDPI" : "")"
            }
        }
        return DisplayIdentityDiagnostic(
            name: display.name,
            vendor: display.vendorNumber,
            product: display.modelNumber,
            serial: display.serialNumber,
            displayUUID: display.displayUUID,
            isBuiltin: display.isBuiltin,
            isMain: display.isMain,
            resolution: resolution,
            // Left unknown on purpose. macOS exposes no public link type: on Apple
            // Silicon the IORegistry names the display node (`dispext0`) and marks
            // the DDC channel "External", but nothing there says DisplayPort vs
            // HDMI vs USB-C. Reporting "unknown" is the honest answer; inventing
            // one from the chip address or the port index would be a guess printed
            // as a fact, which is the thing this whole feature exists to avoid.
            connection: nil
        )
    }

    // MARK: - DDC status

    private static func ddcStatus(
        for display: DisplayInfo,
        ddcAvailable: Bool?
    ) async -> DDCStatusDiagnostic {
        guard !display.isBuiltin else {
            return DDCStatusDiagnostic(
                availability: .notApplicable(
                    reason: "the built-in panel's backlight is driven through IOKit, not DDC/CI over I²C"
                ),
                consecutiveReadFailures: nil,
                quarantineRemaining: nil
            )
        }

        let availability: DDCStatusDiagnostic.Availability
        switch ddcAvailable {
        case true?:
            availability = .available
        case false?:
            availability = .unavailable(
                reason: "DDC writes to this display have failed repeatedly, so Crisp has stopped aiming at the "
                    + "backlight. Usual causes: an MST hub or DisplayLink dock in the path, a Studio Display "
                    + "(USB HID, not DDC/CI), or DDC/CI switched off in the monitor's own menu"
            )
        case nil:
            availability = .unproven(
                reason: "nothing has been read from or written to this display over DDC yet. Not a failure — "
                    + "the write path still aims at DDC, and it only steps down after three consecutive failures"
            )
        }

        let health = await DDCService.shared.readHealth(displayID: display.displayID)
        return DDCStatusDiagnostic(
            availability: availability,
            consecutiveReadFailures: health.consecutiveReadFailures,
            // Captured as a duration here so the pure renderer needs no clock.
            quarantineRemaining: health.quarantinedUntil.map { $0.timeIntervalSinceNow }
        )
    }

    // MARK: - Features

    /// This run's raw reads, one per feature.
    private struct Probes {
        var brightness: RawProbe?
        var contrast: RawProbe?
        var volume: RawProbe?
        var input: RawProbe?

        static let none = Probes()
    }

    private static func probeAll(_ displayID: CGDirectDisplayID) async -> Probes {
        var probes = Probes()
        // Serially, and one attempt each: hammering every VCP code is what wedges
        // a marginal DDC controller, which is the failure this feature reports on.
        probes.brightness = await read(displayID, QuirkFeatureName.brightness.vcpCode)
        probes.contrast = await read(displayID, QuirkFeatureName.contrast.vcpCode)
        probes.volume = await read(displayID, QuirkFeatureName.volume.vcpCode)
        probes.input = await read(displayID, QuirkFeatureName.input.vcpCode)
        return probes
    }

    private static func read(_ displayID: CGDirectDisplayID, _ command: UInt8) async -> RawProbe? {
        await withCheckedContinuation { continuation in
            DDCService.shared.readAsync(displayID: displayID, command: command) { result in
                continuation.resume(returning: result.map { RawProbe(current: $0.current, max: $0.max) })
            }
        }
    }

    private static func features(
        for display: DisplayInfo,
        probes: Probes,
        ddcAvailable: Bool?,
        quirks: MonitorQuirks?
    ) -> [FeatureDiagnostic] {
        let displayID = display.displayID
        let isBuiltin = display.isBuiltin

        func evidence(app: Bool, probe: RawProbe?, answered: Bool? = nil) -> FeatureDiagnostic.Evidence {
            FeatureDiagnostic.Evidence(
                appReportsSupported: app,
                probeAnswered: answered ?? (probe.map { $0.max > 0 } ?? false),
                ddcAvailable: ddcAvailable,
                isBuiltinDisplay: isBuiltin
            )
        }

        // Brightness: `BrightnessService` denormalises through the raw maximum it
        // remembers (`ddcMaxBrightness[id] ?? 100`) rather than through the quirks
        // resolver, so the report says the same. Falling back to this run's probe
        // keeps the two in step when the service has not cached one yet.
        let brightnessMax = BrightnessService.shared.ddcBrightnessMax(for: displayID) ?? probes.brightness?.max
        let brightnessRange: ResolvedQuirk<QuirkRange>?
        if let brightnessMax, let range = QuirkRange(min: 0, max: brightnessMax) {
            brightnessRange = ResolvedQuirk(value: range, source: .probe, confidence: .verified)
        } else {
            brightnessRange = ResolvedQuirk(value: .mccsPercent, source: .standard, confidence: .reported)
        }

        return [
            FeatureDiagnostic(
                feature: .brightness,
                support: FeatureDiagnostic.resolveSupport(
                    .brightness,
                    evidence: evidence(app: ddcAvailable == true, probe: probes.brightness)
                ),
                probe: probes.brightness,
                range: isBuiltin ? nil : brightnessRange
            ),
            FeatureDiagnostic(
                feature: .contrast,
                support: FeatureDiagnostic.resolveSupport(
                    .contrast,
                    evidence: evidence(app: display.contrastSupported, probe: probes.contrast)
                ),
                probe: probes.contrast,
                // The exact call `DDCFeatureService.contrastRange` makes.
                range: isBuiltin ? nil : MonitorQuirkResolver.range(
                    .contrast, quirks: quirks, probeMax: probes.contrast?.max, standard: .mccsPercent
                )
            ),
            FeatureDiagnostic(
                feature: .volume,
                support: FeatureDiagnostic.resolveSupport(
                    .volume,
                    evidence: evidence(app: display.volumeSupported, probe: probes.volume)
                ),
                probe: probes.volume,
                // The exact call `VolumeService.volumeRange` makes.
                range: isBuiltin ? nil : MonitorQuirkResolver.range(
                    .volume, quirks: quirks, probeMax: probes.volume?.max, standard: .mccsPercent
                )
            ),
            FeatureDiagnostic(
                feature: .input,
                support: FeatureDiagnostic.resolveSupport(
                    .input,
                    evidence: evidence(
                        app: display.inputSourceSupported,
                        probe: probes.input,
                        // A monitor sitting on input code 0 with a max of 0 still
                        // answered; this is the same acceptance rule
                        // `DDCFeatureService.refreshInputSource` uses.
                        answered: probes.input.map { $0.max > 0 || $0.current > 0 } ?? false
                    )
                ),
                probe: probes.input,
                // Input is a set of codes, not a dial: it has no raw range.
                range: nil
            )
        ]
    }

    // MARK: - Quirks match

    private static func quirkMatch(_ quirks: MonitorQuirks?) -> QuirkMatchDiagnostic? {
        guard let quirks else { return nil }
        return QuirkMatchDiagnostic(
            key: quirks.key,
            vendorName: quirks.vendorName,
            modelName: quirks.modelName,
            confidence: quirks.confidence,
            fileName: vendorFileName(for: quirks.key),
            notes: quirks.notes
        )
    }

    /// Which shipped vendor file the matched entry came from.
    ///
    /// Re-read through the real decoder rather than guessed from the vendor name:
    /// `MonitorQuirksDatabase` merges files and does not keep their origin, and
    /// "benq.json because the vendor is BenQ" would be wrong the first time two
    /// files describe one vendor. Only runs when the user opens diagnostics, and
    /// the files are a few kilobytes each.
    private static func vendorFileName(for key: MonitorQuirkKey) -> String? {
        for url in MonitorQuirksService.resourceURLs(in: .main) {
            guard let data = try? Data(contentsOf: url) else { continue }
            let (file, _) = MonitorQuirksFile.decoding(data)
            guard let file, file.models.contains(where: { $0.key == key }) else { continue }
            return url.lastPathComponent
        }
        return nil
    }

    // MARK: - Brightness keys

    private static func brightnessKeys(
        for display: DisplayInfo,
        among displays: [DisplayInfo]
    ) -> BrightnessKeyDiagnostic {
        let interception: KeyInterceptionDiagnostic
        switch BrightnessKeyService.shared.interceptionState {
        case .armed: interception = .armed
        case .waitingForPermission: interception = .waitingForPermission
        case .grantedButRefused: interception = .grantedButRefused
        case .disabled: interception = .disabled
        }

        let settings = SettingsService.shared
        switch settings.brightnessKeyTarget {
        case .underCursor:
            return BrightnessKeyDiagnostic(
                interception: interception,
                targetsThisDisplay: nil,
                targetDescription: "target: follow the pointer"
            )
        case .allDisplays:
            return BrightnessKeyDiagnostic(
                interception: interception,
                targetsThisDisplay: true,
                targetDescription: "target: all connected displays"
            )
        case .selected:
            let selected = settings.brightnessKeySelectedDisplayUUIDs
            // The routing falls back to the pointer when none of the chosen
            // displays is attached, so report that rather than "does not target
            // this display" — which would be true and useless.
            guard displays.contains(where: { selected.contains($0.stateUUID) }) else {
                return BrightnessKeyDiagnostic(
                    interception: interception,
                    targetsThisDisplay: nil,
                    targetDescription: "target: selected displays only, none of which is attached, so keys fall back to the pointer"
                )
            }
            return BrightnessKeyDiagnostic(
                interception: interception,
                targetsThisDisplay: selected.contains(display.stateUUID),
                targetDescription: "target: selected displays only"
            )
        }
    }

    // MARK: - Monitor report

    /// The probe behind "report this monitor". Same reads as the diagnostics
    /// block, packaged for `QuirkEntryGenerator`; still not a single write.
    static func monitorProbe(for display: DisplayInfo) async -> MonitorProbeReport {
        let environment = environment()
        let probes = display.isBuiltin ? Probes.none : await probeAll(display.displayID)
        return MonitorProbeReport(
            vendor: display.vendorNumber,
            product: display.modelNumber,
            displayName: display.name,
            brightness: probes.brightness,
            contrast: probes.contrast,
            volume: probes.volume,
            input: probes.input,
            osVersion: environment.osVersion,
            macModel: environment.macModel,
            appVersion: environment.appVersion
        )
    }
}
