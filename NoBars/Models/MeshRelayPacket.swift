import Foundation

/// A single unit of data that travels across the mesh.
///
/// Packets are relayed peer-to-peer: each device that receives a packet
/// re-broadcasts it to its own neighbours (minus the one it came from) after
/// decrementing `ttl`. This is what lets a message reach a device that is *not*
/// directly connected to the original sender (multi-hop). `id` stays constant
/// across every hop and is used for de-duplication so a packet looping around
/// the mesh is only processed once.
nonisolated struct MeshRelayPacket: Codable, Identifiable, Sendable {

    enum Kind: String, Codable, Sendable {
        case message
        case location
        /// Sent once to each direct neighbour right after connecting. Proves the
        /// neighbour knows the group key and pins its signing key. Never relayed.
        case hello
    }

    let id: UUID
    var ttl: Int
    let kind: Kind
    let senderName: String
    let timestamp: Date

    var text: String?
    var latitude: Double?
    var longitude: Double?
    var isEmergency: Bool?

    /// Sender's Curve25519 signing public key and its signature over the packet
    /// (everything except `ttl`). See `MeshCrypto`.
    var senderKey: Data?
    var signature: Data?

    static let defaultTTL = 10

    init(
        kind: Kind,
        senderName: String,
        ttl: Int = MeshRelayPacket.defaultTTL,
        text: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isEmergency: Bool? = nil,
        id: UUID = UUID(),
        timestamp: Date = Date()
    ) {
        self.id = id
        self.ttl = ttl
        self.kind = kind
        self.senderName = senderName
        self.timestamp = timestamp
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.isEmergency = isEmergency
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(from data: Data) -> MeshRelayPacket? {
        try? JSONDecoder().decode(MeshRelayPacket.self, from: data)
    }
}

/// Tracks recently seen packet ids so a packet circulating the mesh is only
/// delivered/relayed once. Bounded so memory stays flat during long sessions.
nonisolated struct SeenPacketCache {
    private var ids: Set<UUID> = []
    private var order: [UUID] = []
    private let limit: Int

    init(limit: Int = 500) {
        self.limit = limit
    }

    mutating func insertIfNew(_ id: UUID) -> Bool {
        guard !ids.contains(id) else { return false }
        ids.insert(id)
        order.append(id)
        if order.count > limit {
            let evicted = order.removeFirst()
            ids.remove(evicted)
        }
        return true
    }
}

/// The relay decision every phone makes for every packet it sees.
///
/// Kept free of MultipeerConnectivity so the flooding behaviour can be tested
/// on its own (see `Tests/RelaySimulation/main.swift`).
nonisolated struct MeshRouter {
    enum Decision: Equatable {
        /// Already seen. Ignore it and do not forward.
        case drop
        /// New packet. Deliver it locally, and forward `forward` to every
        /// neighbour except the one it came from (nil once TTL runs out).
        case deliver(forward: MeshRelayPacket?)

        static func == (lhs: Decision, rhs: Decision) -> Bool {
            switch (lhs, rhs) {
            case (.drop, .drop): return true
            case let (.deliver(a), .deliver(b)): return a?.id == b?.id && a?.ttl == b?.ttl
            default: return false
            }
        }
    }

    private var seen = SeenPacketCache()

    /// Call for packets this phone originates so echoes coming back are dropped.
    mutating func markOwn(_ packet: MeshRelayPacket) {
        _ = seen.insertIfNew(packet.id)
    }

    mutating func receive(_ packet: MeshRelayPacket) -> Decision {
        guard seen.insertIfNew(packet.id) else { return .drop }
        var forwarded = packet
        forwarded.ttl -= 1
        return .deliver(forward: forwarded.ttl > 0 ? forwarded : nil)
    }
}
