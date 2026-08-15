import Foundation

/// A finished calibration session → a quirks entry somebody can actually submit.
///
/// **Why this is not `QuirkEntryGenerator.json(for:)`.** That generator has one
/// contractual property, stated in its own header and asserted in its tests:
/// *nothing it emits is ever `verified`*. It renders a read pass, and a read pass
/// cannot establish what a code is wired to. Calibration is the one path in the
/// app that can — a human switched to the code and said they could see the
/// picture — so its output has to carry `verified` input values, which the other
/// generator is forbidden to produce. Two generators with opposite guarantees is
/// the honest arrangement; one generator with a "trust me" flag is how the
/// guarantee gets lost.
///
/// Everything that is *not* the confidence rule is reused rather than
/// re-derived: `QuirkEntryGenerator.names(displayName:vendor:product:)` splits
/// the display name, `QuirkEntryGenerator.suggestedFileName(vendorName:)` picks
/// the file, `EDIDManufacturer` decodes the PnP id. Only the on-disk `Encodable`
/// mirror is restated, because the other one is `private` — and it emits a
/// deliberately narrower file: this measurement establishes input codes and
/// nothing else, so it writes the `input` feature and no ranges at all.
///
/// Pure Foundation, so `CrispTests` can push the output straight back through
/// `MonitorQuirksFile.decoding` and assert the loader really does read the values
/// as `verified`.
enum InputCalibrationReport {

    /// The confidence this generator emits for a confirmed code.
    ///
    /// A named constant for the same reason `QuirkEntryGenerator.emittedConfidence`
    /// is one: "can this path produce `verified`?" should be answerable by reading
    /// one line, and the two lines should be greppable side by side.
    static let emittedConfidence = QuirkConfidence.verified

    /// What one session established about one monitor.
    struct Subject: Equatable, Sendable {
        let vendor: UInt32
        let product: UInt32
        /// The display's own name as macOS reports it, e.g. "BenQ MA320U".
        let displayName: String?
        /// Confirmed codes, in confirmation order.
        let confirmed: [CalibratedInput]
        /// Codes the user tried and reverted. Not written into the entry — a
        /// revert proves nothing about the port, only about this desk's cabling —
        /// but named in the issue body so a reviewer knows the list was worked
        /// through rather than guessed at.
        let reverted: [UInt16]
        let osVersion: String
        let macModel: String
        let appVersion: String

        init(
            vendor: UInt32,
            product: UInt32,
            displayName: String? = nil,
            confirmed: [CalibratedInput],
            reverted: [UInt16] = [],
            osVersion: String,
            macModel: String,
            appVersion: String
        ) {
            self.vendor = vendor
            self.product = product
            self.displayName = displayName
            self.confirmed = confirmed
            self.reverted = reverted
            self.osVersion = osVersion
            self.macModel = macModel
            self.appVersion = appVersion
        }
    }

    /// The quirks JSON for the confirmed codes.
    ///
    /// Throws if the session confirmed nothing: an entry with an empty `values`
    /// array claims a measurement that did not happen, and the point of this
    /// whole feature is that unmeasured input data stays out of the database.
    static func json(for subject: Subject) throws -> String {
        guard !subject.confirmed.isEmpty else {
            throw QuirkParseError("no input codes were confirmed, so there is nothing to report")
        }
        let names = QuirkEntryGenerator.names(
            displayName: subject.displayName, vendor: subject.vendor, product: subject.product
        )

        let file = File(
            schemaVersion: MonitorQuirksFile.currentSchemaVersion,
            vendor: String(format: "0x%04X", subject.vendor),
            vendorName: names.vendor,
            models: [
                Model(
                    product: String(format: "0x%04X", subject.product),
                    name: names.model,
                    // The *model* stays `reported`: this session measured input
                    // codes, not brightness ranges or write behaviour, and the
                    // model-level value is the default every future feature in
                    // this entry would inherit.
                    confidence: QuirkConfidence.reported.rawValue,
                    notes: modelNotes(subject),
                    features: Features(input: inputFeature(subject))
                )
            ]
        )

        let encoder = JSONEncoder()
        // Same reasoning as `QuirkEntryGenerator.json`: Swift seeds its string
        // hashing per process, so without `.sortedKeys` the same session emits
        // the same entry with the keys shuffled and a contributor who regenerates
        // gets a diff full of nothing.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(file)
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuirkParseError("generated quirks entry was not valid UTF-8")
        }
        return text
    }

    /// The issue/pull-request body, with the JSON inline so the contribution is
    /// one paste.
    static func issueBody(for subject: Subject, json: String) -> String {
        let names = QuirkEntryGenerator.names(
            displayName: subject.displayName, vendor: subject.vendor, product: subject.product
        )
        let fileName = QuirkEntryGenerator.suggestedFileName(vendorName: names.vendor)

        var out: [String] = []
        out.append("## Input-source calibration: \(names.vendor) \(names.model)")
        out.append("")
        out.append("Measured with Crisp \(subject.appVersion)'s input-source calibration wizard "
            + "on macOS \(subject.osVersion) (\(subject.macModel)).")
        out.append("")
        out.append("| VCP 0x60 code | Port | Evidence |")
        out.append("|---|---|---|")
        for entry in subject.confirmed {
            let standard = MCCSInputTable.label(for: entry.code)
                .map { "VESA MCCS calls this \"\($0)\"" } ?? "not named by the VESA MCCS table"
            out.append("| \(entry.code) | \(entry.label) | switched to it and confirmed a picture; \(standard) |")
        }
        out.append("")
        if !subject.reverted.isEmpty {
            let list = subject.reverted.map(String.init).joined(separator: ", ")
            out.append("Codes tried that produced no picture on this unit and were reverted: \(list). "
                + "They are **not** in the entry below: a dead port here may simply be an empty port, "
                + "which says nothing about the model.")
            out.append("")
        }
        out.append("### Proposed entry for `Crisp/Resources/quirks/\(fileName)`")
        out.append("")
        out.append("```json")
        out.append(json)
        out.append("```")
        out.append("")
        out.append("### Why these are `verified`")
        out.append("")
        out.append("Each code above was written to VCP 0x60 with a 15-second auto-revert armed, and a human "
            + "confirmed the panel was showing the Mac before the countdown expired. That is exactly the "
            + "evidence `verified` claims in `Crisp/Resources/quirks/README.md` — a person watched the "
            + "change happen on the physical panel — and it is the only way this app produces it.")
        out.append("")
        out.append("The entry lists no ranges and no workarounds: this session measured input codes only. "
            + "Merge it into an existing model entry rather than replacing one, and leave the model-level "
            + "confidence alone unless you measured the rest too.")
        out.append("")
        return out.joined(separator: "\n")
    }

    // MARK: - Field builders

    private static func inputFeature(_ subject: Subject) -> InputFeature {
        InputFeature(
            // The feature default stays `reported` even though every value under
            // it is verified. `MonitorQuirks`' decoder caps what `input` inherits
            // at `reported` anyway, so a `verified` here would be silently
            // ignored — and writing a value the loader discards is how a schema
            // starts lying.
            confidence: QuirkConfidence.reported.rawValue,
            // Never true: a session confirms the ports this desk has cables in,
            // which is a subset of the ports the model has. Declaring the list
            // complete would stop the app offering the generic VESA codes and
            // take away the only route to the ports still unmapped.
            complete: false,
            notes: "Confirmed with Crisp's input-source calibration wizard: each code was written, "
                + "and a human confirmed the picture came back before the auto-revert fired. "
                + "Only the ports this unit had cables in were reachable, so the list is incomplete.",
            values: subject.confirmed.map { entry in
                InputValueEntry(
                    code: entry.code,
                    label: entry.label,
                    confidence: emittedConfidence.rawValue,
                    notes: "Switched to this code and the panel showed the Mac; the port was named by the "
                        + "person watching it. \(mccsNote(for: entry.code))"
                )
            }
        )
    }

    private static func mccsNote(for code: UInt16) -> String {
        guard let standard = MCCSInputTable.label(for: code) else {
            return "The VESA MCCS table does not name code \(code) at all."
        }
        return "The VESA MCCS table calls code \(code) \"\(standard)\", which is what the standard says "
            + "rather than what this panel does — the label above is the measurement."
    }

    private static func modelNotes(_ subject: Subject) -> String {
        "Input-source codes measured with Crisp \(subject.appVersion)'s calibration wizard on macOS "
            + "\(subject.osVersion) (\(subject.macModel)). Only the input feature was measured here: "
            + "brightness, contrast, volume and the workarounds are untouched by this entry. Check that "
            + "vendorName and name read the way the vendor spells them before merging."
    }

    // MARK: - On-disk shape

    // Mirrors Crisp/Resources/quirks/README.md, and deliberately narrower than
    // `QuirkEntryGenerator`'s: no ranges, no workarounds, because this session
    // measured neither. Encoded rather than string-built so a port name carrying
    // a quote or a backslash cannot produce an entry the loader silently drops.

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
    }

    private struct Features: Encodable {
        let input: InputFeature
    }

    private struct InputFeature: Encodable {
        let confidence: String
        let complete: Bool
        let notes: String
        let values: [InputValueEntry]
    }

    /// A sibling of `InputFeature` rather than a nested `Value`, so the on-disk
    /// mirror stays one level deep.
    private struct InputValueEntry: Encodable {
        let code: UInt16
        let label: String
        let confidence: String
        let notes: String
    }
}
