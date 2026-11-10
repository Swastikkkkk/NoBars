import SwiftUI
import UIKit

struct DashboardView: View {
    let mesh: MeshConnectivityManager
    @State private var selectedTab = 0
    @State private var showSettings = false
    @State private var unread = 0

    /// Debug-only: steps through tabs for CI screenshots (`-meshTestTabs 0,1,2`).
    private func runScreenshotTour() async {
        #if DEBUG
        guard let seq = UserDefaults.standard.string(forKey: "meshTestTabs") else { return }
        let waitForSOS = UserDefaults.standard.bool(forKey: "meshTestTabsAfterSOS")
        while mesh.connectedPeers.isEmpty || (waitForSOS && mesh.emergencyBuddies.isEmpty) {
            try? await Task.sleep(for: .seconds(1))
        }
        try? await Task.sleep(for: .seconds(5))
        for tab in seq.split(separator: ",").compactMap({ Int($0) }) {
            selectedTab = tab
            mesh.note("SHOT tab \(tab)")
            try? await Task.sleep(for: .seconds(16))
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab(mesh: mesh, showSettings: $showSettings, selectedTab: $selectedTab)
                .tabItem { Label("Home", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)

            FullChatTab(mesh: mesh)
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(unread)
                .tag(1)

            FullMapTab(mesh: mesh)
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(2)
        }
        .tint(NoBarsTheme.accent)
        .onAppear { applyTabBarStyle() }
        .task { await runScreenshotTour() }
        .onChange(of: selectedTab) { _, tab in if tab == 1 { unread = 0 } }
        .onChange(of: mesh.receivedMessages.count) {
            if selectedTab != 1,
               let last = mesh.receivedMessages.last,
               !last.isSystem,
               last.sender != mesh.myName {
                unread += 1
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = mesh.toast {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(msg)
            }
        }
        .animation(.spring(duration: 0.3), value: mesh.toast)
        .sheet(isPresented: Binding(get: { mesh.voice.isInCall }, set: { if !$0 { mesh.endCall() } })) {
            CallView(voice: mesh.voice)
        }
        .sheet(isPresented: $showSettings) { SettingsView(mesh: mesh) }
    }

    private func applyTabBarStyle() {
        let bar = UITabBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = UIColor(red: 0.06, green: 0.05, blue: 0.14, alpha: 0.98)
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
    }
}

// MARK: - Home tab

private struct HomeTab: View {
    let mesh: MeshConnectivityManager
    @Binding var showSettings: Bool
    @Binding var selectedTab: Int
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if mesh.meshStartError != nil {
                        errorBanner
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    radarSection

                    VStack(spacing: 14) {
                        if mesh.isLive && mesh.connectedPeers.isEmpty { inviteCard }
                        if !mesh.connectedPeers.isEmpty { peopleStrip }
                        chatSection
                        toolsGrid
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .noBarsBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(mesh.groupCode.isEmpty ? "NoBars" : "#\(mesh.groupCode)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        MeshConnectivityManager.haptic()
                        mesh.togglePanic()
                    } label: {
                        Image(systemName: mesh.isPanicBroadcasting ? "location.fill" : "location")
                            .foregroundStyle(mesh.isPanicBroadcasting ? NoBarsTheme.alert : .white.opacity(0.55))
                            .symbolEffect(.pulse, isActive: mesh.isPanicBroadcasting)
                    }
                }
            }
        }
    }

    // MARK: Radar section (full-width immersive)

    private var ringColor: Color {
        !mesh.connectedPeers.isEmpty ? .green : (mesh.isLive ? NoBarsTheme.accent : .white)
    }

    private var radarSection: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mesh.myName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(mesh.groupCode.isEmpty ? "Open mesh" : "#\(mesh.groupCode)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.36))
                }
                Spacer()
                statusPill
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ZStack {
                radarRings
                if mesh.isLive && mesh.connectedPeers.isEmpty {
                    ScanningRing(color: NoBarsTheme.accent)
                }
                if !mesh.connectedPeers.isEmpty {
                    radarCenter
                }
            }
            .frame(height: 246)

            goLiveButton
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.06, blue: 0.20),
                         Color(red: 0.05, green: 0.03, blue: 0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var radarRings: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .stroke(ringColor.opacity(0.04 + Double(3 - i) * 0.04), lineWidth: i == 0 ? 1.5 : 1)
                    .frame(width: CGFloat(260 - i * 52), height: CGFloat(260 - i * 52))
            }
        }
    }

    private var radarCenter: some View {
        VStack(spacing: 4) {
            Text("\(mesh.connectedPeers.count)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.spring(duration: 0.4), value: mesh.connectedPeers.count)
            Text(mesh.connectedPeers.count == 1 ? "buddy nearby" : "buddies nearby")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
            Text(mesh.connectedPeers.prefix(2).joined(separator: " · "))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.green.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)
        }
        .frame(width: 160)
    }

    private var goLiveButton: some View {
        Button {
            MeshConnectivityManager.haptic()
            if mesh.isLive { mesh.leaveMesh() } else { mesh.startHosting(); mesh.startBrowsing() }
        } label: {
            HStack(spacing: 9) {
                if mesh.isLive {
                    Circle()
                        .fill(mesh.connectedPeers.isEmpty ? Color.yellow : Color.green)
                        .frame(width: 8, height: 8)
                }
                Text(mesh.isLive ? (mesh.connectedPeers.isEmpty ? "Scanning…" : "Live") : "Go Live")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                mesh.isLive
                    ? AnyShapeStyle(.white.opacity(0.08))
                    : AnyShapeStyle(NoBarsTheme.brandGradient),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.white.opacity(0.09), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var statusColor: Color {
        !mesh.connectedPeers.isEmpty ? .green : (mesh.isLive ? .yellow : .white.opacity(0.25))
    }
    private var statusLabel: String {
        !mesh.connectedPeers.isEmpty ? "\(mesh.connectedPeers.count) online" : (mesh.isLive ? "Scanning" : "Offline")
    }

    // MARK: Invite card

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(NoBarsTheme.accent)
                Text("Scanning for buddies…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            Text("Share your group code so friends can join.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: mesh.groupCode.isEmpty ? "globe" : "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NoBarsTheme.accent)
                    Text(mesh.groupCode.isEmpty ? "Open mesh" : mesh.groupCode)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(NoBarsTheme.accent)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(NoBarsTheme.accent.opacity(0.1), in: Capsule())

                Spacer()

                ShareLink(item: inviteText) {
                    Label("Invite", systemImage: "person.badge.plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(NoBarsTheme.brandGradient, in: Capsule())
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(NoBarsTheme.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private var inviteText: String {
        mesh.groupCode.isEmpty
            ? "Join my NoBars mesh! Download the app, go live, and we'll connect automatically nearby. No internet needed."
            : "Join my NoBars mesh! Download NoBars, open the app, and enter group code \"\(mesh.groupCode)\". No internet needed."
    }

    // MARK: Error banner

    private var errorBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(NoBarsTheme.alert)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local network blocked")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(mesh.meshStartError ?? "")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Fix") { mesh.openSystemSettings() }
                .font(.caption.weight(.bold))
                .foregroundStyle(NoBarsTheme.alert)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(NoBarsTheme.alert.opacity(0.15), in: Capsule())
        }
        .padding(14)
        .background(NoBarsTheme.alert.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(NoBarsTheme.alert.opacity(0.18), lineWidth: 1))
    }

    // MARK: People strip

    private var peopleStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CREW")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .tracking(1)
                Spacer()
                Text("\(mesh.connectedPeers.count) online")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(mesh.connectedPeers, id: \.self) { peer in
                        PeerChip(mesh: mesh, name: peer, onMessage: { selectedTab = 1 })
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Chat section

    private var recentRealMessages: [MeshMessage] {
        mesh.receivedMessages.filter { !$0.isSystem }.suffix(3).reversed()
    }

    private var chatSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CHAT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .tracking(1)
                Spacer()
                if !mesh.receivedMessages.filter({ !$0.isSystem }).isEmpty {
                    Button { selectedTab = 1 } label: {
                        Text("View all →")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NoBarsTheme.accent)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            Divider().overlay(.white.opacity(0.05))

            if recentRealMessages.isEmpty {
                Text(mesh.connectedPeers.isEmpty ? "Go live to start chatting with nearby phones" : "No messages yet — say hi!")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 14)
            } else {
                ForEach(recentRealMessages) { m in
                    HStack(alignment: .top, spacing: 10) {
                        InitialsAvatar(name: m.sender, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.sender == mesh.myName ? "You" : m.sender)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(m.sender == mesh.myName ? NoBarsTheme.accent : .white.opacity(0.8))
                                Spacer()
                                Text(m.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.28))
                            }
                            Text(m.text)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider().overlay(.white.opacity(0.05)).padding(.leading, 58)
                }
            }

            Divider().overlay(.white.opacity(0.05))

            HStack(spacing: 10) {
                TextField("", text: $draft,
                          prompt: Text("Send a message…")
                            .foregroundColor(.white.opacity(0.22)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.subheadline)
                    .onSubmit(sendMessage)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? NoBarsTheme.accent : .white.opacity(0.12))
                }
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private func sendMessage() {
        guard canSend else { return }
        mesh.sendMessage(draft)
        draft = ""
        selectedTab = 1
    }

    // MARK: Tools grid

    private var toolsGrid: some View {
        HStack(spacing: 12) {
            NavigationLink { CompassView(mesh: mesh) } label: {
                toolTile(
                    gradient: LinearGradient(
                        colors: [NoBarsTheme.accent.opacity(0.35), NoBarsTheme.accent.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    icon: "location.north.line.fill",
                    label: "Compass",
                    detail: mesh.connectedPeers.isEmpty ? "Go live first" : "\(mesh.connectedPeers.count) trackable"
                )
            }
            .buttonStyle(.plain)

            NavigationLink { BuddyMapView(mesh: mesh) } label: {
                toolTile(
                    gradient: LinearGradient(
                        colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.08)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    icon: "map.fill",
                    label: "Map",
                    detail: mesh.buddyLocations.isEmpty ? "No pings yet" : "\(mesh.buddyLocations.count) pinned"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func toolTile(gradient: LinearGradient, icon: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .frame(height: 122)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Scanning ring (separate view so onAppear fires on every scan start)

private struct ScanningRing: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.0, to: 0.78)
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 122, height: 122)
            .rotationEffect(.degrees(rotation - 90))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Peer chip

private struct PeerChip: View {
    let mesh: MeshConnectivityManager
    let name: String
    let onMessage: () -> Void

    private var firstName: String {
        String(name.split(separator: " ").first ?? Substring(name))
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                InitialsAvatar(name: name, size: 52)
                if mesh.emergencyBuddies.contains(name) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(NoBarsTheme.alert)
                        .offset(x: 2, y: 2)
                } else if mesh.buddyLocations[name] != nil {
                    Circle().fill(.green).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(.black, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }

            Text(firstName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)

            HStack(spacing: 6) {
                chipButton("message.fill") { onMessage() }
                chipButton("phone.fill") { mesh.startCall(with: name) }
                chipButton("video.fill") { mesh.startCall(with: name, video: true) }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }

    private func chipButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button { MeshConnectivityManager.haptic(); action() } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NoBarsTheme.accent)
                .frame(width: 28, height: 28)
                .background(NoBarsTheme.accent.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(mesh.voice.isInCall && icon != "message.fill")
    }
}

// MARK: - Full Chat tab

private struct FullChatTab: View {
    let mesh: MeshConnectivityManager
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private let quickReplies = [
        "Where are you? 👀",
        "I'm here! Come find me 📍",
        "On my way! 🏃"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
                composerBar
            }
            .noBarsBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text("Chat")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(peerSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
    }

    private var peerSubtitle: String {
        switch mesh.connectedPeers.count {
        case 0: return "no one on mesh yet"
        case 1: return "1 person on mesh"
        default: return "\(mesh.connectedPeers.count) people on mesh"
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if mesh.receivedMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(mesh.receivedMessages.enumerated()), id: \.element.id) { i, m in
                            let mine = m.sender == mesh.myName
                            let nextReal = (i + 1..<mesh.receivedMessages.count).first { !mesh.receivedMessages[$0].isSystem }
                            let prevReal = (0..<i).last { !mesh.receivedMessages[$0].isSystem }
                            let nextSame = nextReal.map { mesh.receivedMessages[$0].sender == m.sender } ?? false
                            let prevSame = prevReal.map { mesh.receivedMessages[$0].sender == m.sender } ?? false
                            ChatBubble(
                                message: m,
                                mine: mine,
                                showAvatar: !mine && !nextSame && !m.isSystem,
                                showName: !mine && !prevSame && !m.isSystem,
                                isLastInGroup: !nextSame
                            )
                            .id(m.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: mesh.receivedMessages.count) {
                if let last = mesh.receivedMessages.last {
                    withAnimation(.spring(duration: 0.3)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(NoBarsTheme.accent.opacity(0.08))
                    .frame(width: 90, height: 90)
                Circle()
                    .stroke(NoBarsTheme.accent.opacity(0.12), lineWidth: 1)
                    .frame(width: 90, height: 90)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(NoBarsTheme.accent.opacity(0.55))
            }
            VStack(spacing: 7) {
                Text("Start the conversation")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text("Messages hop phone-to-phone\nacross everyone on your mesh")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.3))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private var quickReplyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        MeshConnectivityManager.haptic()
                        mesh.sendMessage(reply)
                    } label: {
                        Text(reply)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.09), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.13), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.2))
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.05)).frame(height: 1)
            if !mesh.connectedPeers.isEmpty {
                quickReplyRow
            }
            HStack(spacing: 10) {
                TextField("", text: $draft,
                          prompt: Text("Message…").foregroundColor(.white.opacity(0.28)))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.subheadline)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.07), in: Capsule())
                    .overlay(
                        Capsule().stroke(.white.opacity(composerFocused ? 0.18 : 0.07), lineWidth: 1)
                    )

                Button(action: send) {
                    ZStack {
                        Circle()
                            .fill(canSend ? NoBarsTheme.accent : Color.white.opacity(0.08))
                            .frame(width: 38, height: 38)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(canSend ? .white : .white.opacity(0.2))
                    }
                }
                .disabled(!canSend)
                .animation(.spring(duration: 0.2), value: canSend)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.35))
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() { guard canSend else { return }; mesh.sendMessage(draft); draft = "" }
}

// MARK: - Full Map tab

private struct FullMapTab: View {
    let mesh: MeshConnectivityManager

    var body: some View {
        NavigationStack {
            BuddyMapView(mesh: mesh)
                .navigationTitle("Live Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            MeshConnectivityManager.haptic()
                            mesh.togglePanic()
                        } label: {
                            Label(mesh.isPanicBroadcasting ? "Sharing" : "Share",
                                  systemImage: mesh.isPanicBroadcasting ? "location.fill.viewfinder" : "location")
                                .foregroundStyle(mesh.isPanicBroadcasting ? NoBarsTheme.alert : .primary)
                                .symbolEffect(.pulse, isActive: mesh.isPanicBroadcasting)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink { CompassView(mesh: mesh) } label: {
                            Image(systemName: "location.north.line.fill")
                        }
                    }
                }
        }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: MeshMessage
    let mine: Bool
    let showAvatar: Bool
    let showName: Bool
    let isLastInGroup: Bool

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.white.opacity(0.05), in: Capsule())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if !mine {
                    Group {
                        if showAvatar {
                            InitialsAvatar(name: message.sender, size: 30)
                        } else {
                            Color.clear.frame(width: 30)
                        }
                    }
                }

                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if showName {
                        Text(message.sender)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.42))
                            .padding(mine ? .trailing : .leading, 6)
                    }

                    HStack(alignment: .bottom, spacing: 0) {
                        if mine { Spacer(minLength: 64) }

                        Text(message.text)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                mine
                                    ? AnyShapeStyle(NoBarsTheme.brandGradient)
                                    : AnyShapeStyle(Color.white.opacity(0.1)),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )

                        if !mine { Spacer(minLength: 64) }
                    }

                    if isLastInGroup {
                        Group {
                            if message.pending {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock").font(.caption2)
                                    Text("Sending…").font(.caption2)
                                }
                                .foregroundStyle(.white.opacity(0.28))
                            } else {
                                Text(message.date.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.28))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                        .padding(mine ? .trailing : .leading, 6)
                    }
                }
            }
            .padding(.vertical, isLastInGroup ? 4 : 1)
        }
    }
}

// MARK: - Initials avatar

struct InitialsAvatar: View {
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return letters.isEmpty ? "?" : letters
    }
    private var tint: Color {
        [Color.purple, .blue, .teal, .pink, .orange, .indigo, .mint][abs(name.hashValue) % 7]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: Circle())
    }
}

// MARK: - Settings

private struct SettingsView: View {
    let mesh: MeshConnectivityManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("nobars.onboarded") private var onboarded = false
    @AppStorage("nobars.walkthroughDone") private var walkthroughDone = true
    @State private var name = ""
    @State private var group = ""
    @State private var showDiagnostics = false

    private var groupLabel: String { group.trimmingCharacters(in: .whitespaces) }
    private var shareText: String {
        groupLabel.isEmpty
            ? "Join my NoBars mesh! Download the app and go live — we'll connect nearby automatically. No internet needed."
            : "Join my NoBars mesh! Download NoBars, open the app, and enter group code \"\(groupLabel)\". No internet needed."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    LabeledContent("Name") {
                        TextField("Your name", text: $name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Group code") {
                        TextField("blank = open mesh", text: $group)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled()
                    }
                    Button("Save changes") { mesh.configure(name: name, group: group); dismiss() }
                        .disabled(
                            (name.trimmingCharacters(in: .whitespaces).isEmpty || name == mesh.myName)
                            && group == mesh.groupCode
                        )
                }

                Section("Invite friends") {
                    LabeledContent("Group code") {
                        Text(mesh.groupCode.isEmpty ? "Open mesh" : mesh.groupCode)
                            .foregroundStyle(.secondary)
                    }
                    ShareLink(item: shareText) {
                        Label("Share invite", systemImage: "square.and.arrow.up")
                    }
                    Text(mesh.groupCode.isEmpty
                         ? "You're on an open mesh — any nearby NoBars phone can find you."
                         : "Only phones with code \"\(mesh.groupCode)\" can join your mesh.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Live Activity") {
                    Button("Test lock-screen banner") { mesh.testLiveActivity() }
                }

                Section {
                    LabeledContent("Your key", value: mesh.myFingerprint)
                        .font(.body.monospaced())
                    Button("Reset trusted buddies") { mesh.resetTrustedBuddies() }
                    Button("Clear chat history", role: .destructive) { mesh.clearChatHistory() }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Messages are encrypted with your group code and signed by each phone. A buddy's key is trusted the first time you meet. Reset if a friend reinstalls the app.")
                }

                Section("App") {
                    Button("Replay tutorial") {
                        walkthroughDone = false
                        dismiss()
                    }
                }

                Section {
                    DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                        if mesh.statusLog.isEmpty {
                            Text("No activity yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(mesh.statusLog.suffix(20).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        mesh.leaveMesh(); onboarded = false; dismiss()
                    } label: {
                        Label("Leave mesh & reset", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .noBarsBackground()
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { name = mesh.myName; group = mesh.groupCode }
        }
    }
}
