import Foundation

// Trust-on-first-use for the TVs' self-signed TLS certificates.
//
// **The problem, stated honestly.** webOS port 3001 and Tizen port 8002 are TLS,
// and both present a self-signed certificate. There is no published root to
// chain to — LG and Samsung do not operate one for these — so ordinary
// validation cannot succeed on any TV, ever. Every client that exists deals with
// this by disabling validation outright: `verify_mode = CERT_NONE`,
// `rejectUnauthorized: false`, an `URLSessionDelegate` that answers
// `.useCredential` unconditionally. That turns the TLS into obfuscation: anyone
// on the LAN can present any certificate and be believed.
//
// **What this does instead, and exactly what it buys.** The first time a TV is
// paired, the SHA-256 of the certificate it presented is recorded next to its
// credential in the Keychain. Every later connection compares. A mismatch is
// refused and *said out loud*; it is never silently re-pinned, because a silent
// re-pin is the same thing as not checking.
//
// **What it does not buy, said plainly rather than left to be assumed:** this
// authenticates "the same device as the one you paired with", not "an LG
// television" and not "the device at this address". A device that impersonates
// the TV *before* the user ever pairs is trusted, because there is nothing to
// compare against — that is the "first use" in trust-on-first-use, and no amount
// of code here changes it. What it does defend is the interesting case: the TV
// was paired on a trusted network, and something later stands in for it.
//
// Pure Foundation and no I/O: the Keychain read and the socket both live
// elsewhere, which is what makes the mismatch rule a unit test rather than
// something you would have to stage a man-in-the-middle to exercise.

enum TVTrust {

    /// What to do about a certificate a TV just presented.
    enum Decision: Equatable, Sendable {
        /// Plaintext port. There is no certificate, so there is nothing to pin —
        /// distinct from "trusted", and named so a caller cannot mistake one for
        /// the other. webOS 3000 and Tizen 8001 land here.
        case notEncrypted
        /// Nothing was recorded for this device yet: record this fingerprint and
        /// continue. The one-time leap of faith, made explicit so the UI can say
        /// so at pairing time instead of on every connection afterwards.
        case pinOnFirstUse(fingerprint: String)
        /// Same certificate as last time.
        case matched(fingerprint: String)
        /// Different certificate. The connection must not proceed.
        case refused(expected: String, presented: String)
        /// The port was TLS but nothing usable came back from it. Refused rather
        /// than treated as plaintext: "the certificate could not be read" is not
        /// a reason to skip checking it.
        case unreadableCertificate

        /// Whether the caller may go on using the channel.
        var permitsConnection: Bool {
            switch self {
            case .notEncrypted, .pinOnFirstUse, .matched: return true
            case .refused, .unreadableCertificate: return false
            }
        }

        /// The fingerprint to store, when this decision changes what is stored.
        /// `matched` deliberately returns nil: rewriting an identical value is a
        /// Keychain write for no reason.
        var fingerprintToRecord: String? {
            guard case .pinOnFirstUse(let fingerprint) = self else { return nil }
            return fingerprint
        }

        var error: TVTransportError? {
            switch self {
            case .notEncrypted, .pinOnFirstUse, .matched:
                return nil
            case .refused(let expected, let presented):
                return .certificateChanged(expected: expected, presented: presented)
            case .unreadableCertificate:
                return .malformedResponse("the TV's certificate could not be read")
            }
        }
    }

    /// The rule. Pure, ordered, total.
    ///
    /// - Parameters:
    ///   - presented: what the socket saw. `nil` means the port was plaintext;
    ///     an empty or unparseable string means TLS whose certificate could not
    ///     be digested, which is *not* the same thing.
    ///   - recorded: what the Keychain holds for this device, if anything.
    ///   - isEncrypted: whether the channel negotiated TLS at all. Passed
    ///     separately rather than inferred from `presented == nil`, because
    ///     "TLS with an unreadable certificate" has to be distinguishable from
    ///     "no TLS" — inferring it would collapse a refusal into a pass.
    static func evaluate(
        presented: String?,
        recorded: String?,
        isEncrypted: Bool
    ) -> Decision {
        guard isEncrypted else { return .notEncrypted }
        guard let presented = normalized(presented) else { return .unreadableCertificate }
        // A recorded value that is not a usable fingerprint (a hand-edited
        // Keychain item, a truncated write) is treated as *absent* rather than as
        // a mismatch: refusing forever on unreadable state would leave the user
        // with a TV they cannot connect to and no way to fix it that is not
        // "delete the device". Re-pinning is the recoverable answer, and it is
        // still a decision the user sees.
        guard let recorded = normalized(recorded) else {
            return .pinOnFirstUse(fingerprint: presented)
        }
        guard recorded == presented else {
            return .refused(expected: recorded, presented: presented)
        }
        return .matched(fingerprint: presented)
    }

    /// One spelling for a fingerprint, so `AB:CD` and `abcd` cannot be the same
    /// certificate recorded twice and compared as different ones.
    ///
    /// Separators (`:`, `-`, whitespace) and a leading `sha256:` are removed, and
    /// the rest is lowercased — those are the shapes people paste into a support
    /// thread. Then it is **validated**: anything that is not all hex digits is
    /// `nil`, not a best effort.
    ///
    /// That validation is the part that matters. Filtering non-hex characters out
    /// instead would turn `not-hex-at-all` into `eaa` and `SHA256:` into `256`,
    /// so a garbage string would become a perfectly good fingerprint that happens
    /// to match nothing — a refusal the user could never explain, and, on the
    /// stored side, a value that can never be repaired.
    static func normalized(_ fingerprint: String?) -> String? {
        guard let fingerprint else { return nil }
        var text = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let prefix = text.range(of: "sha256:") { text = String(text[prefix.upperBound...]) }
        let stripped = text.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard !stripped.isEmpty, stripped.allSatisfy(\.isHexDigit) else { return nil }
        return stripped
    }

    /// A fingerprint as it should be shown to a person: grouped in pairs so two
    /// of them can actually be compared by eye in a support thread.
    static func formatted(_ fingerprint: String) -> String {
        let hex = normalized(fingerprint) ?? ""
        return stride(from: 0, to: hex.count, by: 2)
            .map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: min(2, hex.count - offset))
                return String(hex[start..<end])
            }
            .joined(separator: ":")
            .uppercased()
    }
}
