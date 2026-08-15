import XCTest

/// Headless tests for the `crisp://` grammar.
///
/// `CrispURL` is text in, a command or a refusal out, which is what lets a
/// hostile URL be tested here — with no URL handler registered, no app running
/// and no monitor attached. Each test names the mutation it is designed to kill.
///
/// The three properties under test are the ones a URL scheme gets wrong:
/// a destructive feature cannot be applied from a link, anything outside the
/// grammar is a quiet no-op, and nothing is coerced into being writable.
final class CrispURLTests: XCTestCase {

    private let uuid = "AEB55F97-FD93-4F8D-AD10-0942959D069C"
    private var attached: Set<DisplayUUID> { [DisplayUUID(uuid)] }

    private func command(_ string: String) -> CrispURLCommand {
        guard let url = URL(string: string) else {
            return .ignored(reason: "test URL did not parse: \(string)")
        }
        return CrispURL.command(for: url)
    }

    private func request(_ string: String) -> AutomationRequest? {
        guard case .write(let request) = command(string) else { return nil }
        return request
    }

    // MARK: - The destructive rule, end to end

    /// *The property the scheme lives or dies on.* A link asking for an input
    /// switch parses — and its plan is `needsConfirmation`, never `.ready`, so
    /// nothing can reach the transport without the dialog.
    /// Kills mutation: "let `CrispURL` mark a request pre-authorised", and any
    /// future `plan` change that makes a destructive URL directly applicable.
    func testAnInputSwitchFromALinkCannotBeAppliedWithoutConfirmation() {
        guard let request = request("crisp://display/\(uuid)/input?value=17") else {
            return XCTFail("the input URL should parse")
        }
        XCTAssertEqual(request.origin, .url)
        guard case .needsConfirmation = request.plan(attached: attached) else {
            return XCTFail("an input switch from a URL must require confirmation")
        }
    }

    /// A parameter that looks like a bypass is not ignored — it invalidates the
    /// whole URL. Refusing unknown parameters is what makes "there is no bypass
    /// flag" true by construction rather than by review: a `?confirmed=true`
    /// cannot be silently tolerated because it cannot be silently anything.
    /// Kills mutation: "ignore query items other than `value`".
    func testABypassLookingParameterVoidsTheWholeURL() {
        for suffix in ["&confirmed=true", "&force=1", "&trusted=yes"] {
            guard case .ignored = command("crisp://display/\(uuid)/input?value=17\(suffix)") else {
                return XCTFail("a URL carrying \(suffix) must be ignored whole")
            }
        }
    }

    /// Two `value` parameters is ambiguous, and ambiguity in a hostile input is
    /// answered by refusing, not by picking one.
    /// Kills mutation: "take the first (or last) `value`".
    func testDuplicateValueParametersAreRefused() {
        guard case .ignored = command("crisp://display/\(uuid)/brightness?value=10&value=90") else {
            return XCTFail("two value parameters must be refused")
        }
    }

    // MARK: - Malformed URLs are no-ops

    /// Every shape of malformed URL is `.ignored`: no crash, no partial write,
    /// no guess. Listed exhaustively because each one is a real thing a link or
    /// a typo produces.
    /// Kills mutation: any "be lenient here" repair — defaulting a missing value,
    /// trimming a whitespace UUID, treating an unknown feature as brightness.
    func testMalformedURLsAreQuietNoOps() {
        let malformed = [
            "https://example.com/display/\(uuid)/brightness?value=50",   // another scheme entirely
            "crisp://",                                                   // nothing at all
            "crisp://display",                                            // no display, no feature
            "crisp://display/\(uuid)",                                    // no feature
            "crisp://display/\(uuid)/brightness",                         // no value
            "crisp://display/\(uuid)/brightness?value=",                  // empty value
            "crisp://display/\(uuid)/brightness?level=50",                // wrong parameter name
            "crisp://display/\(uuid)/brightness/extra?value=50",          // trailing path
            "crisp://display//brightness?value=50",                       // empty identifier
            "crisp://display/\(uuid)/luminance?value=50",                 // unknown feature
            "crisp://monitor/\(uuid)/brightness?value=50",                // unknown target
            "crisp://display/\(uuid)/brightness?value=fifty",             // not a number
            "crisp://display/\(uuid)/brightness?value=50%25",             // percent sign, decoded
            "crisp://display/\(uuid)/input?value=-1",                     // negative code
            "crisp://display/\(uuid)/input?value=65536",                  // past UInt16
            "crisp://display/\(uuid)/input?value=17.5",                   // fractional code
            "crisp://displays/refresh?value=1",                           // refresh takes nothing
            "crisp://displays/reboot",                                    // unknown action
            "crisp://displays",                                           // no action
            "crisp://preset",                                             // no preset named
            "crisp://preset/",                                            // empty identifier
            "crisp://preset/abc/extra",                                   // trailing path
            "crisp://preset/abc?confirmed=true",                          // a preset takes no parameters
            "crisp://preset/a%20b"                                        // whitespace in the identifier
        ]
        for string in malformed {
            guard case .ignored = command(string) else {
                return XCTFail("\(string) should have been ignored")
            }
        }
    }

    /// A UUID longer than any display identity is refused rather than carried
    /// around. Nothing downstream would match it, but a parser that accepts
    /// unbounded input is one that has never thought about its input.
    /// Kills mutation: "drop the length cap".
    func testAnAbsurdlyLongIdentifierIsRefused() {
        let long = String(repeating: "A", count: CrispURL.maximumIdentifierLength + 1)
        guard case .ignored = command("crisp://display/\(long)/brightness?value=50") else {
            return XCTFail("an over-long identifier should be refused")
        }
        // One character shorter is fine: the cap is a bound, not a shape check.
        let atLimit = String(repeating: "A", count: CrispURL.maximumIdentifierLength)
        XCTAssertNotNil(request("crisp://display/\(atLimit)/brightness?value=50"))
    }

    /// *The cap bounds bytes, because that is the thing an attacker chooses.*
    /// `String.count` counts extended grapheme clusters, and a cluster has no
    /// size limit: one base character plus 200,000 combining marks is `count ==
    /// 1` and ~400KB. Under a `count` cap that string sails through the length
    /// check and gets segmented — the expensive operation — on every `crisp://`
    /// open a web page cares to trigger. It could never reach a DDC write (no
    /// real `DisplayUUID` looks like that), which is why this is a cap that did
    /// not cap rather than a hole; the parser's premise is still that the string
    /// is hostile.
    /// Kills mutation: `text.count <= maximumIdentifierLength`.
    func testACombiningMarkBlobIsRefusedByBytesNotByCharacterCount() {
        // U+0301 COMBINING ACUTE ACCENT is 2 UTF-8 bytes and no grapheme of its
        // own: the whole thing is one character to `count`.
        let blob = "e" + String(repeating: "\u{0301}", count: 4_000)
        XCTAssertEqual(blob.count, 1, "the premise: this is one grapheme cluster")
        XCTAssertGreaterThan(blob.utf8.count, CrispURL.maximumIdentifierLength)

        guard case .ignored(let reason) = command("crisp://display/\(blob)/brightness?value=50") else {
            return XCTFail("an 8KB identifier must be refused however few characters it reports")
        }
        // Named, so this cannot pass because the URL failed to parse for some
        // unrelated reason: the identifier check is what has to reject it.
        XCTAssertTrue(reason.contains("identifier"), "refused for the wrong reason: \(reason)")
    }

    /// *…and a legitimate non-ASCII identifier is still measured, not banned.*
    /// The bound is on size, so a short multi-byte string stays acceptable to the
    /// parser (nothing will match it downstream, which is a different layer's
    /// answer).
    /// Kills mutation: refusing anything non-ASCII outright, or capping
    /// `unicodeScalars.count` and calling it bytes.
    func testAShortMultiByteIdentifierIsStillParsed() {
        let short = "é" + String(repeating: "ü", count: 8)
        XCTAssertLessThanOrEqual(short.utf8.count, CrispURL.maximumIdentifierLength)
        XCTAssertNotNil(request("crisp://display/\(short)/brightness?value=50"))
    }

    /// A whitespace-bearing identifier is refused, not trimmed. Quietly repairing
    /// hostile input is how a parser ends up with two spellings of one thing.
    /// Kills mutation: "trim the identifier before using it".
    func testAWhitespaceIdentifierIsRefusedNotTrimmed() {
        guard case .ignored = command("crisp://display/%20\(uuid)/brightness?value=50") else {
            return XCTFail("an identifier with whitespace should be refused")
        }
    }

    // MARK: - Values

    /// A well-formed brightness link produces exactly the request it looks like:
    /// this display, this feature, this percentage, origin `.url`.
    /// Kills mutation: "hard-code the origin to `.appIntent`", "drop the fragment
    /// order (uuid/feature vs feature/uuid)".
    func testAWellFormedBrightnessURLProducesThatRequest() {
        guard let request = request("crisp://display/\(uuid)/brightness?value=50") else {
            return XCTFail("the brightness URL should parse")
        }
        XCTAssertEqual(request.display, DisplayUUID(uuid))
        XCTAssertEqual(request.feature, .brightness)
        XCTAssertEqual(request.value, .percent(50))
        XCTAssertEqual(request.origin, .url)
    }

    /// Out-of-range percentages parse and are clamped by the plan, rather than
    /// being refused at the door. A link asking for 150 means "as bright as it
    /// goes"; refusing it would be pedantry, and wrapping it would be a bug.
    /// Kills mutation: "clamp in the parser" (which would hide the plan's own
    /// clamp from every other origin), "reject out-of-range values".
    func testOutOfRangeValuesClampThroughThePlan() {
        for (asked, expected) in [("150", 100.0), ("-10", 0.0)] {
            guard let request = request("crisp://display/\(uuid)/brightness?value=\(asked)") else {
                return XCTFail("value=\(asked) should parse")
            }
            guard case .ready(let write) = request.plan(attached: attached) else {
                return XCTFail("value=\(asked) should plan")
            }
            XCTAssertEqual(write.percent, expected)
        }
    }

    /// `Double("nan")` succeeds, so the parser hands a NaN on and the plan is
    /// what refuses it — which is the point: the refusal lives on the path every
    /// origin shares, not in one parser.
    /// Kills mutation: "let the parser accept nan and the plan clamp it" (nan
    /// clamps to 100 in Swift, i.e. full brightness from a malformed link).
    func testNaNParsesButIsRefusedByThePlan() {
        guard let request = request("crisp://display/\(uuid)/brightness?value=nan") else {
            return XCTFail("value=nan parses as a Double, so it should reach the plan")
        }
        guard case .rejected = request.plan(attached: attached) else {
            return XCTFail("a NaN brightness must be refused")
        }
    }

    /// Input codes are raw, and hex is accepted because monitor manuals and this
    /// app's own diagnostics both print codes that way.
    /// Kills mutation: "parse everything as decimal" (0x11 then fails), "parse
    /// everything as hex" (17 becomes 23).
    func testInputCodesParseAsDecimalAndHex() {
        XCTAssertEqual(request("crisp://display/\(uuid)/input?value=17")?.value, .raw(17))
        XCTAssertEqual(request("crisp://display/\(uuid)/input?value=0x11")?.value, .raw(17))
        XCTAssertEqual(request("crisp://display/\(uuid)/input?value=0X11")?.value, .raw(17))
    }

    /// A percentage for input source is not silently converted; it parses as a
    /// raw code when it is an integer, and the plan refuses the shape mismatch
    /// only when it is not. `50` really is a code here — the shape comes from the
    /// registry, not from how the sender spelled the number.
    /// Kills mutation: "decide the value shape from the text" (`50` would be a
    /// percentage for input and a percentage for brightness, which is one of them
    /// wrong).
    func testTheValueShapeComesFromTheFeatureNotTheText() {
        XCTAssertEqual(request("crisp://display/\(uuid)/input?value=50")?.value, .raw(50))
        XCTAssertEqual(request("crisp://display/\(uuid)/brightness?value=50")?.value, .percent(50))
    }

    // MARK: - Spelling

    /// LaunchServices does not promise the case of a scheme or a host, so neither
    /// does the parser. The feature name is matched the same way, since a URL is
    /// typed by hand as often as generated.
    /// Kills mutation: "compare the scheme case-sensitively".
    func testSchemeHostAndFeatureAreCaseInsensitive() {
        XCTAssertNotNil(request("CRISP://DISPLAY/\(uuid)/BRIGHTNESS?value=50"))
        XCTAssertNotNil(request("crisp://Display/\(uuid)/Brightness?value=50"))
        guard case .refreshDisplays = command("CRISP://Displays/Refresh") else {
            return XCTFail("refresh should parse whatever its case")
        }
    }

    /// The identifier itself is *not* case-folded: it is an opaque identity, and
    /// two spellings of one UUID would be two keys in every UUID-keyed store in
    /// the app (AGENTS.md §3.3).
    /// Kills mutation: "lowercase the whole path".
    func testTheDisplayIdentifierKeepsItsCase() {
        XCTAssertEqual(request("crisp://display/\(uuid)/brightness?value=50")?.display, DisplayUUID(uuid))
        XCTAssertNotEqual(
            request("crisp://display/\(uuid.lowercased())/brightness?value=50")?.display,
            DisplayUUID(uuid)
        )
    }

    /// The refresh command reads only and takes nothing, so it needs no display
    /// and no confirmation.
    /// Kills mutation: "route refresh through the write path".
    func testRefreshIsItsOwnCommand() {
        guard case .refreshDisplays = command("crisp://displays/refresh") else {
            return XCTFail("crisp://displays/refresh should be the refresh command")
        }
    }

    // MARK: - crisp://preset/<id>

    /// A well-formed preset link parses to the identifier verbatim, with its
    /// origin carried through. The preset itself is not resolved here — this
    /// parser has no store — so what comes out is a name, not a permission.
    /// Kills mutation: lowercasing the identifier (preset ids are UUID strings
    /// and a link would then match nothing), or dropping the origin.
    func testAWellFormedPresetURLProducesThatCommand() {
        let id = "B67C0FAF-0000-4000-8000-0123456789AB"

        guard case .applyPreset(let parsed, let origin) = command("crisp://preset/\(id)") else {
            return XCTFail("crisp://preset/<id> should be the apply-preset command")
        }
        XCTAssertEqual(parsed, id)
        XCTAssertEqual(origin, .url)
    }

    /// The preset path is bounded like the display path is. Nothing downstream
    /// would match a 200KB identifier, but a parser whose premise is that the
    /// string is hostile does not accept unbounded input on one route and not
    /// the other.
    /// Kills mutation: parsing the preset id without the shared `identifier`
    /// check.
    func testAnAbsurdlyLongPresetIdentifierIsRefused() {
        let long = String(repeating: "A", count: CrispURL.maximumIdentifierLength + 1)

        guard case .ignored = command("crisp://preset/\(long)") else {
            return XCTFail("an over-long preset identifier should be ignored")
        }
    }

    // MARK: - crisp://tv/<device-id>/<feature>

    /// A well-formed TV link parses to a request, with the device identity and
    /// the origin carried through.
    /// Kills mutation: routing a TV URL through the display grammar (whose
    /// features are VCP names), or lowercasing the device identifier — a TV's id
    /// is a `uuid:` string the device chose and a link would then match nothing.
    func testAWellFormedTVURLProducesATVAction() {
        guard case .tvAction(let request) = command("crisp://tv/uuid:AbC-123/volume?value=35") else {
            return XCTFail("crisp://tv/<id>/<feature> should be a TV action")
        }
        XCTAssertEqual(request.device, TVDeviceID("uuid:AbC-123"))
        XCTAssertEqual(request.feature, .volume)
        XCTAssertEqual(request.value, .percent(35))
        XCTAssertEqual(request.origin, .url)
    }

    /// A flag-shaped feature takes on/off, and only the three spellings.
    /// Kills mutation: accepting anything non-empty as true, which would make
    /// `?value=please` turn a television off.
    func testFlagFeaturesAcceptOnlyTheThreeSpellings() {
        for (text, expected) in [("off", false), ("false", false), ("0", false),
                                 ("on", true), ("true", true), ("1", true)] {
            guard case .tvAction(let request) = command("crisp://tv/uuid:1/mute?value=\(text)") else {
                return XCTFail("'\(text)' should parse as a flag")
            }
            XCTAssertEqual(request.value, .flag(expected))
        }
        for text in ["yes", "y", "maybe", "2", ""] {
            guard case .ignored = command("crisp://tv/uuid:1/mute?value=\(text)") else {
                return XCTFail("'\(text)' should not parse as a flag")
            }
        }
    }

    /// Rule 2 applies to the TV grammar too: an unknown parameter refuses the
    /// whole URL rather than being quietly discarded.
    /// Kills mutation: ignoring extra query items, which is one pull request away
    /// from tolerating `?confirmed=true` on the one action that must always ask.
    func testAnUnknownParameterRefusesTheWholeTVURL() {
        for url in [
            "crisp://tv/uuid:1/power?value=off&confirmed=true",
            "crisp://tv/uuid:1/power?confirmed=true",
            "crisp://tv/uuid:1/power"
        ] {
            guard case .ignored = command(url) else {
                return XCTFail("\(url) should be ignored")
            }
        }
    }

    /// A malformed TV URL is a quiet no-op, never a partial action.
    /// Kills mutation: defaulting a missing feature or device to something.
    func testMalformedTVURLsAreIgnored() {
        let long = String(repeating: "A", count: CrispURL.maximumIdentifierLength + 1)
        for url in [
            "crisp://tv", "crisp://tv/uuid:1", "crisp://tv/uuid:1/volume/extra?value=1",
            "crisp://tv//volume?value=1", "crisp://tv/uuid:1/nosuchfeature?value=1",
            "crisp://tv/\(long)/volume?value=1", "crisp://tv/uuid:1/volume?value=abc"
        ] {
            guard case .ignored = command(url) else {
                return XCTFail("\(url) should be ignored")
            }
        }
    }

    /// The TV grammar cannot express consent, so a destructive action still has
    /// to go through the plan — which can only answer `needsConfirmation`.
    /// Kills mutation: any future shortcut in the parser that marks a URL as
    /// pre-approved. This asserts the two layers meet: the URL parses, and the
    /// plan still refuses to make it `.ready`.
    func testADestructiveTVURLStillPlansAsNeedingConfirmation() {
        guard case .tvAction(let request) = command("crisp://tv/uuid:1/power?value=off") else {
            return XCTFail("a power URL should parse")
        }
        let plan = request.plan(known: [TVDeviceID("uuid:1"): .webOS])
        guard case .needsConfirmation = plan else {
            return XCTFail("a TV power-off from a URL planned \(plan)")
        }
    }
}
