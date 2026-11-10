import WidgetKit
import SwiftUI

/// Reads what the app writes to the shared App Group.
private enum MeshSnapshot {
    static let suite = UserDefaults(suiteName: "group.com.swastik.nobars")

    static var peers: [String] {
        guard let data = suite?.data(forKey: "connectedPeers"),
              let v = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return v
    }
    static var emergencies: [String] { suite?.stringArray(forKey: "emergencyBuddies") ?? [] }
    static var updatedAt: Date? { suite?.object(forKey: "updatedAt") as? Date }
}

struct MeshEntry: TimelineEntry {
    let date: Date
    let peers: [String]
    let emergencies: [String]
    let updatedAt: Date?
}

struct MeshProvider: TimelineProvider {
    func placeholder(in context: Context) -> MeshEntry {
        MeshEntry(date: .now, peers: ["Arjun", "Kabir"], emergencies: [], updatedAt: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (MeshEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MeshEntry>) -> Void) {
        // The app reloads timelines whenever peers or SOS state change.
        completion(Timeline(entries: [current()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func current() -> MeshEntry {
        MeshEntry(date: .now, peers: MeshSnapshot.peers, emergencies: MeshSnapshot.emergencies, updatedAt: MeshSnapshot.updatedAt)
    }
}

struct MeshWidgetView: View {
    let entry: MeshEntry
    @Environment(\.widgetFamily) private var family
    private let accent = Color(red: 0.52, green: 0.35, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.emergencies.isEmpty ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle.fill")
                    .foregroundStyle(entry.emergencies.isEmpty ? accent : .red)
                Text("NoBars").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }

            if let sos = entry.emergencies.first {
                Text("SOS").font(.title2.bold()).foregroundStyle(.red)
                Text(sos).font(.subheadline.weight(.semibold)).lineLimit(1)
            } else {
                Text("\(entry.peers.count)").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(entry.peers.count == 1 ? "buddy nearby" : "buddies nearby")
                    .font(.caption).foregroundStyle(.secondary)
                if family != .systemSmall, !entry.peers.isEmpty {
                    Text(entry.peers.prefix(4).joined(separator: ", "))
                        .font(.caption.weight(.medium)).lineLimit(1)
                }
            }

            Spacer(minLength: 0)
            if let updated = entry.updatedAt {
                Text(updated, style: .relative).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "nobars://open"))
    }
}

struct NoBarsWidget: Widget {
    let kind = "NoBarsStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MeshProvider()) { entry in
            MeshWidgetView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Mesh Status")
        .description("Who's on your mesh, and any SOS.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    NoBarsWidget()
} timeline: {
    MeshEntry(date: .now, peers: ["Arjun", "Kabir", "Aman"], emergencies: [], updatedAt: .now)
    MeshEntry(date: .now, peers: ["Arjun"], emergencies: ["Arjun"], updatedAt: .now)
}
