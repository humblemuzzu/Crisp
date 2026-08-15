import Foundation
import AppKit
import os.log

/// The single home for per-display persistence:
/// `~/Library/Application Support/Crisp/displays.json`.
///
/// It replaces the flat `crisp.ddcState.<uuid>.<field>` /
/// `crisp.softBrightness.uuid.<uuid>` / list-of-UUIDs `UserDefaults` keys with
/// one versioned document (see `DisplayStateDocument`). The three things flat
/// keys could not do and this can: migrate atomically, carry a schema version,
/// and be pasted whole into a bug report.
///
/// Contracts that follow from AGENTS.md:
/// - keyed by `DisplayUUID`, never `CGDirectDisplayID` (rule #3), enforced by
///   the type of the API rather than by review;
/// - nothing here throws or traps at a caller. A corrupt document degrades to
///   an empty one and logs; a failed write is logged and dropped. Persistence
///   must not be able to take the app down (rule #4);
/// - no private frameworks: Foundation, AppKit's terminate notification, os.log.
///
/// Thread-safe by `NSLock`, matching `BrightnessService`/`GammaService`; callers
/// live on several threads (the brightness writer runs on its own queue, the DDC
/// feature services on the main actor).

/// The slice of `UserDefaults` the one-shot v1 migration needs.
///
/// A protocol rather than the concrete type purely so the tests can hand the
/// store an in-memory dictionary: any real `UserDefaults(suiteName:)` leaves an
/// empty plist behind in `~/Library/Preferences` after every run, and cfprefsd
/// recreates it faster than a test's tear-down can delete it.
protocol LegacyDefaults: AnyObject {
    func dictionaryRepresentation() -> [String: Any]
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: LegacyDefaults {}

final class DisplayStateStore: @unchecked Sendable {
    static let shared = DisplayStateStore()

    private static let log = Logger(subsystem: "com.crisp.app", category: "DisplayStateStore")
    private static let fileName = "displays.json"
    /// Sentinel so the v1 → v2 fold runs exactly once per install.
    private static let migrationDoneKey = "crisp.didMigrateDisplayStateV2"
    /// A brightness drag emits changes continuously; coalesce them into one
    /// write instead of hitting the disk per slider tick.
    private static let saveDebounce: TimeInterval = 0.5

    /// `~/Library/Application Support/Crisp`, also home to `SettingsService`'s
    /// JSON blobs. Owned here because this store can be the first thing to touch
    /// the folder at launch, and whoever gets there first has to perform the
    /// pre-rename `FreeDisplay` move — creating the directory before that check
    /// would strand an old install's files.
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Crisp", isDirectory: true)
        let legacy = base.appendingPathComponent("FreeDisplay", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let url: URL
    /// Guards `document` and `pendingSave`.
    private let lock = NSLock()
    /// Serializes encode-and-write so a debounced save and a terminate-time
    /// flush cannot interleave and produce a half-old file.
    private let writeLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.crisp.displaystate", qos: .utility)

    private var document: DisplayStateDocument
    private var pendingSave: DispatchWorkItem?

    /// Both dependencies are injected so `CrispTests` can exercise the I/O half — the debounce,
    /// the atomic rename, the corrupt-file degrade — against a temp directory and an in-memory
    /// defaults stand-in. Production callers use `shared` and get the real ones.
    init(directory: URL = DisplayStateStore.supportDirectory, defaults: LegacyDefaults = UserDefaults.standard) {
        url = directory.appendingPathComponent(Self.fileName)
        document = Self.read(from: url)
        migrateFromDefaultsIfNeeded(defaults)
        // Quit is the one moment a debounced write would otherwise be lost.
        // `queue: nil` posts synchronously on the terminating thread; a `.main`
        // queue hop would never get a chance to run.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
    }

    // MARK: - Reading

    /// Saved state for a display, or an all-`nil` state if nothing was ever
    /// stored for it. Never `nil`, so call sites read as `state(for:).contrast`.
    func state(for uuid: DisplayUUID) -> DisplayState {
        lock.withLock { document.displays[uuid] ?? DisplayState() }
    }

    /// The displays whose state matches `predicate` — the set-shaped settings
    /// (volume-capable, brightness-key selection) are stored as a flag per
    /// display and read back as a set here.
    func uuids(where predicate: (DisplayState) -> Bool) -> Set<DisplayUUID> {
        lock.withLock { Set(document.displays.filter { predicate($0.value) }.keys) }
    }

    // MARK: - The v3 collections
    //
    // Groups, presets and schedules are whole-list settings rather than
    // per-display ones, so they get a read property and one mutating call each
    // instead of `update(_:_:)`'s keyed form. Every mutation goes through
    // `mutateLocked`, which re-runs `DisplayStateMigration.upgraded` — that is
    // what keeps "identifiers are unique, a group lists no display twice" an
    // invariant of the stored document rather than something each caller has to
    // remember.

    var groups: [DisplayGroup] { lock.withLock { document.groups } }
    var presets: [DDCPreset] { lock.withLock { document.presets } }
    var schedules: [PresetSchedule] { lock.withLock { document.schedules } }

    func group(id: String) -> DisplayGroup? { groups.first { $0.id == id } }
    func preset(id: String) -> DDCPreset? { presets.first { $0.id == id } }

    func setGroups(_ groups: [DisplayGroup]) {
        mutate { $0.groups = groups }
    }

    func setPresets(_ presets: [DDCPreset]) {
        mutate { $0.presets = presets }
    }

    func setSchedules(_ schedules: [PresetSchedule]) {
        mutate { $0.schedules = schedules }
    }

    private func mutate(_ body: (inout DisplayStateDocument) -> Void) {
        lock.withLock {
            body(&document)
            document = DisplayStateMigration.upgraded(document)
            scheduleSaveLocked()
        }
    }

    // MARK: - Writing

    /// Mutates one display's state and schedules a debounced save.
    func update(_ uuid: DisplayUUID, _ mutate: (inout DisplayState) -> Void) {
        lock.withLock {
            var state = document.displays[uuid] ?? DisplayState()
            mutate(&state)
            store(state, for: uuid)
            scheduleSaveLocked()
        }
    }

    /// Replaces a whole membership set in one write: `uuids` get `true`, every
    /// other display has the flag cleared. Clearing to `nil` rather than `false`
    /// keeps a display that is only *not* selected from occupying an entry, the
    /// way removing it from the old `[String]` default did.
    func setMembership(_ field: WritableKeyPath<DisplayState, Bool?>, to uuids: Set<DisplayUUID>) {
        lock.withLock {
            for uuid in Set(document.displays.keys).union(uuids) {
                var state = document.displays[uuid] ?? DisplayState()
                state[keyPath: field] = uuids.contains(uuid) ? true : nil
                store(state, for: uuid)
            }
            scheduleSaveLocked()
        }
    }

    /// Writes any debounced change out now. Called on quit; safe to call at any
    /// time (a save with nothing pending just rewrites the same bytes).
    func flush() {
        lock.withLock {
            pendingSave?.cancel()
            pendingSave = nil
        }
        writeNow()
    }

    // MARK: - Migration

    /// Folds the v1 flat `UserDefaults` keys into the document, once.
    ///
    /// The legacy keys are **not** deleted: leaving them lets the user roll back
    /// to the checkpoint build with their settings intact. Deleting them is a
    /// later phase's job, once this build has some mileage.
    private func migrateFromDefaultsIfNeeded(_ defaults: LegacyDefaults) {
        guard !defaults.bool(forKey: Self.migrationDoneKey) else { return }

        var legacy: [String: LegacyDefaultsValue] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where DisplayStateMigration.isLegacyKey(key) {
            if let list = value as? [String] {
                legacy[key] = .list(list)
            } else if let number = value as? NSNumber {
                // Bools come back as NSNumber too; `DisplayStateMigration`
                // decides per key which of the two a value means.
                legacy[key] = .number(number.doubleValue)
            }
        }

        let migrated = DisplayStateMigration.migrated(legacy: legacy, into: lock.withLock { document })
        lock.withLock { document = migrated }
        // Document first, sentinel second: a crash in between re-runs a
        // migration that is idempotent, whereas the reverse order would lose
        // every legacy value.
        flush()
        defaults.set(true, forKey: Self.migrationDoneKey)
        Self.log.info("migrated \(legacy.count, privacy: .public) legacy display-state keys into displays.json")
    }

    // MARK: - Storage

    /// Must be called with `lock` held.
    private func store(_ state: DisplayState, for uuid: DisplayUUID) {
        if state.isEmpty {
            document.displays.removeValue(forKey: uuid)
        } else {
            document.displays[uuid] = state
        }
    }

    /// Must be called with `lock` held.
    private func scheduleSaveLocked() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeNow() }
        pendingSave = item
        ioQueue.asyncAfter(deadline: .now() + Self.saveDebounce, execute: item)
    }

    private static func read(from url: URL) -> DisplayStateDocument {
        // No file yet is the normal fresh-install path, not an error.
        guard let data = try? Data(contentsOf: url) else { return DisplayStateDocument() }
        let (decoded, failure) = DisplayStateDocument.decoding(data)
        // v2 → v3 on every load. Idempotent and pure, so it needs no sentinel
        // (unlike the v1 fold below, which has to read `UserDefaults`), and
        // running it unconditionally is what keeps the document's invariants
        // true even for a file someone edited by hand.
        let document = DisplayStateMigration.upgraded(decoded)
        if let failure {
            // Keep the bad bytes for diagnosis instead of silently overwriting
            // them with the empty document the next save would write.
            let quarantine = url.deletingLastPathComponent().appendingPathComponent("displays.corrupt.json")
            try? FileManager.default.removeItem(at: quarantine)
            try? FileManager.default.moveItem(at: url, to: quarantine)
            log.error("displays.json unreadable, starting empty: \(failure.localizedDescription, privacy: .public)")
        }
        return document
    }

    /// Atomic by construction: the new bytes land in a sibling temp file and
    /// then replace the document in one filesystem operation, so a crash
    /// mid-write can never leave a truncated `displays.json` behind.
    private func writeNow() {
        writeLock.lock()
        defer { writeLock.unlock() }

        let snapshot = lock.withLock { document }
        let encoder = JSONEncoder()
        // Stable, readable output: this file is meant to be pasted into a bug
        // report and diffed between runs.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // replaceItemAt needs an original to replace; the first write has
            // none. Data.write(.atomic) is itself a temp-file-plus-rename.
            guard FileManager.default.fileExists(atPath: url.path) else {
                try data.write(to: url, options: .atomic)
                return
            }
            let temp = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
            do {
                try data.write(to: temp)
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
        } catch {
            // Best-effort persistence: the in-memory state is still correct, and
            // the next change schedules another attempt.
            Self.log.error("displays.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
