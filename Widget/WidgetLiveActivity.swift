import ActivityKit
import WidgetKit
import SwiftUI

// NoBarsActivityAttributes must match the definition in MeshActivityAttributes.swift exactly.
struct NoBarsActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var connectedCount: Int
        var headline: String
        var isSharingLocation: Bool
    }
    var group: String
}

struct WidgetLiveActivity: Widget {
    private let accent = Color(red: 0.52, green: 0.35, blue: 1.0)

    private func statusIcon(_ state: NoBarsActivityAttributes.ContentState) -> String {
        state.isSharingLocation ? "location.fill" : "dot.radiowaves.left.and.right"
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NoBarsActivityAttributes.self) { context in

            // Lock screen / StandBy banner
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.15))
                        .frame(width: 48, height: 48)
                    Circle()
                        .stroke(accent.opacity(0.5), lineWidth: 1)
                        .frame(width: 48, height: 48)
                    Image(systemName: statusIcon(context.state))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(context.state.isSharingLocation ? "Sharing location" : "Live on mesh")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(accent)
                        if context.attributes.group != "NoBars" {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("#\(context.attributes.group)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(context.state.headline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(context.state.connectedCount)")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(accent)
                    Text(context.state.connectedCount == 1 ? "buddy" : "buddies")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(accent)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("\(context.state.connectedCount)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(accent)
                    } icon: {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(accent)
                    }
                    .font(.caption.bold())
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: statusIcon(context.state))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(context.state.isSharingLocation ? .red : accent)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if context.attributes.group != "NoBars" {
                            Text("#\(context.attributes.group)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.isSharingLocation ? "Location shared with your mesh" : "Mesh is active — no internet needed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

            } compactLeading: {
                Image(systemName: statusIcon(context.state))
                    .foregroundStyle(accent)
                    .font(.caption.weight(.semibold))
            } compactTrailing: {
                HStack(spacing: 3) {
                    Text("\(context.state.connectedCount)")
                        .font(.caption.bold())
                        .foregroundStyle(accent)
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(accent.opacity(0.7))
                }
            } minimal: {
                Image(systemName: statusIcon(context.state))
                    .foregroundStyle(accent)
                    .font(.caption2)
            }
            .keylineTint(accent)
        }
    }
}
