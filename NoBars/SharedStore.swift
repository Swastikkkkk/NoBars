import Foundation

enum SharedStore {
    static let suiteName = "group.com.swastik.nobars"
    private static let buddiesKey = "buddyLocations"
    private static let peersKey = "connectedPeers"
    private static let emergencyKey = "emergencyBuddies"
    private static let updatedKey = "updatedAt"

    struct BuddySnapshot: Codable, Identifiable {
        var id: String { name }
        let name: String
        let lat: Double
        let lon: Double
        let date: Date
    }

    static func saveBuddies(_ buddies: [BuddySnapshot]) {
        guard let d = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(buddies) else { return }
        d.set(data, forKey: buddiesKey)
    }

    static func loadBuddies() -> [BuddySnapshot] {
        guard let d = UserDefaults(suiteName: suiteName),
              let data = d.data(forKey: buddiesKey),
              let v = try? JSONDecoder().decode([BuddySnapshot].self, from: data) else { return [] }
        return v
    }

    static func saveConnectedPeers(_ peers: [String]) {
        guard let d = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(peers) else { return }
        d.set(data, forKey: peersKey)
        d.set(Date(), forKey: updatedKey)
    }

    static func saveEmergencies(_ names: [String]) {
        UserDefaults(suiteName: suiteName)?.set(names, forKey: emergencyKey)
    }

    static func loadConnectedPeers() -> [String] {
        guard let d = UserDefaults(suiteName: suiteName),
              let data = d.data(forKey: peersKey),
              let v = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return v
    }
}
