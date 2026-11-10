import Foundation
import CryptoKit
import Security

/// This phone's long-lived signing key, kept in the Keychain (this device only).
/// Buddies pin it the first time they see it, so nobody else can later send
/// messages or SOS alerts under your name.
enum MeshIdentity {
    private static let account = "com.swastik.nobars.signing-key"

    static func loadOrCreate() -> Curve25519.Signing.PrivateKey {
        if let raw = read(), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        write(key.rawRepresentation)
        return key
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrAccount as String: account,
         kSecAttrService as String: "NoBars"]
    }

    private static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data) {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}
