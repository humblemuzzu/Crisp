import Foundation
import CoreGraphics
import AppKit
import os.log

/// Wires the input-source calibration wizard to the world: the DDC writes, the
/// countdown that survives the screen going black, and the disk.
///
/// Every *decision* lives elsewhere and is tested headlessly —
/// `InputCalibration` (the state machine) and `InputCalibrationDriver` (the glue
/// around it: close requests, recovery ownership, in-flight restores). What is
/// left here is the part that genuinely cannot be pure: a `DispatchSourceTimer`,
/// `DDCService`'s I2C, `DisplayStateStore`'s file, `DisplayManagerAccessor`'s
/// display list, and the `@Published` mirrors SwiftUI observes.
///
/// Two implementation choices carry the whole safety story:
///
/// **The countdown is a `DispatchSourceTimer`, not a `Timer`.** A `Timer` is
/// attached to a run-loop mode, and the modes it is not in are exactly the ones
/// that happen when a user is confused: a tracking menu, a modal sheet, a window
/// drag. A dispatch source has no notion of run-loop modes at all, so the revert
/// cannot be starved by whatever the UI is doing — and the wizard shows no modal
/// alert for the same reason.
///
/// **The deadline is absolute.** The timer only *delivers* ticks; the pure state
/// machine compares `Date()` against a stored deadline. A tick that arrives four
/// seconds late still reverts on arrival, rather than resetting a counter.
///
/// No private frameworks: Foundation, CoreGraphics, AppKit's screen notification,
/// os.log, and `DDCService`'s IOKit-only path (AGENTS.md §3.1).
@MainActor
final class InputCalibrationService: ObservableObject {
    static let shared = InputCalibrationService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "InputCalibration")

    /// VCP 0x60. Spelled here rather than imported so the one register this
    /// service is allowed to write is visible in the file that writes it.
    private static let inputSourceVCP: UInt8 = 0x60

    /// The live session, or `nil` when the wizard is closed.
    @Published private(set) var session: InputCalibrationSession?
    /// Whole seconds left on the countdown, for display only. Nothing decides
    /// anything from this: the deadline in the session is the truth.
    @Published private(set) var secondsRemaining: Int = 0
    /// Why the last trial ended, so the wizard can say "that port showed nothing"
    /// instead of silently returning to the list.
    @Published private(set) var lastRevert: InputCalibrationRevertReason?

    /// Codes tried and reverted this session — reported to the contributor as
    /// context, never written into a quirks entry (a dead port on this desk is
    /// evidence about the cabling, not about the model).
    @Published private(set) var revertedCodes: [UInt16] = []

    private let driver: InputCalibrationDriver

    private var store: DisplayStateStore { .shared }

    private init() {
        // A local, not a stored property: the environment's tick closures own it,
        // and capturing `self.ticker` here would be a `self` access before every
        // stored property is initialised.
        let ticker = InputCalibrationTicker()
        driver = InputCalibrationDriver(environment: InputCalibrationEnvironment(
            now: Date.init,
            displayID: { uuid in
                // Looked up fresh every time, never a stored `CGDirectDisplayID`:
                // macOS reassigns IDs across a reconnect (AGENTS.md §3.3), and a
                // session that outlives one would otherwise write this monitor's
                // input code into a different panel.
                MainActor.assumeIsolated {
                    DisplayManagerAccessor.shared.displays.first { $0.stateUUID == uuid }?.displayID
                }
            },
            writeInputSource: { displayID, code, completion in
                DDCService.shared.writeAsync(
                    displayID: displayID, command: Self.inputSourceVCP, value: code
                ) { acked in
                    Task { @MainActor in completion(acked) }
                }
            },
            noteInputSource: { uuid, code in
                MainActor.assumeIsolated {
                    DisplayManagerAccessor.shared.displays
                        .first { $0.stateUUID == uuid }?
                        .inputSource = code
                }
            },
            pendingRecord: { uuid in
                DisplayStateStore.shared.state(for: uuid).pendingInputCalibration
            },
            writePendingRecord: { uuid, pending in
                // Persist-and-flush, synchronously, before the write it protects.
                // `DisplayStateStore` debounces saves by half a second, which is
                // the right trade for a slider drag and the wrong one for this:
                // the whole point of the record is to survive a process that dies
                // in the next instant.
                DisplayStateStore.shared.update(uuid) { $0.pendingInputCalibration = pending }
                DisplayStateStore.shared.flush()
            },
            appendConfirmedInput: { uuid, entry in
                DisplayStateStore.shared.update(uuid) { state in
                    var entries = state.calibratedInputs ?? []
                    entries.removeAll { $0.code == entry.code }
                    entries.append(entry)
                    state.calibratedInputs = entries.sorted { $0.code < $1.code }
                }
                DisplayStateStore.shared.flush()
            },
            startTicking: { interval, tick in ticker.start(interval: interval, tick: tick) },
            stopTicking: { ticker.stop() },
            log: { message in Self.log.info("\(message, privacy: .public)") }
        ))
        driver.onChange = { [weak self] in self?.republish() }

        // A display vanishing mid-trial is a real case, not a theoretical one:
        // the wizard is used precisely when cables are being moved around.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.driver.checkDisplayStillAttached() }
        }
    }

    /// Mirrors the driver's state onto the `@Published` properties SwiftUI reads.
    private func republish() {
        session = driver.session
        secondsRemaining = driver.secondsRemaining
        lastRevert = driver.lastRevert
        revertedCodes = driver.revertedCodes
    }

    // MARK: - Session lifecycle

    /// Opens a session for `display`, or returns `false` if it cannot be started.
    ///
    /// It requires a *successful* live read of 0x60 (`inputSourceSupported`),
    /// because the original code is the entire safety net: without knowing what
    /// the monitor is on, there is nothing to revert to and the wizard must not
    /// run at all. The rest of the refusals (a session already open, a recovery
    /// restore in flight, an unresolved pending record) are the driver's.
    @discardableResult
    func begin(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltin, display.inputSourceSupported else { return false }

        let uuid = display.stateUUID
        let quirks = MonitorQuirksService.shared.quirks(
            vendor: display.vendorNumber, product: display.modelNumber
        )
        return driver.begin(
            uuid: uuid,
            originalCode: display.inputSource,
            candidates: InputCalibrationPlan.candidates(
                quirks: quirks,
                currentInput: display.inputSource,
                calibrated: calibratedLabels(for: uuid)
            )
        )
    }

    var isCalibrating: Bool { driver.isCalibrating }

    func isCalibrating(_ uuid: DisplayUUID) -> Bool { driver.isCalibrating(uuid) }

    // MARK: - User actions

    func test(_ code: UInt16) { driver.test(code) }
    func keep() { driver.keep() }
    func revertNow() { driver.revertNow() }
    func name(_ label: String) { driver.name(label) }

    /// Closes the wizard. Mid-trial this reverts first — a window close is not
    /// permission to leave an unconfirmed code on the panel.
    func close() { driver.close() }

    // MARK: - Recovery

    /// Repairs a calibration that never finished. Called from
    /// `DDCFeatureService.refreshInputSource`, which runs at launch and on every
    /// reconnect — the two moments a stranded monitor can be reached again.
    ///
    /// - Parameter currentInput: what the 0x60 read answered, or `nil` if it
    ///   failed. Both are handled; see `InputCalibrationRecovery.decide`.
    func restoreIfInterrupted(for display: DisplayInfo, currentInput: UInt16?) {
        driver.restoreIfInterrupted(
            uuid: display.stateUUID, displayID: display.displayID, currentInput: currentInput
        )
    }

    // MARK: - Results

    /// Codes this user has confirmed on this display, code → port name. Feeds
    /// `MonitorQuirkResolver.input`'s top tier.
    func calibratedLabels(for uuid: DisplayUUID) -> [UInt16: String] {
        let entries = store.state(for: uuid).calibratedInputs ?? []
        return Dictionary(entries.map { ($0.code, $0.label) }, uniquingKeysWith: { _, latest in latest })
    }

    func calibratedInputs(for uuid: DisplayUUID) -> [CalibratedInput] {
        (store.state(for: uuid).calibratedInputs ?? []).sorted { $0.code < $1.code }
    }

    /// The contribution artifact for a finished session.
    func report(for display: DisplayInfo) -> InputCalibrationReport.Subject {
        let environment = DisplayDiagnosticsService.environment()
        return InputCalibrationReport.Subject(
            vendor: display.vendorNumber,
            product: display.modelNumber,
            displayName: display.name,
            confirmed: calibratedInputs(for: display.stateUUID),
            reverted: revertedCodes,
            osVersion: environment.osVersion,
            macModel: environment.macModel,
            appVersion: environment.appVersion
        )
    }
}

/// The countdown's tick source: a `DispatchSourceTimer` that delivers on the main
/// actor. Split out of the service so `InputCalibrationDriver` can be handed a
/// tick source it controls and the whole countdown can be driven in tests without
/// waiting on wall time.
@MainActor
private final class InputCalibrationTicker {
    private let queue = DispatchQueue(label: "com.crisp.inputcalibration", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    func start(interval: TimeInterval, tick: @escaping () -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        timer.setEventHandler { Task { @MainActor in tick() } }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
