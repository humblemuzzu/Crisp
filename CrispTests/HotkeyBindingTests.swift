import XCTest

/// Headless tests for the global-shortcut rules.
///
/// `HotkeyBinding` is pure data plus two decisions — is this combination legal,
/// and who already owns it — so all of it runs here without registering anything
/// with Carbon or the window server. Each test names the mutation it kills.
final class HotkeyBindingTests: XCTestCase {

    private let commandOptionB = HotkeyBinding(keyCode: 11, modifiers: [.command, .option])
    private let commandOptionF1 = HotkeyBinding(keyCode: 122, modifiers: [.command, .option])

    // MARK: - What may be registered

    /// A combination with no ⌘/⌥/⌃ is refused. A global hotkey on a bare letter
    /// takes that letter from every app in the session — the user would have to
    /// find this panel again with a keyboard that no longer types B.
    /// Kills mutation: "accept any combination", "count `isEmpty` as the only
    /// failure" (⇧B would then register).
    func testABareKeyIsRefused() {
        for modifiers in [HotkeyModifiers([]), .shift] {
            let binding = HotkeyBinding(keyCode: 11, modifiers: modifiers)
            XCTAssertFalse(binding.isRegisterable, "\(binding.displayString) should not be registerable")
            guard case .failure(.needsModifier) = HotkeyBindings.empty.assigning(binding, to: .brightnessUp) else {
                return XCTFail("\(binding.displayString) should be refused for want of a modifier")
            }
        }
    }

    /// Each of ⌘, ⌥ and ⌃ qualifies on its own, and shift qualifies alongside
    /// one of them.
    /// Kills mutation: "require Command specifically", "require two modifiers".
    func testAnyRealModifierQualifies() {
        for modifiers in [HotkeyModifiers.command, .option, .control, [.shift, .control]] {
            XCTAssertTrue(HotkeyBinding(keyCode: 11, modifiers: modifiers).isRegisterable)
        }
    }

    // MARK: - Conflicts

    /// A combination another action owns is refused, and the refusal names the
    /// owner. Refused rather than moved: silently taking a shortcut away is how a
    /// user ends up with a key that stopped working and nothing to explain it.
    /// Kills mutation: "overwrite the previous owner", "report the conflict
    /// against the action being assigned instead of the owner".
    func testAConflictIsRefusedAndNamesTheOwner() {
        guard case .success(let assigned) =
            HotkeyBindings.empty.assigning(commandOptionB, to: .brightnessUp) else {
            return XCTFail("the first assignment should succeed")
        }
        guard case .failure(.alreadyAssigned(let owner)) =
            assigned.assigning(commandOptionB, to: .volumeUp) else {
            return XCTFail("the second assignment should conflict")
        }
        XCTAssertEqual(owner, .brightnessUp)
        // And the set is unchanged: the refusal cost nothing.
        XCTAssertEqual(assigned[.brightnessUp], commandOptionB)
        XCTAssertNil(assigned[.volumeUp])
    }

    /// Re-recording the same keys for the same action succeeds and changes
    /// nothing. It is what a user does by pressing the combination again, and
    /// reporting "already assigned" against itself would be nonsense.
    /// Kills mutation: "conflict on any existing owner, including the same one".
    func testReassigningAnActionItsOwnShortcutSucceeds() {
        guard case .success(let first) = HotkeyBindings.empty.assigning(commandOptionB, to: .brightnessUp),
              case .success(let again) = first.assigning(commandOptionB, to: .brightnessUp) else {
            return XCTFail("re-recording the same combination should succeed")
        }
        XCTAssertEqual(again, first)
    }

    /// Clearing an action frees its combination for another one, and clearing an
    /// action that has none is a no-op rather than an error.
    /// Kills mutation: "keep the combination reserved after clearing".
    func testClearingFreesTheCombination() {
        guard case .success(let assigned) =
            HotkeyBindings.empty.assigning(commandOptionB, to: .brightnessUp) else {
            return XCTFail("the first assignment should succeed")
        }
        let cleared = assigned.clearing(.brightnessUp)
        XCTAssertNil(cleared[.brightnessUp])
        XCTAssertEqual(cleared.clearing(.volumeMute), cleared)
        guard case .success(let reassigned) = cleared.assigning(commandOptionB, to: .volumeUp) else {
            return XCTFail("the freed combination should be assignable")
        }
        XCTAssertEqual(reassigned[.volumeUp], commandOptionB)
    }

    /// The reverse lookup the OS event dispatch needs: which action owns a
    /// combination, and nil for one nobody does.
    /// Kills mutation: "return the first assignment regardless of the binding".
    func testActionLookupByCombination() {
        guard case .success(let assigned) =
            HotkeyBindings.empty.assigning(commandOptionF1, to: .volumeMute) else {
            return XCTFail("assignment should succeed")
        }
        XCTAssertEqual(assigned.action(for: commandOptionF1), .volumeMute)
        XCTAssertNil(assigned.action(for: commandOptionB))
    }

    /// `assignments` is in `allCases` order, which is what the UI renders and
    /// what the registration loop walks — a dictionary's own order would make
    /// both non-deterministic between runs.
    /// Kills mutation: "return the dictionary's values directly".
    func testAssignmentsAreInDeclarationOrder() {
        var bindings = HotkeyBindings.empty
        for (offset, action) in HotkeyAction.allCases.enumerated().reversed() {
            guard case .success(let next) = bindings.assigning(
                HotkeyBinding(keyCode: UInt16(offset), modifiers: .control), to: action
            ) else { return XCTFail("assignment should succeed") }
            bindings = next
        }
        XCTAssertEqual(bindings.assignments.map(\.action), HotkeyAction.allCases)
    }

    // MARK: - Presentation

    /// Modifiers render in Apple's canonical order (⌃⌥⇧⌘) whatever order they
    /// were inserted in, followed by the key's own label.
    /// Kills mutation: "render in insertion order", "render in bit order".
    func testDisplayStringUsesTheCanonicalModifierOrder() {
        let binding = HotkeyBinding(keyCode: 122, modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘F1")
        XCTAssertEqual(HotkeyBinding(keyCode: 11, modifiers: [.command]).displayString, "⌘B")
    }

    /// An unmapped key code is named, not hidden. A shortcut rendered as an empty
    /// box is one the user cannot recognise or clear.
    /// Kills mutation: "return an empty string for an unknown code".
    func testAnUnknownKeyCodeStillGetsALabel() {
        XCTAssertEqual(HotkeyBinding.keyLabel(for: 250), "Key 250")
        XCTAssertFalse(HotkeyBinding(keyCode: 250, modifiers: .command).displayString.isEmpty)
    }

    // MARK: - Persistence

    /// A round trip through JSON keeps every assignment, and the encoded form is
    /// an object keyed by action name (readable in a bug report, hand-editable)
    /// rather than the flat `[key, value, key, value…]` array an enum-keyed
    /// `Dictionary` encodes as by default.
    /// Kills mutation: "encode `byAction` directly".
    func testRoundTripsThroughJSONAsAKeyedObject() throws {
        var bindings = HotkeyBindings.empty
        guard case .success(let withUp) = bindings.assigning(commandOptionB, to: .brightnessUp),
              case .success(let withMute) = withUp.assigning(commandOptionF1, to: .volumeMute) else {
            return XCTFail("assignments should succeed")
        }
        bindings = withMute

        let data = try JSONEncoder().encode(bindings)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("brightnessUp"), json)
        XCTAssertEqual(try JSONDecoder().decode(HotkeyBindings.self, from: data), bindings)
    }

    /// The settings file is on disk and therefore hand-editable, which makes it
    /// another way in. A modifier-less binding written into it by hand is dropped
    /// at decode rather than registered — a file cannot install a shortcut the UI
    /// would have refused.
    /// Kills mutation: "decode straight into the dictionary" (the bare `B` would
    /// then be registered globally at the next launch).
    func testAHandEditedFileCannotInstallABareKey() throws {
        let json = Data(#"{"brightnessUp":{"keyCode":11,"modifiers":0}}"#.utf8)
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: json)
        XCTAssertNil(decoded[.brightnessUp])
        XCTAssertTrue(decoded.assignments.isEmpty)
    }

    /// Two actions given the same combination by hand: the first in `allCases`
    /// order keeps it, deterministically, and the other is dropped. Which one
    /// survives must not depend on the dictionary's hash order.
    /// Kills mutation: "iterate the decoded dictionary instead of allCases".
    func testAHandEditedDuplicateResolvesInDeclarationOrder() throws {
        let json = Data(
            #"{"volumeUp":{"keyCode":11,"modifiers":1},"brightnessUp":{"keyCode":11,"modifiers":1}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: json)
        XCTAssertEqual(decoded[.brightnessUp]?.keyCode, 11)
        XCTAssertNil(decoded[.volumeUp])
    }

    /// An action name this build does not know (a file from a newer version, or a
    /// typo) is dropped, and everything valid alongside it still loads.
    /// Kills mutation: "throw on an unknown key", which would cost the user every
    /// shortcut because of one bad line.
    func testAnUnknownActionIsDroppedWithoutLosingTheRest() throws {
        let json = Data(
            #"{"teleport":{"keyCode":11,"modifiers":1},"volumeMute":{"keyCode":122,"modifiers":1}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: json)
        XCTAssertEqual(decoded[.volumeMute], HotkeyBinding(keyCode: 122, modifiers: .command))
        XCTAssertEqual(decoded.assignments.count, 1)
    }

    /// Modifier bits this type does not define are masked off at decode, so a
    /// file cannot smuggle in a flag that later gets translated into some other
    /// Carbon modifier.
    /// Kills mutation: "decode the raw value as-is".
    func testUnknownModifierBitsAreMaskedOff() throws {
        let modifiers = try JSONDecoder().decode(HotkeyModifiers.self, from: Data("4294967295".utf8))
        XCTAssertEqual(modifiers, HotkeyModifiers.known)
    }

    /// The default is nothing assigned. An app that claims a system-wide
    /// combination nobody asked for is an app fighting whatever already owns it.
    /// Kills mutation: "seed a default set of shortcuts".
    func testNothingIsAssignedByDefault() {
        XCTAssertTrue(HotkeyBindings.empty.assignments.isEmpty)
        for action in HotkeyAction.allCases {
            XCTAssertNil(HotkeyBindings.empty[action])
        }
    }
}
