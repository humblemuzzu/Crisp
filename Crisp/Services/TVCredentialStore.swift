import Foundation
import Security
import os.log

/// The Keychain home for the two smart-TV secrets and the certificate they are
/// pinned against.
///
/// **Why not `UserDefaults`, and why not `displays.json`.** A webOS client key
/// and a Tizen token are bearer credentials: anything holding one can turn that
/// television off, switch it to a dead input and drive its volume, from anywhere
/// on the network, with no further prompt. `UserDefaults` is a plist in the
/// user's Library that every process running as that user can read; `displays.json`
/// is a file this project actively encourages people to paste into bug reports.
/// Neither is a place for a credential, so neither has a code path to one here —
/// `TVDevice` has no field that could hold a secret, and this file is the only
/// thing in the app that touches `SecItem*`.
///
/// The TOFU certificate fingerprint lives alongside them. It is not secret, but
/// it is the thing an attacker would want to *change*, and putting it in the
/// Keychain means it is protected by the same ACL as the credential it guards
/// rather than by file permissions on a JSON document.
///
/// No private frameworks: `Security` is public API (AGENTS.md §3.1). Nothing here
/// touches WindowServer, and this file is policed by
/// `scripts/check-boundaries.sh` like every other service.
///
/// Every operation is total and non-throwing. A Keychain that refuses (locked,
/// denied, an entitlement mismatch after a re-sign) degrades to "there is no
/// credential", which re-pairs — never to a crash and never to a thrown error a
/// caller has to remember to catch. Persistence must not be able to take the app
/// down (AGENTS.md rule #4).
final class TVCredentialStore: @unchecked Sendable {
    static let shared = TVCredentialStore()

    private static let log = Logger(subsystem: "com.crisp.app", category: "TVCredentialStore")

    /// The `kSecAttrService` every item is filed under. One service, two account
    /// shapes (see `account(for:kind:)`), so "delete everything for this TV" is
    /// two deletes rather than a query that could match somebody else's items.
    private let service: String

    /// What is stored for a device.
    enum Kind: String, Sendable, CaseIterable {
        /// webOS `client-key`, or the Tizen `token`. The bearer credential.
        case credential
        /// SHA-256 of the leaf certificate seen when the device was paired
        /// (`TVTrust`).
        case certificate
    }

    /// The service name is injectable purely so tests can use a throwaway
    /// namespace; production callers use `shared`.
    init(service: String = "com.crisp.app.tv") {
        self.service = service
    }

    // MARK: - Reading

    func value(for device: TVDeviceID, kind: Kind) -> String? {
        var query = baseQuery(device: device, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            // `errSecItemNotFound` is the ordinary "never paired" case and is not
            // worth a log line; anything else is a real refusal worth seeing when
            // a user reports that their TV keeps asking to be paired.
            if status != errSecSuccess && status != errSecItemNotFound {
                Self.log.error("keychain read failed for \(kind.rawValue, privacy: .public): \(status)")
            }
            return nil
        }
        return text
    }

    // MARK: - Writing

    /// Stores (or replaces) one value. `nil` deletes, which is what makes
    /// "forget this TV" one call per kind rather than a separate API.
    @discardableResult
    func set(_ value: String?, for device: TVDeviceID, kind: Kind) -> Bool {
        guard let value, !value.isEmpty else { return delete(device: device, kind: kind) }

        let query = baseQuery(device: device, kind: kind)
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            Self.log.error("keychain update failed for \(kind.rawValue, privacy: .public): \(updateStatus)")
            return false
        }

        var insert = query
        insert[kSecValueData as String] = data
        // The credential is only ever needed while the user is at the Mac
        // driving a television in the same room, so it does not need to survive
        // into a backup or leave this device. `ThisDeviceOnly` also means a
        // restored Time Machine backup re-pairs rather than resurrecting a
        // credential for a TV that may have been factory reset since.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.log.error("keychain add failed for \(kind.rawValue, privacy: .public): \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    @discardableResult
    func delete(device: TVDeviceID, kind: Kind) -> Bool {
        let status = SecItemDelete(baseQuery(device: device, kind: kind) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Everything for one device: what "remove this TV" has to do.
    ///
    /// Leaving the credential behind after the user removed a TV would mean a
    /// re-add silently re-uses a key they thought they had revoked — and on
    /// Tizen, a token the television may have since forgotten, which fails in a
    /// way that looks like the TV is broken.
    func removeAll(for device: TVDeviceID) {
        for kind in Kind.allCases {
            delete(device: device, kind: kind)
        }
    }

    // MARK: - Query shape

    private func baseQuery(device: TVDeviceID, kind: Kind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: device, kind: kind),
            // Off by default in a non-sandboxed app, and switching it on here is
            // what lets a signed rebuild find its own items instead of asking the
            // user to re-pair every television after every build.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// `<device-uuid>` for the credential, `<device-uuid>#cert` for the pinned
    /// fingerprint. A suffix rather than a second service so removing a device
    /// cannot miss one of the two.
    private func account(for device: TVDeviceID, kind: Kind) -> String {
        switch kind {
        case .credential: return device.rawValue
        case .certificate: return "\(device.rawValue)#cert"
        }
    }
}

extension TVCredentialStore {
    /// The stored credential for a device: webOS client key or Tizen token.
    func credential(for device: TVDeviceID) -> String? { value(for: device, kind: .credential) }

    /// The pinned certificate fingerprint, if the device was ever reached over TLS.
    func pinnedCertificate(for device: TVDeviceID) -> String? { value(for: device, kind: .certificate) }

    /// Applies a `TVTrust` decision: records a first-use pin and does nothing for
    /// every other outcome.
    ///
    /// Deliberately the only writer of the fingerprint. A mismatch is refused by
    /// `TVTrust` and never re-pinned here, because a silent re-pin is exactly the
    /// same as not checking — and putting that decision in one place means a
    /// future caller cannot re-pin by passing a flag.
    func record(_ decision: TVTrust.Decision, for device: TVDeviceID) {
        guard let fingerprint = decision.fingerprintToRecord else { return }
        set(fingerprint, for: device, kind: .certificate)
    }
}
