import Foundation

// The DDC/CI capabilities string (command 0xF3, reply 0xE3), parsed.
//
// A monitor's capabilities string is meant to look like this:
//
//   (prot(monitor)type(lcd)model(MA320U)cmds(01 02 03 07 0C E3 F3)
//    vcp(02 04 10 12 14(01 05 08 0B) 60(11 12 0F))mccs_ver(2.2))
//
// Real ones frequently do not. The tolerance rules below are not defensive
// programming in the abstract — each one is a verbatim string off real hardware:
//
//   1. Never throw, never crash, always return a result. ddcutil has both
//      `assert`-aborted and segfaulted (fixed in 2.2.0) on strings monitors
//      actually send. The outcome is modelled as valid / usable / invalid plus
//      diagnostics plus the raw text, so a broken string is data, not an error.
//   2. Outer parens are decoration. The Apple Cinema Display A1082 omits them.
//   3. Per-segment recovery, the most important rule. ddcutil aborts the whole
//      parse on one bad segment: the ASUS MG279 emits `model LCDPB287` with the
//      value unparenthesized, and ddcutil consequently loses `cmds`, `vcp` AND
//      `mccs_ver` out of an otherwise perfect string. One bad segment costs one
//      segment here.
//   4. Greedy hex tokenizing, in `vcp()` and in nested value lists. The AOC
//      C24G2 emits `cmds(010203070C4EF3E3)` and `14(010506080B)` with no spaces
//      anywhere. Value lists nest arbitrarily deep — the Lenovo Legion 27U-10
//      emits `F7(01(01) 02 09(01 02(00 03 04 05 06) …))`.
//   5. Unknown segments are ignored, preserved and logged. The spec's own rule is
//      that "generic host SW shall discard any unsupported capability fields".
//      Real ones to survive: `UM69cmds` (LG 29UM69G's misspelt cmds),
//      `vcp_p02`/`vcp_p10` (NEC P241W), `mpu`, `mswhql`, `asset_eep`, `window1`.
//   6. Non-printable bytes are filtered out and marked degraded.
//   7. `mccs_ver` is lenient and never fatal, and never treated as truth:
//      monitors contradict feature 0xDF freely.
//   8. Input is capped before parsing. ddcutil's fixed 2048-byte accumulator
//      asserts on overflow; that is a real crash vector, not a hypothetical one.
//
// And what the result may be used for is limited on purpose — see
// `DDCFeatureDiscovery`: a capabilities string may only *widen* what Crisp
// offers, never narrow it, because a well-formed parse is not evidence of
// support. The LG 27MD5KL advertises dozens of features of which three answer.
// ddcui greys controls out from this string; that is the counter-example.
//
// Pure Foundation, so it compiles into the headless `CrispTests` target and into
// `crispctl` (AGENTS.md §3.6). The I/O half — the 0xF3/0xE3 fragment exchange —
// is `DDCCapabilitiesReader` at the bottom of this file plus
// `DDCProtocolEngine.readCapabilities`, which owns the transport.

// MARK: - Result

/// A parsed capabilities string: what was extracted, how much of it can be
/// trusted, and the original text.
struct DDCCapabilities: Equatable, Sendable {

    /// How much of the string parsed cleanly.
    ///
    /// Three levels rather than a Bool because the middle one is the common case
    /// on real hardware, and because "invalid" must not read as "the read
    /// failed": a monitor that returns nothing at all is reporting a fact.
    enum Validity: String, Equatable, Sendable {
        /// Every segment parsed, nothing was dropped, nothing was repaired.
        /// Unknown segment *names* do not lower this: discarding unsupported
        /// fields is what the spec tells hosts to do, so a string full of them is
        /// still a well-formed string.
        case valid
        /// Something was repaired, dropped or truncated, and the rest parsed.
        case usable
        /// Nothing usable came out. Includes the empty string.
        case invalid
    }

    /// One `name(value)` pair, in the order the monitor emitted it.
    struct Segment: Equatable, Sendable {
        let name: String
        let value: String
        /// This parser interprets the name (`prot`, `type`, `model`, `cmds`,
        /// `vcp`, `mccs_ver`). Everything else is carried, reported and ignored.
        let recognized: Bool
        /// The segment needed repair — an unbalanced paren, or a value the
        /// monitor never parenthesized.
        let degraded: Bool
    }

    /// One VCP code from `vcp()`, with the value list it carries. Recursive
    /// because value lists nest: `F7(01(01) 02 09(01 02(00 03 04 05 06)))`.
    struct Feature: Equatable, Sendable {
        let code: UInt8
        let values: [Feature]

        init(code: UInt8, values: [Feature] = []) {
            self.code = code
            self.values = values
        }

        var codeText: String { String(format: "0x%02X", code) }
    }

    /// Exactly what came off the wire, before any filtering. Shown verbatim in
    /// the diagnostics report: the raw string is the evidence, everything else
    /// here is this parser's opinion about it.
    let raw: String
    let validity: Validity
    let segments: [Segment]
    /// Top-level codes from `vcp()`, in emission order.
    let features: [Feature]
    /// Codes from `cmds()` — the DDC/CI *commands* the monitor answers (0x01
    /// VCP request, 0xF3 capabilities request …), not VCP feature codes.
    let commands: [UInt8]
    /// `mccs_ver()`, when it parsed and was not absurd.
    let mccsVersion: MCCSVersion?
    /// Everything worth telling a human, in the order it was noticed.
    let diagnostics: [String]

    /// The names this parser understands. Anything else is preserved and logged.
    static let recognizedSegmentNames: Set<String> = ["prot", "type", "model", "cmds", "vcp", "mccs_ver"]

    /// Nothing was extracted. Not an error: the Samsung S32D850 answers the
    /// capabilities request with a zero-length string, which is a fact about the
    /// monitor rather than a failure of the read.
    var isEmpty: Bool { segments.isEmpty && features.isEmpty && commands.isEmpty }

    func segment(_ name: String) -> Segment? { segments.first { $0.name == name } }

    var model: String? { segment("model")?.value }
    var monitorType: String? { segment("type")?.value }
    var protocolName: String? { segment("prot")?.value }

    /// Segments this parser does not interpret, preserved for the report.
    var unknownSegments: [Segment] { segments.filter { !$0.recognized } }

    /// Every VCP code the string advertises, at the top level of `vcp()`.
    var advertisedCodes: [UInt8] { features.map(\.code) }

    /// Whether the string advertises a code.
    ///
    /// Only ever an argument *for* offering a feature. `false` means the string
    /// does not mention it, which is not evidence of anything: the HP LP2480zx
    /// omits 0x10 and supports brightness perfectly well.
    func advertises(_ vcp: UInt8) -> Bool { features.contains { $0.code == vcp } }

    func feature(_ vcp: UInt8) -> Feature? { features.first { $0.code == vcp } }
}

// MARK: - Parsing

extension DDCCapabilities {

    /// The most bytes that will be parsed. ddcutil's fixed 2048-byte accumulator
    /// asserts when a monitor overflows it; the cap is here so that a monitor
    /// streaming an endless string costs a truncated result, never the app.
    static let maxLength = 4096

    /// The deepest a `vcp()` value list may nest before the parser stops
    /// recursing. Value lists genuinely nest three deep on real hardware; a
    /// string of 2000 open parens is not a monitor, it is a wedged controller,
    /// and recursing on it would overflow the stack.
    static let maxNestingDepth = 8

    /// Parses a capabilities string. Never throws, never traps, always returns.
    ///
    /// - Parameter transferNotes: anything the fragment exchange itself noticed
    ///   (a truncated transfer, a monitor that stopped answering). Carried into
    ///   the result's diagnostics because from a reader's point of view "the
    ///   string is short because the monitor stopped talking" and "the string is
    ///   short because it is short" are the same symptom and different faults.
    static func parse(_ raw: String, transferNotes: [String] = []) -> DDCCapabilities {
        var notes = transferNotes
        var degraded = !transferNotes.isEmpty

        let text = sanitized(raw, notes: &notes, degraded: &degraded)
        guard !text.isEmpty else {
            notes.append("the capabilities string is empty — the monitor answered with no capabilities data")
            return DDCCapabilities(
                raw: raw, validity: .invalid, segments: [], features: [],
                commands: [], mccsVersion: nil, diagnostics: notes
            )
        }

        let body = stripOuterParentheses(text, notes: &notes, degraded: &degraded)
        let segments = scanSegments(Array(body), notes: &notes, degraded: &degraded)

        var features: [Feature] = []
        var commands: [UInt8] = []
        var mccsVersion: MCCSVersion?
        for segment in segments {
            switch segment.name {
            case "vcp":
                features += parseFeatureList(Array(segment.value), notes: &notes, degraded: &degraded)
            case "cmds":
                commands += parseHexBytes(segment.value, context: "cmds", notes: &notes, degraded: &degraded)
            case "mccs_ver":
                mccsVersion = MCCSVersion.parse(segment.value)
                if mccsVersion == nil {
                    // Never fatal: the field is a claim, and a monitor that gets
                    // its own version wrong still answers VCP reads correctly.
                    notes.append("mccs_ver(\(segment.value)) is not a version VESA has published — ignored")
                }
            default:
                guard !segment.recognized else { continue }
                notes.append("unsupported capability field \"\(segment.name)\" — preserved and ignored, per the DDC/CI spec")
            }
        }

        let validity: Validity = segments.isEmpty ? .invalid : (degraded ? .usable : .valid)
        return DDCCapabilities(
            raw: raw, validity: validity, segments: segments, features: features,
            commands: commands, mccsVersion: mccsVersion, diagnostics: notes
        )
    }

    // MARK: Stage 1 — bound and clean the input

    /// Caps the length, drops anything that is not printable ASCII, and trims.
    private static func sanitized(_ raw: String, notes: inout [String], degraded: inout Bool) -> String {
        var bytes = Array(raw.utf8)
        if bytes.count > maxLength {
            notes.append("capabilities string is \(bytes.count) bytes — truncated to \(maxLength) before parsing")
            bytes = Array(bytes.prefix(maxLength))
            degraded = true
        }
        let printable = bytes.filter { (0x20...0x7E).contains($0) }
        if printable.count != bytes.count {
            notes.append("\(bytes.count - printable.count) non-printable byte(s) removed before parsing")
            degraded = true
        }
        // Cannot fail: every remaining byte is in 0x20–0x7E, which is valid ASCII
        // by construction. The `?? ""` is the type system's price, not a case.
        let text = String(bytes: printable, encoding: .ascii) ?? ""
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Strips the wrapping parens when they are there and balanced.
    ///
    /// The Apple Cinema Display A1082 omits them entirely, so their absence is
    /// not an error; a leading `(` with no partner is, and costs only itself.
    private static func stripOuterParentheses(_ text: String, notes: inout [String], degraded: inout Bool) -> String {
        guard text.hasPrefix("(") else { return text }
        if text.hasSuffix(")"), isBalanced(text) {
            return String(text.dropFirst().dropLast())
        }
        notes.append("leading '(' has no matching ')' — dropped, and parsing continued on the rest")
        degraded = true
        return String(text.dropFirst())
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }

    // MARK: Stage 2 — segments

    /// Splits the body into `name(value)` segments, recovering from the two
    /// deviations real monitors ship: a value that was never parenthesized, and
    /// a `(` that never closes.
    private static func scanSegments(
        _ chars: [Character], notes: inout [String], degraded: inout Bool
    ) -> [Segment] {
        var segments: [Segment] = []
        var index = 0
        while index < chars.count {
            guard let name = readName(chars, from: &index) else { continue }
            if index < chars.count, chars[index] == "(" {
                let scan = readParenthesizedValue(chars, from: index)
                segments.append(segment(name: name, value: scan.value, degraded: scan.unbalanced))
                guard scan.unbalanced else {
                    index = scan.end
                    continue
                }
                notes.append("segment \"\(name)\" has an unbalanced '(' — value taken to the end of the string")
                degraded = true
                // Recovery is what separates this from ddcutil's behaviour: the
                // text the runaway segment swallowed is still scanned for the
                // next `name(`, so one unterminated segment costs one segment
                // instead of costing the rest of the string.
                guard let resume = recoveryIndex(chars, after: index + 1) else { break }
                index = resume
                continue
            }
            // No paren. Either the value was never parenthesized (ASUS MG279's
            // `model LCDPB287`) or this name simply has no value.
            let value = readBareValue(chars, from: &index)
            if let value {
                notes.append("segment \"\(name)\" has an unparenthesized value \"\(value)\" — accepted anyway")
                degraded = true
            }
            segments.append(segment(name: name, value: value ?? "", degraded: value != nil))
        }
        return segments
    }

    private static func segment(name: String, value: String, degraded: Bool) -> Segment {
        Segment(
            name: name,
            value: value.trimmingCharacters(in: .whitespaces),
            recognized: recognizedSegmentNames.contains(name),
            degraded: degraded
        )
    }

    /// Reads a segment name, skipping separators. Returns nil when the character
    /// at `index` was only a separator, having advanced past it.
    private static func readName(_ chars: [Character], from index: inout Int) -> String? {
        while index < chars.count, chars[index].isWhitespace || chars[index] == ")" || chars[index] == "," {
            index += 1
        }
        let start = index
        while index < chars.count, !isSeparator(chars[index]) {
            index += 1
        }
        guard index > start else {
            // Not a separator and not a name character: an unexpected '(' at the
            // head of a segment. Skip it rather than loop forever on it.
            if index < chars.count { index += 1 }
            return nil
        }
        return String(chars[start..<index])
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "(" || character == ")" || character == ","
    }

    /// Reads a `(...)` value, tracking nesting. `unbalanced` means the string ran
    /// out before the paren closed, in which case `end` is the end of the string.
    private static func readParenthesizedValue(
        _ chars: [Character], from openIndex: Int
    ) -> (value: String, end: Int, unbalanced: Bool) {
        var depth = 0
        var index = openIndex
        let start = openIndex + 1
        while index < chars.count {
            if chars[index] == "(" { depth += 1 }
            if chars[index] == ")" {
                depth -= 1
                if depth == 0 { return (String(chars[start..<index]), index + 1, false) }
            }
            index += 1
        }
        return (String(chars[start...]), chars.count, true)
    }

    /// Reads an unparenthesized value, if the next token is one.
    ///
    /// The ambiguity is real: in `model LCDPB287 cmds(01 02)` the token after
    /// `model` is its value, but the token after that is the next segment's name.
    /// The tell is what follows — a name is followed by `(`, a value is not.
    private static func readBareValue(_ chars: [Character], from index: inout Int) -> String? {
        var probe = index
        while probe < chars.count, chars[probe].isWhitespace { probe += 1 }
        let start = probe
        while probe < chars.count, !isSeparator(chars[probe]) { probe += 1 }
        guard probe > start else { return nil }
        // Followed by '(' → it is the next segment's name, not this one's value.
        if probe < chars.count, chars[probe] == "(" { return nil }
        index = probe
        return String(chars[start..<probe])
    }

    /// Where to resume after an unterminated segment: the next thing that looks
    /// like a segment name followed by `(`.
    ///
    /// "Looks like a name" means at least two characters and at least one letter
    /// that is not a hex digit. Without that test the scan would resume inside a
    /// hex value list — `14(01 05)` would come back as a segment called "14" —
    /// and the recovery would manufacture nonsense out of the data it is trying
    /// to rescue.
    private static func recoveryIndex(_ chars: [Character], after start: Int) -> Int? {
        var index = min(start, chars.count)
        while index < chars.count {
            while index < chars.count, isSeparator(chars[index]) { index += 1 }
            let tokenStart = index
            while index < chars.count, !isSeparator(chars[index]) { index += 1 }
            guard index > tokenStart else { continue }
            let token = String(chars[tokenStart..<index])
            if index < chars.count, chars[index] == "(", looksLikeSegmentName(token) {
                return tokenStart
            }
        }
        return nil
    }

    private static func looksLikeSegmentName(_ token: String) -> Bool {
        token.count >= 2 && token.contains { $0.isLetter && !$0.isHexDigit }
    }

    // MARK: Stage 3 — hex

    /// Greedy hex tokenizing over whitespace-separated runs.
    ///
    /// The AOC C24G2 sends `cmds(010203070C4EF3E3)` with no spaces at all, so the
    /// run length is the only signal: pair greedily, accept a lone digit as a
    /// zero-padded byte, and drop a trailing nibble rather than inventing one.
    static func parseHexBytes(
        _ text: String, context: String, notes: inout [String], degraded: inout Bool
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        for run in text.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            guard run.allSatisfy({ $0.isHexDigit }) else {
                notes.append("\(context): \"\(run)\" is not hexadecimal — skipped")
                degraded = true
                continue
            }
            bytes += hexPairs(Array(run), context: context, notes: &notes, degraded: &degraded)
        }
        return bytes
    }

    private static func hexPairs(
        _ digits: [Character], context: String, notes: inout [String], degraded: inout Bool
    ) -> [UInt8] {
        var digits = digits
        if digits.count > 1, !digits.count.isMultiple(of: 2) {
            notes.append("\(context): \"\(String(digits))\" has an odd number of hex digits — trailing nibble dropped")
            degraded = true
            digits.removeLast()
        }
        if digits.count == 1 {
            // A lone digit is a zero-padded byte: `9` means 0x09.
            return UInt8(String(digits[0]), radix: 16).map { [$0] } ?? []
        }
        return stride(from: 0, to: digits.count, by: 2).compactMap {
            UInt8(String(digits[$0...$0 + 1]), radix: 16)
        }
    }

    // MARK: Stage 4 — the vcp() list

    /// Parses `vcp()`'s contents: hex codes, any of which may own a nested value
    /// list, to any depth up to `maxNestingDepth`.
    private static func parseFeatureList(
        _ chars: [Character], notes: inout [String], degraded: inout Bool
    ) -> [Feature] {
        var index = 0
        return parseFeatures(chars, from: &index, depth: 0, notes: &notes, degraded: &degraded)
    }

    private static func parseFeatures(
        _ chars: [Character], from index: inout Int, depth: Int,
        notes: inout [String], degraded: inout Bool
    ) -> [Feature] {
        var features: [Feature] = []
        while index < chars.count {
            while index < chars.count, chars[index].isWhitespace || chars[index] == "," { index += 1 }
            guard index < chars.count else { break }
            if chars[index] == ")" {
                index += 1
                return features
            }
            let start = index
            while index < chars.count, chars[index].isHexDigit { index += 1 }
            guard index > start else {
                skipJunk(chars, from: &index, notes: &notes, degraded: &degraded)
                continue
            }
            var bytes = hexPairs(Array(chars[start..<index]), context: "vcp", notes: &notes, degraded: &degraded)
            guard index < chars.count, chars[index] == "(", let owner = bytes.popLast() else {
                features += bytes.map { Feature(code: $0) }
                continue
            }
            // The run runs straight into '(' with no separator — `…C9CA60(01 0F)`
            // on the AOC — so the last byte of the run owns the list and the
            // bytes before it are codes in their own right.
            features += bytes.map { Feature(code: $0) }
            index += 1
            features.append(Feature(
                code: owner,
                values: nestedValues(chars, from: &index, depth: depth, notes: &notes, degraded: &degraded)
            ))
        }
        return features
    }

    private static func nestedValues(
        _ chars: [Character], from index: inout Int, depth: Int,
        notes: inout [String], degraded: inout Bool
    ) -> [Feature] {
        guard depth < maxNestingDepth else {
            notes.append("vcp: value list nested deeper than \(maxNestingDepth) — the rest of it was not read")
            degraded = true
            skipToClose(chars, from: &index)
            return []
        }
        return parseFeatures(chars, from: &index, depth: depth + 1, notes: &notes, degraded: &degraded)
    }

    /// Skips a token that is neither hex nor structure, e.g. the `mccs_ver` that
    /// ends up inside a `vcp()` value when an earlier paren never closed.
    private static func skipJunk(
        _ chars: [Character], from index: inout Int, notes: inout [String], degraded: inout Bool
    ) {
        let start = index
        while index < chars.count, !chars[index].isWhitespace, chars[index] != "(", chars[index] != ")" {
            index += 1
        }
        if index == start { index += 1 }
        notes.append("vcp: \"\(String(chars[start..<index]))\" is not a VCP code — skipped")
        degraded = true
    }

    private static func skipToClose(_ chars: [Character], from index: inout Int) {
        var depth = 1
        while index < chars.count, depth > 0 {
            if chars[index] == "(" { depth += 1 }
            if chars[index] == ")" { depth -= 1 }
            index += 1
        }
    }
}

// MARK: - Fragment reassembly

/// The 0xF3/0xE3 capabilities transfer, as a pure state machine.
///
/// The transport belongs to `DDCProtocolEngine`; the *rules* belong here, where
/// they can be tested without a monitor. They are worth stating because each one
/// is a way the transfer goes wrong in the field:
///
/// - The reply carries the offset it is answering. A monitor that answers a
///   different offset is not confused, it is answering an *earlier* request, and
///   appending it silently corrupts the string. So the offset must match.
/// - **A zero-data fragment is the only end-of-string signal the spec defines.**
///   Inferring completion from "this fragment was shorter than 32 bytes" is a
///   common shortcut and it truncates strings on monitors that answer short.
/// - Both the fragment count and the total length are capped, because "the
///   monitor stops saying it is finished" is a real failure mode and an
///   unbounded accumulator is how ddcutil's assert got hit.
struct DDCCapabilitiesReader: Equatable {

    /// Data bytes a single reply can carry (a 38-byte frame minus the six bytes
    /// of framing). Only used to bound `maxFragments`; the reader itself accepts
    /// whatever length a fragment actually has.
    static let fragmentDataLength = 32
    static let maxFragments = DDCCapabilities.maxLength / fragmentDataLength + 8

    /// What the caller should do next.
    enum Outcome: Equatable {
        /// Ask for this offset next.
        case needMore(offset: UInt16)
        /// The string is complete; read `text`.
        case complete
        /// Stop. The accumulated text is still readable and may still be worth
        /// parsing, but the transfer itself did not finish cleanly.
        case failed(reason: String)
    }

    private(set) var bytes: [UInt8] = []
    private(set) var fragmentCount = 0
    /// The offset the next reply must carry.
    private(set) var offset: UInt16 = 0
    private(set) var diagnostics: [String] = []

    init() {}

    /// The bytes so far, as text.
    ///
    /// UTF-8 first because a well-behaved monitor sends ASCII, which is a subset;
    /// Latin-1 as the fallback because it is total — every byte sequence decodes
    /// — so a monitor emitting a stray high byte costs one odd character rather
    /// than the whole transfer. The parser filters to printable ASCII afterwards
    /// either way.
    var text: String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// Folds one 0xE3 reply in.
    mutating func accept(offset replyOffset: UInt16, data: [UInt8]) -> Outcome {
        fragmentCount += 1
        guard fragmentCount <= Self.maxFragments else {
            return .failed(reason: "monitor sent more than \(Self.maxFragments) capability fragments without ending the string")
        }
        guard replyOffset == offset else {
            return .failed(reason: "monitor answered offset \(replyOffset) for a request at offset \(offset)")
        }
        // Per spec this, and only this, ends the string.
        if data.isEmpty { return .complete }
        // The Samsung S32D850 answers the first request with a zero-filled frame.
        // That is "no capabilities", which is an answer, not a failure.
        if fragmentCount == 1, data.allSatisfy({ $0 == 0 }) {
            diagnostics.append("monitor answered the first capabilities fragment with zero bytes — it reports no capabilities")
            return .complete
        }

        bytes += data
        if bytes.count >= DDCCapabilities.maxLength {
            bytes = Array(bytes.prefix(DDCCapabilities.maxLength))
            diagnostics.append("capabilities string reached the \(DDCCapabilities.maxLength)-byte cap — stopped reading")
            return .complete
        }
        guard let next = UInt16(exactly: Int(offset) + data.count) else {
            return .failed(reason: "capabilities offset overflowed 16 bits")
        }
        offset = next
        return .needMore(offset: next)
    }
}
