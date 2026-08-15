import Foundation

// "Report this monitor": live probe results → a ready-to-submit quirks entry.
//
// The monitor quirks database is only as good as the number of monitors in it,
// and the friction that keeps it small is not Swift — it is that a contributor
// has to read a schema, work out which of their numbers count as evidence, and
// be trusted to mark the rest honestly. This generator does the first two and
// removes the temptation in the third: **nothing it emits is ever `verified`.**
//
// That is not politeness. A probe establishes exactly one thing — the maximum
// the monitor *claims* for a VCP code. It does not establish the usable minimum
// (the Dell 2407wfp ignores everything below raw 30), it does not establish that
// a write sticks (the Iiyama PL2492H reverts without a save command), and above
// all it does not establish what any input code is wired to. `MonitorQuirks`'s
// decoder already caps what `input` may inherit at `reported` for that last
// reason; a generator that fought that rule would be undoing the one safety
// property the database has.
//
// Pure Foundation: no `Bundle`, no IOKit, no DDC. It renders what it is handed,
// so `CrispTests` can feed it a probe and push the result back through the real
// `MonitorQuirksFile` decoder — a generator whose output the loader rejects is
// worse than no generator.

// MARK: - Input

/// What one read pass over a monitor actually established.
struct MonitorProbeReport: Equatable, Sendable {
    let vendor: UInt32
    let product: UInt32
    /// The display's own name as macOS reports it, e.g. "BenQ MA320U".
    let displayName: String?
    let brightness: RawProbe?
    let contrast: RawProbe?
    let volume: RawProbe?
    /// VCP 0x60. `current` is the code the monitor is on right now, which is the
    /// only input fact a read can establish — and even then only that the code
    /// exists, not what port it is wired to.
    let input: RawProbe?
    /// For the entry's `notes`, so a reviewer knows what it was measured on.
    let osVersion: String
    let macModel: String
    let appVersion: String

    init(
        vendor: UInt32,
        product: UInt32,
        displayName: String? = nil,
        brightness: RawProbe? = nil,
        contrast: RawProbe? = nil,
        volume: RawProbe? = nil,
        input: RawProbe? = nil,
        osVersion: String,
        macModel: String,
        appVersion: String
    ) {
        self.vendor = vendor
        self.product = product
        self.displayName = displayName
        self.brightness = brightness
        self.contrast = contrast
        self.volume = volume
        self.input = input
        self.osVersion = osVersion
        self.macModel = macModel
        self.appVersion = appVersion
    }
}

// MARK: - EDID manufacturer id

/// The three-letter PnP id EDID packs into the 16-bit manufacturer field.
enum EDIDManufacturer {
    /// One reserved bit, then three 5-bit letters with 1 = 'A'.
    /// `0x09D1` → `"BNQ"`. Returns `nil` for a field that does not decode to
    /// three letters, which is how a synthesised or virtual display looks — and
    /// an unreadable code must read as unknown, not as three question marks.
    static func code(for vendor: UInt32) -> String? {
        guard vendor > 0, vendor <= 0xFFFF else { return nil }
        let packed = UInt16(vendor)
        let letters = [(packed >> 10) & 0x1F, (packed >> 5) & 0x1F, packed & 0x1F]
        guard letters.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return String(letters.map { Character(UnicodeScalar(UInt8(0x40 + $0))) })
    }
}

// MARK: - Generator

enum QuirkEntryGenerator {

    /// The confidence every field this generator emits carries.
    ///
    /// A constant rather than a literal at each site, so "does this generator ever
    /// emit `verified`?" is answerable by reading one line — and so a test can
    /// assert on the value rather than on a string that happens to match.
    static let emittedConfidence = QuirkConfidence.reported

    /// Splits a display name into the schema's `vendorName` and model `name`.
    ///
    /// macOS reports the EDID product name, which by near-universal convention
    /// leads with the vendor: "BenQ MA320U" → `BenQ` / `MA320U`, matching the
    /// hand-written `benq.json` entry exactly. A single-token name keeps the whole
    /// token as the model and falls back to the EDID PnP id for the vendor, and a
    /// missing name falls back to the raw ids — every one of which is a fact, not
    /// a guess. The entry's `notes` tells the contributor to correct the spelling
    /// to whatever the vendor actually uses.
    static func names(displayName: String?, vendor: UInt32, product: UInt32) -> (vendor: String, model: String) {
        let fallbackVendor = EDIDManufacturer.code(for: vendor) ?? String(format: "0x%04X", vendor)
        let tokens = (displayName ?? "")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        switch tokens.count {
        case 0:
            return (fallbackVendor, String(format: "0x%04X", product))
        case 1:
            return (fallbackVendor, tokens[0])
        default:
            return (tokens[0], tokens.dropFirst().joined(separator: " "))
        }
    }

    /// The quirks JSON for this monitor, formatted the way the shipped vendor
    /// files are: 2-space indent, keys in schema order.
    ///
    /// Throws only if `JSONEncoder` fails on a tree of `String`/`Int`/`Bool`,
    /// which it cannot — but a silent `?? "{}"` would emit a file the loader
    /// accepts and that says nothing, so the impossible case stays visible.
    static func json(for probe: MonitorProbeReport) throws -> String {
        let names = names(displayName: probe.displayName, vendor: probe.vendor, product: probe.product)
        let confidence = emittedConfidence.rawValue

        let file = File(
            schemaVersion: MonitorQuirksFile.currentSchemaVersion,
            vendor: String(format: "0x%04X", probe.vendor),
            vendorName: names.vendor,
            models: [
                Model(
                    product: String(format: "0x%04X", probe.product),
                    name: names.model,
                    confidence: confidence,
                    notes: modelNotes(probe),
                    features: Features(
                        brightness: range(for: .brightness, probe: probe.brightness),
                        contrast: range(for: .contrast, probe: probe.contrast),
                        volume: range(for: .volume, probe: probe.volume),
                        input: inputFeature(probe.input)
                    ),
                    workarounds: Workarounds(
                        saveAfterWrite: false,
                        revertsAfterWrite: false,
                        reportsUnsupportedAsSupported: false
                    )
                )
            ]
        )

        let encoder = JSONEncoder()
        // `.sortedKeys` is load-bearing, not cosmetic. `JSONEncoder` builds each
        // keyed container from a dictionary, and Swift seeds its string hashing
        // per process — so without this, generating the same entry twice produces
        // the same JSON in a different key order, and a contributor who
        // regenerates before pushing gets a diff full of nothing. Alphabetical is
        // not the schema's own order, but it is the same every time.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuirkParseError("generated quirks entry was not valid UTF-8")
        }
        return text
    }

    /// The GitHub issue body, with the JSON inline so the whole contribution is
    /// one paste — for a user who would rather open an issue than a pull request.
    static func issueBody(for probe: MonitorProbeReport, json: String) -> String {
        let names = names(displayName: probe.displayName, vendor: probe.vendor, product: probe.product)
        let fileName = suggestedFileName(vendorName: names.vendor)

        var out: [String] = []
        out.append("## Monitor report: \(names.vendor) \(names.model)")
        out.append("")
        out.append("Generated by Crisp \(probe.appVersion) on macOS \(probe.osVersion) (\(probe.macModel)).")
        out.append("")
        out.append("| Item | Value |")
        out.append("|---|---|")
        out.append("| Vendor / product | \(String(format: "0x%04X", probe.vendor)) / \(String(format: "0x%04X", probe.product)) |")
        out.append("| Brightness (VCP 0x10) | \(probeText(probe.brightness)) |")
        out.append("| Contrast (VCP 0x12) | \(probeText(probe.contrast)) |")
        out.append("| Volume (VCP 0x62) | \(probeText(probe.volume)) |")
        out.append("| Input source (VCP 0x60) | \(probeText(probe.input)) |")
        out.append("")
        out.append("No serial number is included: quirks describe a **model**, not one person's unit, "
            + "so the database is keyed on vendor + product only.")
        out.append("")
        out.append("### Proposed entry for `Crisp/Resources/quirks/\(fileName)`")
        out.append("")
        out.append("```json")
        out.append(json)
        out.append("```")
        out.append("")
        out.append("### Everything above is `reported`, and here is what would make it `verified`")
        out.append("")
        out.append("A read pass establishes the maximum a monitor *claims*. It does not establish "
            + "the usable minimum, whether a write sticks, or what any input code is wired to. "
            + "Each box below is one measurement; tick the ones you have actually done and say so in the PR.")
        out.append("")
        out.append("- [ ] **Ranges.** `crispctl set contrast 40`, then `get` — did it land, and did it stay? "
            + "Walk down until the value stops moving: that is the real minimum, not 0.")
        out.append("- [ ] **Reverts.** Value lands and then undoes itself about a second later → `revertsAfterWrite`.")
        out.append("- [ ] **Save needed.** Value never sticks without a \"save settings\" step → `saveAfterWrite`.")
        out.append("- [ ] **Write spacing.** Writes drop under a slider drag → `writeDelayMs` (1–2000 ms).")
        out.append("- [ ] **Input codes.** See the warning below. One line per port you have switched to *and back from*.")
        out.append("")
        out.append("> [!WARNING]")
        out.append("> **Never guess an input code.** A wrong VCP 0x60 write sends the panel to a port with "
            + "nothing attached; the Mac can no longer switch it back, and the only way out is the monitor's own buttons. "
            + "Get the mapping without ever writing 0x60: read the current code, switch input using the monitor's "
            + "physical buttons, read it again. The new number is that port's code. Repeat per port.")
        out.append("")
        out.append("Full instructions, including what `verified` is claiming: `Crisp/Resources/quirks/README.md`.")
        out.append("")
        return out.joined(separator: "\n")
    }

    /// `benq.json` for "BenQ". Non-alphanumeric characters are dropped rather
    /// than escaped, since this is a file name a human will type.
    static func suggestedFileName(vendorName: String) -> String {
        let slug = vendorName.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(slug.isEmpty ? "vendor" : slug).json"
    }

    // MARK: - Field builders

    private static func probeText(_ probe: RawProbe?) -> String {
        guard let probe else { return "no answer — the monitor did not reply to this read" }
        return "current \(probe.current), max \(probe.max)"
    }

    private static func range(for feature: QuirkFeatureName, probe: RawProbe?) -> RangeFeature? {
        // A max of 0 is not a range: `QuirkRange` rejects `min >= max`, so emitting
        // one would produce an entry the loader drops on load with a logged error.
        guard let probe, probe.max > 0 else { return nil }
        return RangeFeature(
            range: [0, probe.max],
            confidence: emittedConfidence.rawValue,
            notes: "Maximum reported by the monitor to a VCP \(feature.vcpText) read; current value was "
                + "\(probe.current) at the time. The minimum is assumed to be 0 and has NOT been confirmed — "
                + "some monitors ignore the bottom of their own range. See README.md, \"Ranges\"."
        )
    }

    /// The `input` feature, carrying at most the one code the monitor is on.
    ///
    /// The label is **always** `Input-<code>`, never the VESA MCCS name, even when
    /// the table has one. That is deliberate and it is the subtlest rule in this
    /// file: the resolver already falls back to the MCCS table on its own, tagged
    /// `labelSource: .standard`, so copying that name into a database entry adds
    /// no information and changes the tag to `.database` — turning a
    /// specification's claim about monitors in general into something that reads
    /// as "a human wrote this down about *this* model". The BenQ MA320U is the
    /// worked example: the table calls its code 19 "DVI-10", and the panel has no
    /// DVI port at all. So the table's name goes in the `notes`, where a
    /// contributor can confirm or reject it, and never in the `label`.
    private static func inputFeature(_ probe: RawProbe?) -> InputFeature? {
        guard let probe else { return nil }
        let code = probe.current
        let provenance: String
        if let standardLabel = MCCSInputTable.label(for: code) {
            provenance = "The VESA MCCS table calls code \(code) \"\(standardLabel)\", but that is only what "
                + "the standard says it should be and monitors deviate constantly "
                + "(the Samsung U32H750 advertises codes it does not use). Confirm it before adopting it as the label"
        } else {
            provenance = "Code \(code) is not a code the VESA MCCS table names at all, "
                + "so there is not even a standard guess to start from"
        }
        return InputFeature(
            confidence: emittedConfidence.rawValue,
            // Never true from a generator: one code cannot be a complete port list,
            // and declaring it complete would stop the app offering the generic
            // VESA codes, taking input switching away instead of improving it.
            complete: false,
            notes: "Only the input the monitor happened to be on when this was generated. "
                + "The panel's other ports are unmapped, so this list is deliberately incomplete.",
            values: [
                InputValue(
                    code: code,
                    label: "Input-\(code)",
                    confidence: emittedConfidence.rawValue,
                    notes: "UNCONFIRMED. The monitor reported this as its current input source; "
                        + "nobody has switched away from it and back to prove which physical port it is. "
                        + "\(provenance). Replace the label with the port you find it wired to, and do not "
                        + "promote to \"verified\" without doing the physical-buttons calibration in README.md."
                )
            ]
        )
    }

    private static func modelNotes(_ probe: MonitorProbeReport) -> String {
        "Auto-generated by Crisp \(probe.appVersion)'s monitor report on macOS \(probe.osVersion) (\(probe.macModel)). "
            + "Every field is \"reported\": the values come from a single DDC read pass, which establishes only the "
            + "maximum each control claims. Nothing was written, no range end was walked, and no input code was "
            + "confirmed against a physical port. Check that vendorName and name read the way the vendor spells them, "
            + "then measure what you can and re-mark those fields — README.md says what each level of evidence is claiming."
    }

    // MARK: - On-disk shape

    // Mirrors Crisp/Resources/quirks/README.md. Encoded rather than string-built
    // so the JSON is valid by construction: a monitor name or a VESA label can
    // carry a quote or a backslash, and a hand-rolled writer that gets that wrong
    // produces an entry the loader silently drops. Declared in schema order for
    // reading; the encoder emits them alphabetically (see `json(for:)`).

    private struct File: Encodable {
        let schemaVersion: Int
        let vendor: String
        let vendorName: String
        let models: [Model]
    }

    private struct Model: Encodable {
        let product: String
        let name: String
        let confidence: String
        let notes: String
        let features: Features
        let workarounds: Workarounds
    }

    private struct Features: Encodable {
        let brightness: RangeFeature?
        let contrast: RangeFeature?
        let volume: RangeFeature?
        let input: InputFeature?
    }

    private struct RangeFeature: Encodable {
        let range: [UInt16]
        let confidence: String
        let notes: String
    }

    private struct InputFeature: Encodable {
        let confidence: String
        let complete: Bool
        let notes: String
        let values: [InputValue]
    }

    /// One entry of `InputFeature.values`. A peer of `InputFeature` rather than a
    /// nested type only so the nesting stays one level deep; the JSON it encodes
    /// to is unchanged, since `Encodable` keys off the property names.
    private struct InputValue: Encodable {
        let code: UInt16
        let label: String
        let confidence: String
        let notes: String
    }

    private struct Workarounds: Encodable {
        // `writeDelayMs` is deliberately absent rather than emitted as null: the
        // decoder reads it with `decodeIfPresent`, so absence and null mean the
        // same thing, and a generator has measured nothing that would justify one.
        let saveAfterWrite: Bool
        let revertsAfterWrite: Bool
        let reportsUnsupportedAsSupported: Bool
    }
}
