import SwiftUI

/// Full-screen call UI for an active mesh call. Shows the remote video (or an
/// avatar for audio-only / while connecting), a local camera preview, and
/// high-contrast controls that stay readable over any video background.
struct CallView: View {

    let voice: MeshVoiceCallManager

    var body: some View {
        ZStack {
            background
            topScrim
            bottomScrim
            VStack {
                header
                Spacer()
                controls
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .overlay(alignment: .topTrailing) { localPreview }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Background

    @ViewBuilder
    private var background: some View {
        if let remote = voice.remoteFrame {
            // Standard video-call layout: the remote fills the screen edge-to-edge.
            GeometryReader { geo in
                Image(decorative: remote, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
        } else {
            ZStack {
                NoBarsTheme.immersiveGradient.ignoresSafeArea()
                VStack(spacing: 16) {
                    InitialsAvatar(name: voice.activePeer ?? "?", size: 108)
                    Text(connectingText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    private var connectingText: String {
        voice.isVideoOn ? "Waiting for their camera\u{2026}" : "On call \u{00B7} audio"
    }

    private var topScrim: some View {
        LinearGradient(colors: [.black.opacity(0.55), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 180)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var bottomScrim: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.65)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: 220)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(voice.activePeer ?? "")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Label("End-to-end encrypted \u{00B7} on mesh", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.black.opacity(0.3), in: Capsule())
        }
    }

    // MARK: Local preview

    @ViewBuilder
    private var localPreview: some View {
        if voice.isVideoOn {
            Group {
                if let local = voice.localFrame {
                    Image(decorative: local, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.black.opacity(0.5)
                        Image(systemName: "video.fill").foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(width: 104, height: 146)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.5), lineWidth: 1))
            // Sits inside the safe-area content, so it can't slide off-screen.
            .padding(.top, 44)
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(alignment: .top, spacing: 14) {
            controlButton("Mute", voice.isMuted ? "mic.slash.fill" : "mic.fill",
                          engaged: voice.isMuted) { voice.isMuted.toggle() }

            controlButton("Speaker", voice.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill",
                          engaged: voice.isSpeakerOn) { voice.isSpeakerOn.toggle() }

            controlButton("Video", voice.isVideoOn ? "video.fill" : "video.slash.fill",
                          engaged: voice.isVideoOn) { voice.toggleVideo() }

            if voice.isVideoOn {
                controlButton("Flip", "arrow.triangle.2.circlepath.camera.fill",
                              engaged: false) { voice.flipCamera() }
            }

            controlButton("End", "phone.down.fill", engaged: false, destructive: true) {
                voice.endCall()
            }
        }
    }

    private func controlButton(_ label: String,
                               _ symbol: String,
                               engaged: Bool,
                               destructive: Bool = false,
                               action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(iconColor(engaged: engaged, destructive: destructive))
                    .frame(width: 60, height: 60)
                    .background(fill(engaged: engaged, destructive: destructive), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    private func fill(engaged: Bool, destructive: Bool) -> Color {
        if destructive { return NoBarsTheme.alert }
        return engaged ? .white : .white.opacity(0.18)
    }

    private func iconColor(engaged: Bool, destructive: Bool) -> Color {
        if destructive { return .white }
        return engaged ? .black : .white
    }
}
