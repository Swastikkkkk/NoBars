import XCTest
import CryptoKit
@testable import MeshCore

final class GroupKeyTests: XCTestCase {
    func testTagIsStableAndPerGroup() {
        XCTAssertEqual(GroupKeys(code: "fest24").discoveryTag, GroupKeys(code: "fest24").discoveryTag)
        XCTAssertNotEqual(GroupKeys(code: "fest24").discoveryTag, GroupKeys(code: "fest25").discoveryTag)
        XCTAssertNotEqual(GroupKeys(code: "").discoveryTag, GroupKeys(code: "fest24").discoveryTag)
    }

    func testTagDoesNotLeakCode() {
        let tag = GroupKeys(code: "fest24").discoveryTag
        XCTAssertEqual(tag.count, 16)
        XCTAssertFalse(tag.contains("fest"))
    }
}

final class SealTests: XCTestCase {
    let keys = GroupKeys(code: "ci")

    func testRoundTrip() throws {
        let packet = MeshRelayPacket(kind: .message, senderName: "Alice", text: "hi")
        let sealed = try XCTUnwrap(MeshCrypto.seal(packet, with: keys.key))
        XCTAssertNil(String(data: sealed, encoding: .utf8)?.range(of: "Alice"))
        let opened = try XCTUnwrap(MeshCrypto.open(sealed, with: keys.key))
        XCTAssertEqual(opened.id, packet.id)
        XCTAssertEqual(opened.text, "hi")
    }

    func testWrongGroupCannotOpen() throws {
        let packet = MeshRelayPacket(kind: .message, senderName: "Alice", text: "hi")
        let sealed = try XCTUnwrap(MeshCrypto.seal(packet, with: keys.key))
        XCTAssertNil(MeshCrypto.open(sealed, with: GroupKeys(code: "other").key))
    }

    func testTamperedCiphertextRejected() throws {
        let packet = MeshRelayPacket(kind: .message, senderName: "Alice", text: "hi")
        var sealed = try XCTUnwrap(MeshCrypto.seal(packet, with: keys.key))
        sealed[sealed.count - 20] ^= 0x01
        XCTAssertNil(MeshCrypto.open(sealed, with: keys.key))
    }

    func testPlainJSONRejected() throws {
        let plain = try XCTUnwrap(MeshRelayPacket(kind: .message, senderName: "Eve", text: "x").encoded())
        XCTAssertNil(MeshCrypto.open(plain, with: keys.key))
    }
}

final class SignatureTests: XCTestCase {
    let alice = Curve25519.Signing.PrivateKey()
    let keys = GroupKeys(code: "ci")

    func signed(_ kind: MeshRelayPacket.Kind = .message) -> MeshRelayPacket {
        var p = MeshRelayPacket(kind: kind, senderName: "Alice", text: "meet at gate 3",
                                latitude: 28.4744, longitude: 77.504, isEmergency: true)
        MeshCrypto.sign(&p, with: alice)
        return p
    }

    func testValidSignature() {
        XCTAssertTrue(MeshCrypto.verify(signed()))
    }

    func testSurvivesWireRoundTripAndRelay() throws {
        let sealed = try XCTUnwrap(MeshCrypto.seal(signed(), with: keys.key))
        var relayed = try XCTUnwrap(MeshCrypto.open(sealed, with: keys.key))
        relayed.ttl -= 3
        let again = try XCTUnwrap(MeshCrypto.open(XCTUnwrap(MeshCrypto.seal(relayed, with: keys.key)), with: keys.key))
        XCTAssertTrue(MeshCrypto.verify(again))
    }

    func testEditedTextRejected() {
        var p = signed()
        p.text = "meet at gate 4"
        XCTAssertFalse(MeshCrypto.verify(p))
    }

    func testEditedSOSFlagRejected() {
        var p = signed(.location)
        p.isEmergency = false
        XCTAssertFalse(MeshCrypto.verify(p))
    }

    func testForgedNameRejected() {
        let p = signed()
        let forged = MeshRelayPacket(kind: p.kind, senderName: "Bob", ttl: p.ttl, text: p.text,
                                     latitude: p.latitude, longitude: p.longitude, isEmergency: p.isEmergency,
                                     id: p.id, timestamp: p.timestamp)
        var withSig = forged
        withSig.senderKey = p.senderKey
        withSig.signature = p.signature
        XCTAssertFalse(MeshCrypto.verify(withSig))
    }

    func testSwappedKeyRejected() {
        var p = signed()
        p.senderKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertFalse(MeshCrypto.verify(p))
    }

    func testUnsignedRejected() {
        XCTAssertFalse(MeshCrypto.verify(MeshRelayPacket(kind: .message, senderName: "Alice", text: "hi")))
    }
}

final class KeyPinTests: XCTestCase {
    func testTrustOnFirstUse() {
        var pins = KeyPins()
        let a = Data([1, 2, 3]), b = Data([4, 5, 6])
        XCTAssertEqual(pins.check(name: "Alice", key: a), .new)
        XCTAssertEqual(pins.check(name: "Alice", key: a), .match)
        XCTAssertEqual(pins.check(name: "Alice", key: b), .mismatch)
        XCTAssertEqual(pins.check(name: "Bob", key: b), .new)
        pins.removeAll()
        XCTAssertEqual(pins.check(name: "Alice", key: b), .new)
    }

    func testCodable() throws {
        var pins = KeyPins()
        _ = pins.check(name: "Alice", key: Data([9]))
        let back = try JSONDecoder().decode(KeyPins.self, from: JSONEncoder().encode(pins))
        XCTAssertEqual(back, pins)
    }
}

final class RouterTests: XCTestCase {
    func testDropsDuplicatesAndDecrementsTTL() {
        var router = MeshRouter()
        let p = MeshRelayPacket(kind: .message, senderName: "A", ttl: 3, text: "x")
        guard case .deliver(let fwd) = router.receive(p) else { return XCTFail("not delivered") }
        XCTAssertEqual(fwd?.ttl, 2)
        XCTAssertEqual(router.receive(p), .drop)
    }

    func testLastHopNotForwarded() {
        var router = MeshRouter()
        let p = MeshRelayPacket(kind: .message, senderName: "A", ttl: 1, text: "x")
        XCTAssertEqual(router.receive(p), .deliver(forward: nil))
    }

    func testOwnPacketsDropped() {
        var router = MeshRouter()
        let p = MeshRelayPacket(kind: .message, senderName: "A", text: "x")
        router.markOwn(p)
        XCTAssertEqual(router.receive(p), .drop)
    }

    /// Flood over a ring of 6 phones: everyone gets it exactly once.
    func testRingFloodDeliversOnce() {
        let n = 6
        var routers = Array(repeating: MeshRouter(), count: n)
        var delivered = Array(repeating: 0, count: n)
        let p = MeshRelayPacket(kind: .message, senderName: "P0", text: "x")
        routers[0].markOwn(p)
        var queue: [(to: Int, from: Int, packet: MeshRelayPacket)] = [(1, 0, p), (n - 1, 0, p)]
        while !queue.isEmpty {
            let (to, from, packet) = queue.removeFirst()
            guard case .deliver(let fwd) = routers[to].receive(packet) else { continue }
            delivered[to] += 1
            guard let fwd else { continue }
            for nb in [(to + 1) % n, (to + n - 1) % n] where nb != from { queue.append((nb, to, fwd)) }
        }
        XCTAssertEqual(Array(delivered.dropFirst()), Array(repeating: 1, count: n - 1))
    }
}

/// Checks the Swift implementation against protocol/vectors.json, which the
/// Android app is tested against too. If these pass on both sides, iPhones
/// and Android phones agree on keys, encryption and signatures.
final class CrossPlatformVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct Group: Decodable { let code: String; let tag: String; let key: String }
        struct Sealed: Decodable { let signingBytes: String; let sealed: String }
        let groups: [Group]
        let sealedWithGroup: String
        let packets: [Sealed]
    }

    func load() throws -> (Vectors, [[String: Any]], [String: Any]) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/vectors.json")
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let packets = try XCTUnwrap(raw["packets"] as? [[String: Any]]).compactMap { $0["packet"] as? [String: Any] }
        let bad = try XCTUnwrap(raw["badSignature"] as? [String: Any])
        return (try JSONDecoder().decode(Vectors.self, from: data), packets, bad)
    }

    func hex(_ data: some DataProtocol) -> String { data.map { String(format: "%02x", $0) }.joined() }
    func unhex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }
    func packet(_ dict: [String: Any]) throws -> MeshRelayPacket {
        try JSONDecoder().decode(MeshRelayPacket.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    func testGroupKeysMatch() throws {
        let (v, _, _) = try load()
        for g in v.groups {
            let keys = GroupKeys(code: g.code)
            XCTAssertEqual(keys.discoveryTag, g.tag, "tag for \(g.code)")
            XCTAssertEqual(keys.key.withUnsafeBytes { hex($0) }, g.key, "key for \(g.code)")
        }
    }

    func testOpensAndVerifiesReferencePackets() throws {
        let (v, dicts, _) = try load()
        let key = GroupKeys(code: v.sealedWithGroup).key
        for (vec, dict) in zip(v.packets, dicts) {
            let opened = try XCTUnwrap(MeshCrypto.open(unhex(vec.sealed), with: key))
            XCTAssertTrue(MeshCrypto.verify(opened), "signature for \(opened.kind)")
            XCTAssertEqual(hex(MeshCrypto.signingBytes(opened)), vec.signingBytes)
            XCTAssertEqual(opened.id.uuidString, dict["id"] as? String)
            XCTAssertEqual(opened.senderName, dict["senderName"] as? String)
            XCTAssertEqual(hex(MeshCrypto.signingBytes(try packet(dict))), vec.signingBytes)
        }
    }

    /// Packets sealed and signed by the Android app's Kotlin code.
    func testOpensAndVerifiesAndroidPackets() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/vectors-android.json")
        struct AndroidVectors: Decodable {
            struct P: Decodable { let id: String; let kind: String; let signingBytes: String; let sealed: String }
            let group: String; let packets: [P]
        }
        let v = try JSONDecoder().decode(AndroidVectors.self, from: Data(contentsOf: url))
        let key = GroupKeys(code: v.group).key
        XCTAssertEqual(v.packets.count, 5)
        for p in v.packets {
            let opened = try XCTUnwrap(MeshCrypto.open(unhex(p.sealed), with: key), "open \(p.kind)")
            XCTAssertEqual(opened.id.uuidString, p.id)
            XCTAssertEqual(opened.kind.rawValue, p.kind)
            XCTAssertTrue(MeshCrypto.verify(opened), "verify \(p.kind)")
            XCTAssertEqual(hex(MeshCrypto.signingBytes(opened)), p.signingBytes)
        }
    }

    func testRejectsTamperedReferencePacket() throws {
        let (_, _, bad) = try load()
        XCTAssertFalse(MeshCrypto.verify(try packet(bad)))
    }
}

final class BLEFramingTests: XCTestCase {
    func testRoundTripOutOfOrder() {
        let msg = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let frames = BLEFraming.split(msg, seq: 42, maxFrame: 182)
        XCTAssertGreaterThan(frames.count, 1)
        XCTAssertTrue(frames.allSatisfy { $0.count <= 182 })
        var r = BLEFraming.Reassembler()
        let results = frames.reversed().map { r.accept($0) }
        XCTAssertEqual(results.last!, msg)
        XCTAssertTrue(results.dropLast().allSatisfy { $0 == nil })
    }

    /// Byte layout must match the Android framer exactly.
    func testHeaderLayout() {
        let frame = BLEFraming.split(Data([0xAB]), seq: 0x01020304, maxFrame: 20)[0]
        XCTAssertEqual([UInt8](frame), [1, 1, 2, 3, 4, 0, 1, 0xAB])
    }

    func testIgnoresGarbage() {
        var r = BLEFraming.Reassembler()
        XCTAssertNil(r.accept(Data([9, 9, 9])))
        XCTAssertNil(r.accept(Data([2, 0, 0, 0, 1, 0, 1, 5])))
    }
}
