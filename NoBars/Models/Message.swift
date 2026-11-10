import Foundation
import CoreLocation

struct MeshMessage: Identifiable, Hashable, Codable {
    var id = UUID()
    let sender: String
    let text: String
    let date: Date
    var pending = false
    var isSystem = false
}

struct BuddyLocation: Identifiable {
    var id: String { name }
    let name: String
    let coordinate: CLLocationCoordinate2D
    let date: Date
}
