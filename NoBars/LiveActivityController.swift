import Foundation
import ActivityKit
import os

@MainActor
final class LiveActivityController {

    private var activity: Activity<NoBarsActivityAttributes>?
    private let log = Logger(subsystem: "com.swastik.nobars", category: "liveactivity")

    func update(
        connectedPeers: [String],
        group: String,
        sharingLocation: Bool,
        nearestPeer: (name: String, distance: Double)? = nil
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.warning("Live Activities not enabled on this device")
            return
        }

        let count = connectedPeers.count
        let headline: String

        if let nearest = nearestPeer {
            let distStr = nearest.distance < 1000
                ? "~\(Int(nearest.distance))m away"
                : String(format: "~%.1fkm away", nearest.distance / 1000)
            switch count {
            case 0:
                headline = "Waiting for buddies…"
            case 1:
                headline = "\(nearest.name) is \(distStr)"
            default:
                headline = "\(nearest.name) \(distStr) · \(count - 1) more on mesh"
            }
        } else {
            switch count {
            case 0:
                headline = "Waiting for buddies…"
            case 1:
                headline = "\(connectedPeers[0]) is on the mesh"
            default:
                headline = "\(connectedPeers[0]) + \(count - 1) more on the mesh"
            }
        }

        let state = NoBarsActivityAttributes.ContentState(
            connectedCount: count,
            headline: headline,
            isSharingLocation: sharingLocation
        )

        if let activity {
            Task {
                await activity.update(.init(state: state, staleDate: nil))
            }
        } else {
            let attrs = NoBarsActivityAttributes(group: group.isEmpty ? "NoBars" : group)
            do {
                activity = try Activity.request(
                    attributes: attrs,
                    content: .init(state: state, staleDate: nil),
                    pushType: nil
                )
                log.info("Live Activity started: \(self.activity?.id ?? "?")")
            } catch {
                log.error("Failed to start Live Activity: \(error.localizedDescription)")
            }
        }
    }

    func end() {
        Task {
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            log.info("Live Activity ended")
        }
    }
}
