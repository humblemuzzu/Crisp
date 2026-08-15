import Foundation

/// The monitor quirks database: what real monitors *do*, as opposed to what the
/// VESA MCCS standard says they should do.
///
/// Why this exists at all. Monitors deviate from MCCS constantly and the
/// monitor's own capabilities string (DDC/CI command 0xF3) is not a fix: ddcutil
/// reads it and then deliberately ignores it for command formulation, because
/// "the only way to know for sure is by testing using getvcp and setvcp".
/// Documented deviations that motivated the format:
///
/// - Samsung U32H750 advertises input codes 0x11/0x12/0x0F but really uses
///   0x05/0x06/0x0F — an advertised code that switches the panel to a dead port.
/// - Iiyama PL2492H reverts every write unless a "save current settings" command
///   follows it.
/// - LG 27MU67 accepts a brightness write and then undoes it about a second later.
/// - Dell 2407wfp cannot go below raw brightness 30; its usable range is 30–50.
/// - Several monitors never set the "unsupported feature" reply bit, so probing
///   cannot detect what is missing.
/// - The BenQ MA320U this fork was built for reports input source `19`, which is
///   not a meaningful VESA code.
///
/// This file is the whole decision core: decoding, merging and resolution, all
/// pure. No `Bundle`, no file system, no IOKit — `MonitorQuirksService` owns that
/// half — so it compiles into the headless `CrispTests` target the same way
/// `DDCServiceMatcher` and `DisplayStateDocument` do.

// MARK: - Identity

/// The lookup key: vendor + product, exactly the pair `DisplayInfo` already
/// carries (`CGDisplayVendorNumber` / `CGDisplayModelNumber`).
///
/// Serial is deliberately not part of the key. Quirks describe a *model*, not one
/// person's unit, and including the serial would make every contributed entry
/// useless to everybody else.
struct MonitorQuirkKey: Hashable, Sendable, CustomStringConvertible {
    let vendor: UInt32
    let product: UInt32

    init(vendor: UInt32, product: UInt32) {
        self.vendor = vendor
        self.product = product
    }

    var description: String {
        String(format: "0x%04X:0x%04X", vendor, product)
    }

    /// Accepts the way monitor IDs are actually written down — `"0x09D1"`,
    /// `"09D1"` (hex is the convention in EDID dumps and bug reports) or plain
    /// decimal `"2513"`. Contributors copy these out of `crispctl list`, which
    /// prints hex, but out of `system_profiler`, which prints decimal.
    static func parseID(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt32(trimmed.dropFirst(2), radix: 16)
        }
        // A bare decimal string wins over a bare hex one: "2513" has to mean 2513.
        return UInt32(trimmed, radix: 10) ?? UInt32(trimmed, radix: 16)
    }
}

// MARK: - Confidence

/// How much evidence stands behind one piece of quirk data.
///
/// Load-bearing, not documentation. `verified` means a human watched the change
/// happen on the physical panel; `reported` means one user said so. The app is
/// allowed to *show* reported data (marked as unconfirmed) but never to act on it
/// silently where being wrong is expensive — an input-source write to the wrong
/// code sends the display to a port with nothing attached, and the only way back
/// is the monitor's physical buttons.
enum QuirkConfidence: String, Codable, Sendable, CaseIterable {
    case verified
    case reported

    var isVerified: Bool { self == .verified }

    /// The better-evidenced of two claims, used when two files describe the same
    /// model and one of them has actually been on the hardware.
    static func stronger(_ lhs: QuirkConfidence, _ rhs: QuirkConfidence) -> QuirkConfidence {
        lhs.isVerified || rhs.isVerified ? .verified : .reported
    }
}

// MARK: - Feature data

/// A DDC feature by name. The name *is* the VCP code (MCCS fixes them), which is
/// why the schema has no per-feature `vcp` override: a JSON file that strangers
/// contribute must not be able to aim a write at an arbitrary register on the
/// monitor's I2C bus.
enum QuirkFeatureName: String, Codable, Sendable, CaseIterable {
    case brightness  // VCP 0x10
    case contrast    // VCP 0x12
    case volume      // VCP 0x62
    case input       // VCP 0x60
}

/// The raw DDC value range a monitor really honours.
///
/// `min` is not always 0 — the Dell 2407wfp ignores anything below 30 and its
/// 0–50 dial is really 30–50 — so percent↔raw conversion has to carry both ends.
struct QuirkRange: Equatable, Sendable {
    let min: UInt16
    let max: UInt16

    private init(validated min: UInt16, max: UInt16) {
        self.min = min
        self.max = max
    }

    init?(min: UInt16, max: UInt16) {
        // An inverted or empty range is contributor error, not something to
        // silently "fix" by swapping: reject it so the entry is dropped and logged.
        guard min < max else { return nil }
        self.init(validated: min, max: max)
    }

    /// The MCCS default for a percent-shaped feature (raw 0–100): what to assume
    /// when neither the database nor the monitor says anything better. Built
    /// through the private initializer so the one range that is known-good at
    /// compile time does not need a force unwrap at every use.
    static let mccsPercent = QuirkRange(validated: 0, max: 100)

    /// Percent (0–100 as the UI thinks of it) → the raw value to write.
    func raw(forPercent percent: Double) -> UInt16 {
        let clamped = Swift.max(0.0, Swift.min(100.0, percent))
        let span = Double(max) - Double(min)
        return UInt16((Double(min) + clamped / 100.0 * span).rounded())
    }

    /// Raw value read back from the monitor → percent for the UI.
    func percent(forRaw raw: UInt16) -> Double {
        let span = Double(max) - Double(min)
        guard span > 0 else { return 0 }
        let ratio = (Double(raw) - Double(min)) / span * 100.0
        return Swift.max(0.0, Swift.min(100.0, ratio))
    }
}

/// One input-source code and what it is actually wired to on this model.
///
/// Carried as an array of objects rather than the obvious `{"19": "USB-C"}` map
/// because each individual code needs its own `confidence` and `notes`: on the
/// MA320U the model is verified for contrast and volume while its input mapping
/// is pure guesswork, and a JSON object key cannot say so.
struct QuirkInputValue: Equatable, Sendable {
    let code: UInt16
    let label: String
    let confidence: QuirkConfidence
    let notes: String?
}

/// Everything known about one feature on one model.
struct QuirkFeature: Equatable, Sendable {
    let range: QuirkRange?
    let values: [QuirkInputValue]
    /// Defaults to the model's confidence when the file does not narrow it —
    /// except for `input`, which never inherits above `reported` and whose codes
    /// only reach `verified` by declaring it themselves (see `resolved`).
    let confidence: QuirkConfidence
    /// `values` is this model's *complete* port list, so the app may stop
    /// offering the generic VESA codes for it. Defaults to false: a half-mapped
    /// monitor is the normal state of a contribution in progress, and dropping
    /// the generic codes there would leave the user unable to reach a port
    /// nobody has written down yet.
    let complete: Bool

    func value(for code: UInt16) -> QuirkInputValue? {
        values.first { $0.code == code }
    }
}

/// Behaviours that need a code work-around rather than a different number.
///
/// Decoded in full so contributors have somewhere to put what they measured;
/// only `writeDelayMs` is acted on today (see `DDCFeatureService`). The rest are
/// carried, surfaced in logs, and wired as the corresponding write paths gain
/// support. Recording a monitor's behaviour is useful before the code handles it.
struct QuirkWorkarounds: Equatable, Sendable {
    /// The largest write spacing a contributed file may ask for.
    ///
    /// MCCS recommends ~50 ms between writes and the slowest monitors anyone has
    /// documented need a few hundred, so two seconds is already far beyond
    /// useful. The bound exists because this database takes pull requests from
    /// strangers: an unbounded value — a ms/ns units mix-up, one extra digit —
    /// is arithmetic the write pump cannot survive, and a delay nobody can
    /// justify is contributor error rather than data.
    static let maxWriteDelayMs = 2000

    /// Spacing between consecutive writes, overriding the MCCS ~50 ms default.
    /// Always within `1...maxWriteDelayMs`; anything else decodes to `nil`.
    var writeDelayMs: Int?
    /// Monitor needs a "save current settings" command (VCP 0xB0) after a write
    /// or the value reverts (Iiyama PL2492H). Not yet acted on.
    var saveAfterWrite: Bool
    /// Monitor accepts a write and undoes it about a second later (LG 27MU67),
    /// so a read-back after the write is not evidence of anything. Not yet acted on.
    var revertsAfterWrite: Bool
    /// Monitor answers every VCP as supported, so probing cannot tell what it
    /// really has (feature detection must come from this database). Not yet acted on.
    var reportsUnsupportedAsSupported: Bool

    static let none = QuirkWorkarounds(
        writeDelayMs: nil,
        saveAfterWrite: false,
        revertsAfterWrite: false,
        reportsUnsupportedAsSupported: false
    )
}

// MARK: - One model

/// The quirks for one monitor model.
struct MonitorQuirks: Equatable, Sendable {
    let key: MonitorQuirkKey
    let vendorName: String
    let modelName: String
    /// Model-wide default; individual features and input codes may narrow it.
    let confidence: QuirkConfidence
    let features: [QuirkFeatureName: QuirkFeature]
    let workarounds: QuirkWorkarounds
    let notes: String?

    func feature(_ name: QuirkFeatureName) -> QuirkFeature? { features[name] }

    func inputValue(for code: UInt16) -> QuirkInputValue? {
        features[.input]?.value(for: code)
    }

    /// Every input code this model is known to have, in file order (contributors
    /// list them in physical port order, which is what a user expects to see).
    var inputValues: [QuirkInputValue] { features[.input]?.values ?? [] }

    /// Whether `inputValues` is the whole port list rather than a partial map.
    var hasCompleteInputList: Bool { features[.input]?.complete ?? false }
}

// MARK: - Decoding

/// One vendor file: `Crisp/Resources/quirks/<vendor>.json`.
///
/// Decoding is tolerant by design (AGENTS.md rule #4 — nothing may take the app
/// down). A model whose product ID or confidence will not parse is dropped and
/// reported in `problems`; the rest of the file still loads. Only a file that is
/// not valid JSON at all fails wholesale, and `MonitorQuirksService` skips it.
struct MonitorQuirksFile: Decodable, Sendable {
    /// Bumped only for a breaking layout change. A file stamped newer is still
    /// read on today's terms — unknown keys are ignored, the same policy
    /// `DisplayStateDocument` uses.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let vendor: UInt32
    let vendorName: String
    let models: [MonitorQuirks]
    /// Human-readable reasons individual entries were dropped, for the log.
    let problems: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, vendor, vendorName, models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion

        let vendorText = try container.decode(String.self, forKey: .vendor)
        guard let vendorID = MonitorQuirkKey.parseID(vendorText) else {
            throw DecodingError.dataCorruptedError(
                forKey: .vendor, in: container,
                debugDescription: "vendor \"\(vendorText)\" is not a hex or decimal id"
            )
        }
        vendor = vendorID
        vendorName = try container.decodeIfPresent(String.self, forKey: .vendorName) ?? vendorText

        // Per-element leniency: one bad model must not cost the file.
        let rawModels = try container.decodeIfPresent([Lenient<RawModel>].self, forKey: .models) ?? []
        var decoded: [MonitorQuirks] = []
        var issues: [String] = []
        for (index, entry) in rawModels.enumerated() {
            guard let raw = entry.value else {
                issues.append("\(vendorName) model[\(index)]: \(entry.problem ?? "unreadable")")
                continue
            }
            do {
                decoded.append(try raw.resolved(vendor: vendorID, vendorName: vendorName))
            } catch {
                issues.append("\(vendorName) model[\(index)]: \(error.localizedDescription)")
            }
        }
        models = decoded
        problems = issues
    }

    /// Decodes `data`, never throwing at the caller: a corrupt file yields `nil`
    /// plus the reason, so the loader can log it and move on to the next vendor.
    static func decoding(_ data: Data) -> (file: MonitorQuirksFile?, failure: Error?) {
        do {
            return (try JSONDecoder().decode(MonitorQuirksFile.self, from: data), nil)
        } catch {
            return (nil, error)
        }
    }
}

/// Decodes `T`, capturing a failure instead of propagating it.
///
/// Works inside an unkeyed container because the element is consumed either way:
/// the wrapper's `init(from:)` does not throw, so the container still advances
/// past the broken element and the following ones decode normally.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    let problem: String?

    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
            problem = nil
        } catch {
            value = nil
            problem = "\(error)"
        }
    }
}

/// The on-disk shape of one model, before the vendor is folded in.
private struct RawModel: Decodable {
    let product: String
    let name: String?
    let confidence: QuirkConfidence?
    let notes: String?
    let features: [String: RawFeature]?
    let workarounds: RawWorkarounds?

    struct RawFeature: Decodable {
        let range: [Int]?
        let confidence: QuirkConfidence?
        let values: [RawInputValue]?
        let complete: Bool?
    }

    struct RawInputValue: Decodable {
        let code: Int
        let label: String
        let confidence: QuirkConfidence?
        let notes: String?
    }

    struct RawWorkarounds: Decodable {
        let writeDelayMs: Int?
        let saveAfterWrite: Bool?
        let revertsAfterWrite: Bool?
        let reportsUnsupportedAsSupported: Bool?
    }

    func resolved(vendor: UInt32, vendorName: String) throws -> MonitorQuirks {
        guard let productID = MonitorQuirkKey.parseID(product) else {
            throw QuirkParseError("product \"\(product)\" is not a hex or decimal id")
        }
        let modelConfidence = confidence ?? .reported
        var resolvedFeatures: [QuirkFeatureName: QuirkFeature] = [:]
        // Unknown feature names are skipped rather than rejected: a file written
        // for a later build must still load everything this build understands.
        for (rawName, rawFeature) in features ?? [:] {
            guard let name = QuirkFeatureName(rawValue: rawName) else { continue }
            resolvedFeatures[name] = try rawFeature.resolved(default: modelConfidence, feature: name)
        }
        return MonitorQuirks(
            key: MonitorQuirkKey(vendor: vendor, product: productID),
            vendorName: vendorName,
            modelName: name ?? product,
            confidence: modelConfidence,
            features: resolvedFeatures,
            workarounds: workarounds?.resolved() ?? .none,
            notes: notes
        )
    }
}

private extension RawModel.RawFeature {
    func resolved(default modelConfidence: QuirkConfidence, feature: QuirkFeatureName) throws -> QuirkFeature {
        // `input` never inherits confidence. A contributor who marks the model
        // `verified` after confirming brightness/contrast/volume, and forgets to
        // re-declare `reported` on `input`, would otherwise promote guessed
        // input codes straight past the confirmation dialog — and a wrong VCP
        // 0x60 write is the one mistake the user cannot undo from the Mac.
        // Every other feature inherits as documented.
        let inherited: QuirkConfidence = feature == .input ? .reported : modelConfidence
        let featureConfidence = confidence ?? inherited
        var parsedRange: QuirkRange?
        if let range {
            guard range.count == 2,
                  let low = UInt16(exactly: range[0]), let high = UInt16(exactly: range[1]),
                  let built = QuirkRange(min: low, max: high) else {
                throw QuirkParseError("\(feature.rawValue) range \(range) must be [min, max] with 0 <= min < max <= 65535")
            }
            parsedRange = built
        }
        // …and for the same reason an individual code only reaches `verified` by
        // saying so itself. Inheriting it from the feature (which a file may
        // still declare `verified` wholesale) would put every unlisted-confidence
        // code in that file past the dialog on one line's worth of evidence.
        let valueDefault: QuirkConfidence = feature == .input ? .reported : featureConfidence
        let parsedValues: [QuirkInputValue] = try (values ?? []).map { raw in
            guard let code = UInt16(exactly: raw.code) else {
                throw QuirkParseError("\(feature.rawValue) value code \(raw.code) is out of range")
            }
            return QuirkInputValue(
                code: code,
                label: raw.label,
                confidence: raw.confidence ?? valueDefault,
                notes: raw.notes
            )
        }
        return QuirkFeature(
            range: parsedRange,
            values: parsedValues,
            confidence: featureConfidence,
            complete: complete ?? false
        )
    }
}

private extension RawModel.RawWorkarounds {
    func resolved() -> QuirkWorkarounds {
        QuirkWorkarounds(
            // Bounded here, at the edge, the same way `range` and input `code`
            // are: the pump multiplies this by 1_000_000 to get nanoseconds, and
            // Swift's `*` traps on overflow. A value outside the plausible band
            // decodes to `nil` — "use the MCCS default" — rather than dropping
            // the whole model, which would also throw away its good range data.
            writeDelayMs: writeDelayMs.flatMap {
                (1...QuirkWorkarounds.maxWriteDelayMs).contains($0) ? $0 : nil
            },
            saveAfterWrite: saveAfterWrite ?? false,
            revertsAfterWrite: revertsAfterWrite ?? false,
            reportsUnsupportedAsSupported: reportsUnsupportedAsSupported ?? false
        )
    }
}

/// A contributor mistake in one entry. Its message goes to the log verbatim, so
/// it names the field and the bad value.
struct QuirkParseError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var localizedDescription: String { message }
}

// MARK: - Merged database

/// Every vendor file, merged and indexed by vendor+product.
struct MonitorQuirksDatabase: Equatable, Sendable {
    private(set) var models: [MonitorQuirkKey: MonitorQuirks]

    static let empty = MonitorQuirksDatabase(models: [:])

    init(models: [MonitorQuirkKey: MonitorQuirks]) {
        self.models = models
    }

    /// Merges files in the order given.
    ///
    /// Duplicate models are resolved by evidence, not by load order: a `verified`
    /// entry always beats a `reported` one, and between equals the first file
    /// wins. Order the input deterministically (the loader sorts by file name) so
    /// the same install always ends up with the same database.
    static func merging(_ files: [MonitorQuirksFile]) -> (database: MonitorQuirksDatabase, problems: [String]) {
        var models: [MonitorQuirkKey: MonitorQuirks] = [:]
        var problems: [String] = []
        for file in files {
            problems.append(contentsOf: file.problems)
            for model in file.models {
                if let existing = models[model.key] {
                    guard model.confidence.isVerified, !existing.confidence.isVerified else {
                        problems.append("duplicate model \(model.key) (\(model.modelName)): kept \(existing.modelName)")
                        continue
                    }
                    problems.append("duplicate model \(model.key): verified \(model.modelName) replaced \(existing.modelName)")
                }
                models[model.key] = model
            }
        }
        return (MonitorQuirksDatabase(models: models), problems)
    }

    /// Unknown vendor or model is not an error — it is the normal case, and it
    /// means the app behaves exactly as it does with no database at all.
    func quirks(vendor: UInt32, product: UInt32) -> MonitorQuirks? {
        models[MonitorQuirkKey(vendor: vendor, product: product)]
    }

    var count: Int { models.count }
}

// MARK: - MCCS standard fallback

/// The VESA MCCS 0x60 value table — the last resort when nothing better is known.
///
/// Its labels are a *specification's* claim about a monitor, not a measurement,
/// which is precisely why the MA320U's code 19 renders as "DVI-10" here and why
/// the resolver stamps this tier `reported`.
enum MCCSInputTable {
    static func label(for value: UInt16) -> String? {
        switch value {
        case 0x01: return "VGA-1"
        case 0x02: return "VGA-2"
        case 0x03: return "DVI-1"
        case 0x04: return "DVI-2"
        case 0x05: return "Composite-1"
        case 0x06: return "Composite-2"
        case 0x07: return "S-Video-1"
        case 0x08: return "S-Video-2"
        case 0x09: return "Tuner-1"
        case 0x0A: return "Tuner-2"
        case 0x0B: return "Tuner-3"
        case 0x0C...0x13: return "DVI-\(value - 0x0C + 3)"
        case 0x14...0x1D: return "DisplayPort-\(value - 0x14 + 1)"
        case 0x20...0x2F: return "HDMI-\(value - 0x20 + 1)"
        case 0x30...0x3F: return "USB-C-\(value - 0x30 + 1)"
        default: return nil
        }
    }

    /// The inputs offered when the database knows nothing about this model:
    /// the DisplayPort, HDMI and USB-C codes that most monitors do use.
    static let commonCodes: [UInt16] = [0x14, 0x15, 0x16, 0x17, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31]
}

// MARK: - Resolution

/// Where a resolved answer came from, highest priority first.
enum QuirkSource: String, Sendable {
    /// Per-display state the user themselves produced.
    case userOverride
    /// The shipped quirks database.
    case database
    /// What the monitor answered to a live DDC read.
    case probe
    /// The VESA MCCS default.
    case standard
}

/// A resolved value plus where it came from and how much it can be trusted.
struct ResolvedQuirk<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let source: QuirkSource
    let confidence: QuirkConfidence
}

/// One input code, resolved for display and for safety.
///
/// The two confidences are deliberately separate. "Is this label right?" and "is
/// writing this code safe?" are different questions with different answers: the
/// input the monitor is on *right now* is provably safe to write even when its
/// label is a stranger's guess.
struct ResolvedInput: Equatable, Sendable {
    let code: UInt16
    /// Best label known. Never presented as fact unless `labelConfidence` is verified.
    let label: String
    let labelSource: QuirkSource
    let labelConfidence: QuirkConfidence
    /// How well founded "writing this code will land on a live port" is.
    let switchConfidence: QuirkConfidence
    let notes: String?

    /// Whether the app must ask the user before writing this to VCP 0x60.
    ///
    /// A wrong input code switches the panel to a port with nothing attached and
    /// the user cannot switch back from the Mac — only from the monitor's
    /// physical buttons. So anything short of verified gets a confirmation.
    var needsConfirmation: Bool { !switchConfidence.isVerified }

    /// What the UI shows. An unconfirmed label keeps its question mark so the app
    /// never states a guess as fact.
    var displayLabel: String {
        labelConfidence.isVerified ? label : "\(label)?"
    }
}

/// The resolution rules, pure and headless.
///
/// Priority, highest first: user override → shipped quirks database → live probe
/// → MCCS standard default. Every query below follows exactly that order.
enum MonitorQuirkResolver {

    /// The raw range to use for a percent-based feature (contrast today).
    ///
    /// The database outranks the probe on purpose: a monitor that misreports its
    /// own maximum is the reason the database exists.
    static func range(
        _ feature: QuirkFeatureName,
        quirks: MonitorQuirks?,
        userOverride: QuirkRange? = nil,
        probeMax: UInt16?,
        standard: QuirkRange
    ) -> ResolvedQuirk<QuirkRange> {
        if let userOverride {
            return ResolvedQuirk(value: userOverride, source: .userOverride, confidence: .verified)
        }
        if let quirkFeature = quirks?.feature(feature), let range = quirkFeature.range {
            return ResolvedQuirk(value: range, source: .database, confidence: quirkFeature.confidence)
        }
        if let probeMax, let probed = QuirkRange(min: 0, max: probeMax) {
            return ResolvedQuirk(value: probed, source: .probe, confidence: .verified)
        }
        return ResolvedQuirk(value: standard, source: .standard, confidence: .reported)
    }

    /// Spacing between consecutive DDC writes for this monitor, in milliseconds.
    /// Falls back to the MCCS-recommended default when nothing is known.
    static func writeDelayMs(quirks: MonitorQuirks?, standard: Int) -> Int {
        guard let delay = quirks?.workarounds.writeDelayMs, delay > 0 else { return standard }
        return delay
    }

    /// Resolves one input-source code.
    ///
    /// - `currentInput`: what VCP 0x60 reports right now (the live probe).
    /// - `userSelectedInput`: the code the user last picked themselves and whose
    ///   screen survived it — the user-override tier, and the strongest evidence
    ///   there is that this particular code works on this particular unit.
    static func input(
        code: UInt16,
        quirks: MonitorQuirks?,
        currentInput: UInt16?,
        userSelectedInput: UInt16?
    ) -> ResolvedInput {
        let quirkValue = quirks?.inputValue(for: code)

        // Label: database first, then the MCCS table, then the bare number. A
        // number is honest about being unknown, so it counts as verified fact.
        let label: String
        let labelSource: QuirkSource
        let labelConfidence: QuirkConfidence
        if let quirkValue {
            label = quirkValue.label
            labelSource = .database
            labelConfidence = quirkValue.confidence
        } else if let standard = MCCSInputTable.label(for: code) {
            label = standard
            labelSource = .standard
            labelConfidence = .reported
        } else {
            label = String(code)
            labelSource = .probe
            labelConfidence = .verified
        }

        // Safety: only three things prove a code lands on a live port — the user
        // already chose it, the monitor is on it, or a human verified it on this
        // model. A `reported` database entry explicitly does not.
        let switchConfidence: QuirkConfidence
        if code == userSelectedInput || code == currentInput || quirkValue?.confidence.isVerified == true {
            switchConfidence = .verified
        } else {
            switchConfidence = .reported
        }

        return ResolvedInput(
            code: code,
            label: label,
            labelSource: labelSource,
            labelConfidence: labelConfidence,
            switchConfidence: switchConfidence,
            notes: quirkValue?.notes
        )
    }

    /// The inputs to offer in the menu: the current one first (always selectable,
    /// since selecting it is a no-op), then whatever the database knows about
    /// this model, then the common MCCS codes unless the database's port list is
    /// declared complete. Deduplicated, order preserved.
    static func inputOptions(
        quirks: MonitorQuirks?,
        currentInput: UInt16,
        userSelectedInput: UInt16?,
        standardCodes: [UInt16] = MCCSInputTable.commonCodes
    ) -> [ResolvedInput] {
        var codes: [UInt16] = [currentInput]
        codes.append(contentsOf: quirks?.inputValues.map(\.code) ?? [])
        // Only a port list a contributor has declared complete may replace the
        // generic VESA codes. A partial map — the MA320U has one inferred code
        // and four physical ports — has to keep them, or the database would be
        // taking input switching away instead of improving it.
        if quirks?.hasCompleteInputList != true {
            codes.append(contentsOf: standardCodes)
        }

        var seen: Set<UInt16> = []
        return codes.compactMap { code in
            guard seen.insert(code).inserted else { return nil }
            return input(code: code, quirks: quirks, currentInput: currentInput, userSelectedInput: userSelectedInput)
        }
    }
}
