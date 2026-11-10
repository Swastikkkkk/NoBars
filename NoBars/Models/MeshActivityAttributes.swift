import Foundation
import ActivityKit

struct NoBarsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var connectedCount: Int
        var headline: String
        var isSharingLocation: Bool
    }
    var group: String
}
