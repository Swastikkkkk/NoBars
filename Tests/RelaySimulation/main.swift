// Simulates a mesh of phones using the exact MeshRouter + MeshRelayPacket code
// the app ships, then checks the guarantees the README makes.
//
// Run on a Mac:
//   xcrun swiftc NoBars/Models/MeshRelayPacket.swift Tests/RelaySimulation/main.swift -o relay-sim && ./relay-sim

import Foundation

final class Phone {
    let name: String
    var router = MeshRouter()
    var neighbours: [Phone] = []
    var inbox: [String] = []
    init(_ name: String) { self.name = name }
}

struct Mesh {
    var phones: [String: Phone] = [:]
    var transmissions = 0

    init(_ names: [String], links: [(String, String)]) {
        for n in names { phones[n] = Phone(n) }
        for (a, b) in links {
            phones[a]!.neighbours.append(phones[b]!)
            phones[b]!.neighbours.append(phones[a]!)
        }
    }

    /// Breadth-first delivery, one hop per round, like packets on the air.
    mutating func send(_ text: String, from origin: String, ttl: Int = MeshRelayPacket.defaultTTL) {
        let sender = phones[origin]!
        // Round-trip through JSON, exactly what goes over MCSession.
        let packet = MeshRelayPacket.decode(from: MeshRelayPacket(kind: .message, senderName: origin, ttl: ttl, text: text).encoded()!)!
        sender.router.markOwn(packet)
        typealias Hop = (packet: MeshRelayPacket, from: Phone, to: Phone)
        var queue: [Hop] = sender.neighbours.map { (packet: packet, from: sender, to: $0) }
        while !queue.isEmpty {
            var next: [Hop] = []
            for (p, from, to) in queue {
                transmissions += 1
                let wire = MeshRelayPacket.decode(from: p.encoded()!)!
                switch to.router.receive(wire) {
                case .drop: break
                case .deliver(let forward):
                    to.inbox.append(wire.text ?? "")
                    if let forward {
                        for n in to.neighbours where n !== from { next.append((packet: forward, from: to, to: n)) }
                    }
                }
            }
            queue = next
        }
    }
}

var failures = 0
func check(_ ok: Bool, _ label: String) {
    print(ok ? "PASS  \(label)" : "FAIL  \(label)")
    if !ok { failures += 1 }
}

// 1. A line of phones: A-B-C-D-E. A and E are never in range.
do {
    var m = Mesh(["A", "B", "C", "D", "E"], links: [("A","B"), ("B","C"), ("C","D"), ("D","E")])
    m.send("hello", from: "A")
    check(m.phones["E"]!.inbox == ["hello"], "4-hop chain: E gets A's message")
    check(["B","C","D"].allSatisfy { m.phones[$0]!.inbox == ["hello"] }, "every relay delivers exactly once")
    check(m.phones["A"]!.inbox.isEmpty, "sender does not receive its own echo")
}

// 2. A loop: A-B-C-D-A plus chord B-D. Duplicates must be dropped.
do {
    var m = Mesh(["A", "B", "C", "D"], links: [("A","B"), ("B","C"), ("C","D"), ("D","A"), ("B","D")])
    m.send("sos", from: "A")
    check(["B","C","D"].allSatisfy { m.phones[$0]!.inbox == ["sos"] }, "loops and chords: delivered exactly once each")
    check(m.transmissions < 20, "flood terminates (\(m.transmissions) transmissions)")
}

// 3. TTL caps reach: chain of 15 phones, default TTL 10.
do {
    let names = (0..<15).map { "P\($0)" }
    var m = Mesh(names, links: (0..<14).map { (names[$0], names[$0 + 1]) })
    m.send("far", from: "P0")
    check(m.phones["P10"]!.inbox == ["far"], "TTL 10 reaches the 10th hop")
    check(m.phones["P11"]!.inbox.isEmpty, "TTL stops at the 11th hop")
}

// 4. Packet survives the wire format intact, including location + emergency.
do {
    let loc = MeshRelayPacket(kind: .location, senderName: "Arjun", latitude: 28.47, longitude: 77.50, isEmergency: true)
    let back = MeshRelayPacket.decode(from: loc.encoded()!)
    check(back?.id == loc.id && back?.latitude == 28.47 && back?.isEmergency == true, "location + SOS flag round-trip")
    check(MeshRelayPacket.decode(from: Data("garbage".utf8)) == nil, "garbage bytes are rejected, not crashed on")
}

// 5. Seen-cache stays bounded during long sessions.
do {
    var cache = SeenPacketCache(limit: 500)
    for _ in 0..<5_000 { _ = cache.insertIfNew(UUID()) }
    let id = UUID()
    check(cache.insertIfNew(id) && !cache.insertIfNew(id), "seen cache dedups after 5k packets")
}

print(failures == 0 ? "\nAll relay checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
