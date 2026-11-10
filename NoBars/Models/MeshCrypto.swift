import Foundation
import CryptoKit

/// Keys derived from a group code.
///
/// The code itself never leaves the phone. Peers advertise `discoveryTag`, a
/// one-way tag of the code, so phones in the same group can find each other
/// without broadcasting the code over Bluetooth. Every packet is then sealed
/// with `key` (ChaCha20-Poly1305), so a phone that copies the tag but doesn't
/// know the code can connect but can't read, forge or relay anything, and is
/// dropped when it fails the hello handshake.
nonisolated struct GroupKeys: Sendable {
    let key: SymmetricKey
    let discoveryTag: String

    /// Rounds of SHA-256 used to stretch the code before key derivation. Slows
    /// down guessing a short code from a sniffed tag. A long code is still the
    /// real protection.
    static let stretchRounds = 50_000

    init(code: String) {
        var digest = Data(SHA256.hash(data: Data("NoBars.group.v1|\(code)".utf8)))
        for _ in 0..<Self.stretchRounds {
            digest = Data(SHA256.hash(data: digest))
        }
        let master = SymmetricKey(data: digest)
        let salt = Data("NoBars.v1".utf8)
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt,
                                     info: Data("payload".utf8), outputByteCount: 32)
        let tagKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt,
                                            info: Data("discovery".utf8), outputByteCount: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("tag".utf8), using: tagKey)
        discoveryTag = Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Wire format and signatures for mesh packets.
nonisolated enum MeshCrypto {

    /// Prefix on every sealed packet, so the format can change later.
    static let magic = Data("NB1".utf8)

    /// Location and hello packets older than this are treated as replays.
    static let maxPositionAge: TimeInterval = 10 * 60

    // MARK: Sealing

    static func seal(_ packet: MeshRelayPacket, with key: SymmetricKey) -> Data? {
        guard let plain = packet.encoded(),
              let box = try? ChaChaPoly.seal(plain, using: key) else { return nil }
        return magic + box.combined
    }

    static func open(_ data: Data, with key: SymmetricKey) -> MeshRelayPacket? {
        guard data.count > magic.count, data.prefix(magic.count) == magic,
              let box = try? ChaChaPoly.SealedBox(combined: data.dropFirst(magic.count)),
              let plain = try? ChaChaPoly.open(box, using: key) else { return nil }
        return MeshRelayPacket.decode(from: plain)
    }

    // MARK: Signing

    /// Bytes covered by the signature: everything except `ttl` (relays change
    /// it) and the signature itself. Built by hand so every phone produces the
    /// exact same bytes regardless of JSON key order.
    static func signingBytes(_ p: MeshRelayPacket) -> Data {
        func bits(_ d: Double?) -> String { d.map { String($0.bitPattern) } ?? "-" }
        let fields = [
            "NB1",
            p.id.uuidString,
            p.kind.rawValue,
            p.senderName,
            String(p.timestamp.timeIntervalSinceReferenceDate.bitPattern),
            p.text ?? "-",
            bits(p.latitude),
            bits(p.longitude),
            p.isEmergency.map { $0 ? "1" : "0" } ?? "-",
            p.senderKey?.base64EncodedString() ?? "-",
        ]
        var data = Data()
        for f in fields {
            let bytes = Data(f.utf8)
            withUnsafeBytes(of: UInt32(bytes.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }

    static func sign(_ packet: inout MeshRelayPacket, with key: Curve25519.Signing.PrivateKey) {
        packet.senderKey = key.publicKey.rawRepresentation
        packet.signature = try? key.signature(for: signingBytes(packet))
    }

    /// True when the packet carries a valid signature from the key it claims.
    static func verify(_ packet: MeshRelayPacket) -> Bool {
        guard let raw = packet.senderKey, let sig = packet.signature,
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return pub.isValidSignature(sig, for: signingBytes(packet))
    }

    /// Short human-checkable fingerprint of a public key, e.g. "3F2A 91C0".
    static func fingerprint(_ publicKey: Data) -> String {
        let hex = Data(SHA256.hash(data: publicKey)).prefix(4).map { String(format: "%02X", $0) }.joined()
        return "\(hex.prefix(4)) \(hex.suffix(4))"
    }
}

/// Trust-on-first-use pinning of buddy names to signing keys.
///
/// The first key seen for a name is remembered. A later packet using that name
/// with a different key is an impersonation attempt (or a reinstalled app) and
/// is rejected until the user resets trusted buddies.
nonisolated struct KeyPins: Codable, Sendable, Equatable {
    enum Result: Equatable { case new, match, mismatch }

    private(set) var keys: [String: Data] = [:]

    mutating func check(name: String, key: Data) -> Result {
        guard let pinned = keys[name] else {
            keys[name] = key
            return .new
        }
        return pinned == key ? .match : .mismatch
    }

    mutating func removeAll() { keys.removeAll() }
}
