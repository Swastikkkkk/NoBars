import SwiftUI
import MapKit

struct BuddyMapView: View {
    let mesh: MeshConnectivityManager

    private var buddies: [BuddyLocation] {
        mesh.buddyLocations.values.sorted { $0.name < $1.name }
    }

    var body: some View {
        Map {
            ForEach(buddies) { buddy in
                Marker(buddy.name, coordinate: buddy.coordinate)
                    .tint(mesh.emergencyBuddies.contains(buddy.name) ? NoBarsTheme.alert : NoBarsTheme.accent)
            }
        }
        .overlay {
            if buddies.isEmpty {
                ContentUnavailableView(
                    "No location pings yet",
                    systemImage: "mappin.slash",
                    description: Text("Tap Share in the toolbar to broadcast your location to the mesh.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !buddies.isEmpty { buddyList }
        }
    }

    private var buddyList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(buddies) { buddy in
                HStack {
                    Circle()
                        .fill(mesh.emergencyBuddies.contains(buddy.name) ? NoBarsTheme.alert : NoBarsTheme.accent)
                        .frame(width: 9, height: 9)
                    Text(buddy.name).font(.callout.weight(.medium)).foregroundStyle(.white)
                    if buddy.name == mesh.myName {
                        Text("(you)").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "%.4f, %.4f",
                                    buddy.coordinate.latitude, buddy.coordinate.longitude))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white)
                        Text(buddy.date, style: .relative).font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}
