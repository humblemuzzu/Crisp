import XCTest

/// Headless tests for trust-on-first-use over the TVs' self-signed certificates.
///
/// `TVTrust.swift` is compiled directly into this target (see `project.yml`), so
/// the interesting case — the certificate changed since pairing — is a unit test
/// rather than something you would have to stage a man-in-the-middle to reach.
/// Each test names the mutation it is designed to kill.
final class TVTrustTests: XCTestCase {

    /// A plaintext port has no certificate, and that is *not* the same as trusted.
    /// Kills mutation: collapsing "no TLS" into "matched", which would let the
    /// first plaintext connection overwrite a pinned fingerprint with nothing.
    func testPlaintextIsNotEncryptedRatherThanTrusted() {
        let decision = TVTrust.evaluate(presented: nil, recorded: "aabb", isEncrypted: false)
        XCTAssertEqual(decision, .notEncrypted)
        XCTAssertTrue(decision.permitsConnection)
        XCTAssertNil(decision.fingerprintToRecord)
    }

    /// First sight pins, and only first sight writes.
    /// Kills mutation: recording on every connection, which is a Keychain write
    /// per action — and worse, makes the "never silently re-pin" rule depend on
    /// the caller rather than on the decision.
    func testFirstUsePinsAndOnlyFirstUseRecords() {
        let first = TVTrust.evaluate(presented: "AABB", recorded: nil, isEncrypted: true)
        XCTAssertEqual(first, .pinOnFirstUse(fingerprint: "aabb"))
        XCTAssertEqual(first.fingerprintToRecord, "aabb")

        let again = TVTrust.evaluate(presented: "aabb", recorded: "aabb", isEncrypted: true)
        XCTAssertEqual(again, .matched(fingerprint: "aabb"))
        XCTAssertNil(again.fingerprintToRecord, "an identical fingerprint is not worth rewriting")
    }

    /// **The whole point of the file.** A different certificate is refused, and it
    /// is never quietly re-pinned.
    /// Kills mutation: returning `.pinOnFirstUse` on a mismatch (a silent re-pin,
    /// which is exactly equivalent to not checking at all), or returning
    /// `.matched` (which is what every other client on the market does by turning
    /// validation off entirely).
    func testAChangedCertificateIsRefusedAndNotRepinned() {
        let decision = TVTrust.evaluate(presented: "ffff", recorded: "aabb", isEncrypted: true)
        XCTAssertEqual(decision, .refused(expected: "aabb", presented: "ffff"))
        XCTAssertFalse(decision.permitsConnection)
        XCTAssertNil(decision.fingerprintToRecord)
        XCTAssertEqual(decision.error, .certificateChanged(expected: "aabb", presented: "ffff"))
    }

    /// TLS whose certificate could not be digested is refused, not treated as
    /// plaintext.
    /// Kills mutation: inferring "not encrypted" from `presented == nil`, which
    /// would turn "the certificate could not be read" into a pass — the one
    /// substitution an attacker would actually try.
    func testAnUnreadableCertificateOnATLSPortIsRefused() {
        for presented in [nil, "", "  ", "not-hex-at-all"] as [String?] {
            let decision = TVTrust.evaluate(presented: presented, recorded: "aabb", isEncrypted: true)
            XCTAssertEqual(decision, .unreadableCertificate, "presented=\(presented ?? "nil")")
            XCTAssertFalse(decision.permitsConnection)
        }
    }

    /// One spelling per certificate: `AA:BB` and `aabb` are the same fingerprint.
    /// Kills mutation: comparing raw strings, so a pasted or re-formatted
    /// fingerprint would refuse a television the user is correctly paired with.
    func testFingerprintsAreNormalisedBeforeComparison() {
        XCTAssertEqual(
            TVTrust.evaluate(presented: "AA:BB:CC", recorded: "aabbcc", isEncrypted: true),
            .matched(fingerprint: "aabbcc")
        )
        XCTAssertEqual(
            TVTrust.evaluate(presented: "SHA256:aa bb cc", recorded: "AABBCC", isEncrypted: true),
            .matched(fingerprint: "aabbcc")
        )
    }

    /// A recorded value that is not a usable fingerprint re-pins rather than
    /// refusing forever.
    /// Kills mutation: treating unreadable stored state as a mismatch, which
    /// would leave the user with a TV they can never connect to and no fix short
    /// of deleting the device.
    func testUnreadableStoredStateRepinsRatherThanLockingTheUserOut() {
        let decision = TVTrust.evaluate(presented: "aabb", recorded: "zzzz", isEncrypted: true)
        XCTAssertEqual(decision, .pinOnFirstUse(fingerprint: "aabb"))
    }

    /// The refusal reads as an instruction, not as a stack trace.
    /// Kills mutation: a message that says "certificate error" and leaves the
    /// user with no idea that removing and re-adding the TV is the fix.
    func testTheRefusalMessageTellsTheUserWhatToDo() {
        let message = TVTransportError.certificateChanged(expected: "a", presented: "b").message
        XCTAssertTrue(message.contains("different certificate"))
        XCTAssertTrue(message.contains("add it again"))
    }

    /// A fingerprint shown to a person is groupable by eye.
    /// Kills mutation: printing 64 unbroken hex characters, which nobody can
    /// compare against another 64 unbroken hex characters.
    func testFormattedFingerprintIsReadable() {
        XCTAssertEqual(TVTrust.formatted("aabbcc"), "AA:BB:CC")
        XCTAssertEqual(TVTrust.formatted("a"), "A")
        XCTAssertEqual(TVTrust.formatted(""), "")
    }
}
