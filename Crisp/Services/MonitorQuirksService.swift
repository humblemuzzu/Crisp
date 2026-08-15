import Foundation
import os.log

/// The I/O half of the monitor quirks database: find the shipped JSON files,
/// read them, hand the bytes to `MonitorQuirks` (which owns every decision) and
/// keep the merged result.
///
/// Deliberately thin. Everything worth testing — decoding, per-entry leniency,
/// merging, resolution priority — lives in `Crisp/Models/MonitorQuirks.swift` and
/// is exercised headlessly from `CrispTests`; this file only knows where files
/// live and how to log.
///
/// Contracts that follow from AGENTS.md:
/// - a missing, unreadable or malformed file is logged and skipped, never fatal
///   (rule #4). The worst case is an empty database, which makes the app behave
///   exactly as it did before this database existed;
/// - no bundle at all is a supported configuration: `make compile` produces a
///   bare `./Crisp-bin` with no `.app` wrapper around it, so resource lookup
///   returns nothing and the app runs on MCCS defaults;
/// - no private frameworks: Foundation and os.log only.
final class MonitorQuirksService: @unchecked Sendable {
    static let shared = MonitorQuirksService()

    private static let log = Logger(subsystem: "com.crisp.app", category: "MonitorQuirks")
    /// Subdirectory inside the bundle's `Resources`, mirroring the repo layout
    /// (`Crisp/Resources/quirks/<vendor>.json`).
    private static let subdirectory = "quirks"

    private let bundle: Bundle
    private let lock = NSLock()
    /// Loaded on first query rather than at launch: the first display refresh
    /// happens milliseconds in, and this way an app that never sees an external
    /// display never touches the disk for it.
    private var loaded: MonitorQuirksDatabase?

    /// `bundle` is injected so the loader can be pointed at a test bundle; the
    /// app uses `shared` and gets `.main`.
    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// The merged database, loading it once on first use.
    var database: MonitorQuirksDatabase {
        lock.withLock {
            if let loaded { return loaded }
            let database = Self.load(from: Self.resourceURLs(in: bundle))
            loaded = database
            return database
        }
    }

    /// Quirks for one monitor, keyed on the vendor/product pair `DisplayInfo`
    /// already carries. `nil` — an unknown monitor — is the normal case.
    func quirks(vendor: UInt32, product: UInt32) -> MonitorQuirks? {
        database.quirks(vendor: vendor, product: product)
    }

    // MARK: - Loading

    /// Every vendor file in the bundle, sorted by name so the merge order (and
    /// therefore the resulting database) is identical on every launch.
    ///
    /// Three lookups, because three different things assemble this app's bundle
    /// and they do not agree on layout: Xcode (`xcodegen`, folder reference),
    /// `scripts/make-app.sh` / `scripts/release.sh` (a plain `cp -R`), and — for
    /// `make compile` — nothing at all. Anything not found simply yields no
    /// quirks, which is the same as an unknown monitor.
    static func resourceURLs(in bundle: Bundle) -> [URL] {
        var urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) ?? []
        if urls.isEmpty, let resourceURL = bundle.resourceURL {
            let directory = resourceURL.appendingPathComponent(subdirectory, isDirectory: true)
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
            urls = (contents ?? []).filter { $0.pathExtension == "json" }
        }
        if urls.isEmpty {
            // Last resort: a build that flattened the directory into `Resources`.
            // Any JSON that is not a quirks file fails to decode and is skipped,
            // so over-collecting here costs a log line, not correctness.
            urls = bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads and merges the given files. Each failure costs only its own file.
    static func load(from urls: [URL]) -> MonitorQuirksDatabase {
        guard !urls.isEmpty else {
            // Normal for `make compile`'s bare binary; nothing to warn about.
            log.debug("no quirks files found; using MCCS defaults only")
            return .empty
        }

        var files: [MonitorQuirksFile] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else {
                log.error("quirks file unreadable, skipped: \(url.lastPathComponent, privacy: .public)")
                continue
            }
            let (file, failure) = MonitorQuirksFile.decoding(data)
            guard let file else {
                log.error("""
                    quirks file malformed, skipped: \(url.lastPathComponent, privacy: .public) \
                    (\(failure?.localizedDescription ?? "unknown", privacy: .public))
                    """)
                continue
            }
            if file.schemaVersion > MonitorQuirksFile.currentSchemaVersion {
                log.info("""
                    quirks file \(url.lastPathComponent, privacy: .public) is schema \
                    v\(file.schemaVersion, privacy: .public); reading it on v\
                    \(MonitorQuirksFile.currentSchemaVersion, privacy: .public) terms
                    """)
            }
            files.append(file)
        }

        let (database, problems) = MonitorQuirksDatabase.merging(files)
        for problem in problems {
            log.error("quirks entry skipped: \(problem, privacy: .public)")
        }
        log.info("""
            loaded \(database.count, privacy: .public) monitor models from \
            \(files.count, privacy: .public) quirks file(s)
            """)
        return database
    }
}
