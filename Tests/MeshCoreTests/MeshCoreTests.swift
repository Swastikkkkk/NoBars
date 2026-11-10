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
