import SwiftUI
import CoreLocation

struct CompassView: View {
    let mesh: MeshConnectivityManager
    @State private var selected: String?
    @State private var pulse = false

    private var nearbyPeers: [String] {
        mesh.connectedPeers.filter { $0 != mesh.myName }
    }
    private var targetName: String? {
        if let s = selected, nearbyPeers.contains(s) { return s }
        return nearbyPeers.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if nearbyPeers.isEmpty {
                    noPeersView
                } else {
                    if nearbyPeers.count > 1 { buddyPicker }
                    if let name = targetName {
                        if let loc = mesh.buddyLocations[name], let me = mesh.myCoordinate {
                            gpsCompass(to: loc, from: me, name: name)
                        } else {
                            proximityMode(name: name)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .noBarsBackground()
        .navigationTitle("Compass")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mesh.startCompass()
            if selected == nil { selected = nearbyPeers.first }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { pulse = true }
        }
        .onDisappear { mesh.stopCompass() }
    }

    // MARK: - No peers

    private var noPeersView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 64)).foregroundStyle(.white.opacity(0.2))
                .padding(.top, 60)
            Text("No one on the mesh")
                .font(.title2.bold()).foregroundStyle(.white)
            Text("Go Live from the home screen. Once friends connect via Bluetooth or WiFi they'll appear here.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    // MARK: - Buddy picker

    private var buddyPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(nearbyPeers, id: \.self) { name in
                    let on = targetName == name
                    Button { selected = name } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(mesh.buddyLocations[name] != nil ? Color.green : .white.opacity(0.3))
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(on ? .white : .white.opacity(0.65))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(on ? AnyShapeStyle(NoBarsTheme.brandGradient) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - GPS Compass

    private func gpsCompass(to target: BuddyLocation, from me: CLLocationCoordinate2D, name: String) -> some View {
        let bearing   = MeshConnectivityManager.bearing(from: me, to: target.coordinate)
        let needleAngle = bearing - mesh.deviceHeading   // relative bearing on screen
        let dist      = CLLocation(latitude: me.latitude, longitude: me.longitude)
                            .distance(from: CLLocation(latitude: target.coordinate.latitude,
                                                       longitude: target.coordinate.longitude))
        let stale     = Date().timeIntervalSince(target.date) > 120
        let tooClose  = dist < 20

        return VStack(spacing: 22) {

            // ── Info header ──────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 12) {
                InitialsAvatar(name: name, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.title2.bold()).foregroundStyle(.white)
                    Text(cardinalLabel(bearing))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(NoBarsTheme.accent)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(distanceText(dist)).font(.title3.bold()).foregroundStyle(.white)
                    Text(String(format: "%.0f°", bearing))
                        .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 4)

            // ── Compass circle ───────────────────────────────────────────────
            ZStack {
                // Rotating compass rose (shows geographic North)
                CompassRose(deviceHeading: mesh.deviceHeading)
                    .frame(width: 290, height: 290)
                    .rotationEffect(.degrees(-mesh.deviceHeading))
                    .animation(.interpolatingSpring(stiffness: 120, damping: 20), value: mesh.deviceHeading)

                if tooClose {
                    togetherState(dist: dist)
                } else if !mesh.headingActive {
                    calibratingState
                } else {
                    // Compass needle pointing toward target
                    CompassNeedle(stale: stale)
                        .frame(width: 290, height: 290)
                        .rotationEffect(.degrees(needleAngle))
                        .animation(.interpolatingSpring(stiffness: 120, damping: 20), value: needleAngle)

                    // My avatar sits at the center
                    Circle()
                        .fill(NoBarsTheme.screenGradient)
                        .frame(width: 46, height: 46)
                    InitialsAvatar(name: mesh.myName, size: 40)
                }
            }

            // ── Status row ───────────────────────────────────────────────────
            VStack(spacing: 8) {
                if stale {
                    Label("Last seen \(target.date, style: .relative) — may be off",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(NoBarsTheme.alert.opacity(0.9))
                } else if !tooClose {
                    Label("Updated \(target.date, style: .relative)",
                          systemImage: "clock")
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                }
                if mesh.isLocationDenied { locationDeniedButton }
            }
        }
    }

    private func togetherState(dist: Double) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 52)).foregroundStyle(NoBarsTheme.accent)
            Text("You're together!").font(.title2.bold()).foregroundStyle(.white)
            Text("~\(Int(dist.rounded())) m").font(.subheadline).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var calibratingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.5))
                .symbolEffect(.rotate, isActive: true)
            Text("Calibrating compass")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
            Text("Slowly wave your phone in a figure-8 to calibrate.")
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center).padding(.horizontal)
        }
    }

    // MARK: - Proximity mode (connected via BT/WiFi, no GPS)

    private func proximityMode(name: String) -> some View {
        VStack(spacing: 22) {
            HStack(spacing: 12) {
                InitialsAvatar(name: name, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title2.bold()).foregroundStyle(.white)
                    Label("Connected via Bluetooth / WiFi", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.green)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            // Radar rings
            ZStack {
                Circle().stroke(.white.opacity(0.07), lineWidth: 1).frame(width: 290, height: 290)
                Circle().stroke(.white.opacity(0.05), lineWidth: 1).frame(width: 190, height: 190)

                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(NoBarsTheme.accent.opacity(0.4), lineWidth: 1.5)
                        .frame(
                            width:  pulse ? CGFloat(80 + i * 70) : 30,
                            height: pulse ? CGFloat(80 + i * 70) : 30
                        )
                        .opacity(pulse ? 0 : 1)
                        .animation(
                            .easeOut(duration: 2.2)
                                .repeatForever(autoreverses: false)
                                .delay(Double(i) * 0.65),
                            value: pulse
                        )
                }

                VStack(spacing: 8) {
                    InitialsAvatar(name: name, size: 58)
                    Text("Nearby").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: 290, height: 290)

            VStack(spacing: 6) {
                Text("No GPS direction yet")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                Text("Ask \(name) to tap **Share location** in the Map tab.\nOnce they share, a live compass arrow appears here.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            if mesh.isLocationDenied { locationDeniedButton }
        }
    }

    // MARK: - Shared helpers

    private var locationDeniedButton: some View {
        Button { mesh.openSystemSettings() } label: {
            Label("Enable Location in Settings", systemImage: "location.slash")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(NoBarsTheme.alert.opacity(0.15), in: Capsule())
                .foregroundStyle(NoBarsTheme.alert)
        }
    }

    private func distanceText(_ m: Double) -> String {
        m < 1000 ? "\(Int(m.rounded())) m" : String(format: "%.1f km", m / 1000)
    }

    private func cardinalLabel(_ bearing: Double) -> String {
        let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"]
        return dirs[Int((bearing + 11.25) / 22.5) % 16]
    }
}

// MARK: - Compass rose

/// The rotating dial. Cardinal text is counter-rotated so labels stay
/// upright on screen as the device turns.
private struct CompassRose: View {
    let deviceHeading: Double

    private let labels: [(String, Double)] = [
        ("N",0),("NE",45),("E",90),("SE",135),
        ("S",180),("SW",225),("W",270),("NW",315)
    ]

    var body: some View {
        ZStack {
            // Outer and inner reference circles
            Circle().stroke(.white.opacity(0.12), lineWidth: 1.5)
            Circle().stroke(.white.opacity(0.05), lineWidth: 1).padding(72)

            // Tick marks — 72 ticks × 5° = 360°
            ForEach(0..<72, id: \.self) { i in
                let deg  = Double(i) * 5.0
                let card = i % 18 == 0  // every 90°
                let ord  = i % 9  == 0  // every 45°
                Rectangle()
                    .fill(card ? .white.opacity(0.65) : ord ? .white.opacity(0.3) : .white.opacity(0.1))
                    .frame(width: card ? 2.5 : 1, height: card ? 18 : ord ? 11 : 6)
                    .offset(y: -133)
                    .rotationEffect(.degrees(deg))
            }

            // Cardinal / ordinal labels — counter-rotated to stay upright
            GeometryReader { geo in
                let cx = geo.size.width  / 2
                let cy = geo.size.height / 2
                let r: CGFloat = 108

                ForEach(labels, id: \.0) { label, angle in
                    let rad = angle * .pi / 180
                    let x = cx + r * sin(rad)
                    let y = cy - r * cos(rad)
                    let isMain = label.count == 1

                    Text(label)
                        .font(.system(size: isMain ? 13 : 9, weight: isMain ? .bold : .semibold))
                        .foregroundStyle(label == "N" ? Color.red : .white.opacity(isMain ? 0.8 : 0.45))
                        // counter-rotate by (deviceHeading − angle) so the net screen
                        // rotation cancels the rose's own −deviceHeading rotation
                        .rotationEffect(.degrees(deviceHeading - angle))
                        .position(x: x, y: y)
                }
            }
        }
    }
}

// MARK: - Compass needle

/// Arrow pointing "up" within its own frame. The parent rotates the whole
/// frame to the correct bearing, so the arrowhead always aims at the target.
private struct CompassNeedle: View {
    let stale: Bool

    private var color: Color { stale ? .white.opacity(0.35) : NoBarsTheme.accent }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Arrowhead
                Triangle()
                    .fill(color)
                    .frame(width: 15, height: 22)
                // Shaft
                Rectangle()
                    .fill(color.opacity(0.65))
                    .frame(width: 3, height: 72)
                // Tail counterpoint (opposite end, dimmer)
                Triangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 10, height: 15)
                    .rotationEffect(.degrees(180))
                Spacer().frame(height: 72)
            }
            .offset(y: -18)

            // Pivot dot
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path {
            $0.move(to: CGPoint(x: rect.midX, y: rect.minY))
            $0.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            $0.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            $0.closeSubpath()
        }
    }
}
