import SwiftUI

struct WalkthroughView: View {

    var onFinish: () -> Void
    @State private var index = 0

    private struct Page: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
        let tint: Color
    }

    private let pages: [Page] = [
        Page(icon: "antenna.radiowaves.left.and.right",
             title: "Go Live",
             body: "On the Home tab, tap Go Live. Your phone starts looking for others in your group \u{2014} no internet, no towers, just nearby phones.",
             tint: NoBarsTheme.accent),
        Page(icon: "person.2.fill",
             title: "Find your people",
             body: "Connected buddies appear in the People strip on the Home tab. Tap their chip to call or video-chat \u{2014} all over the mesh, no internet.",
             tint: .blue),
        Page(icon: "bubble.left.and.bubble.right.fill",
             title: "Chat with the crew",
             body: "Send group messages in Chat. They hop phone-to-phone across the crowd, so they reach people even beyond your direct range.",
             tint: .teal),
        Page(icon: "location.fill",
             title: "Share location & SOS",
             body: "From Home, drop your live location on everyone's map \u{2014} or send an SOS to broadcast your position as urgent if you need help.",
             tint: NoBarsTheme.alert),
        Page(icon: "map.fill",
             title: "See everyone on the map",
             body: "The Map tab plots your crew\u{2019}s live pins as their locations come in \u{2014} red means they\u{2019}re sending an SOS.",
             tint: .green),
        Page(icon: "dot.radiowaves.left.and.right",
             title: "Range grows with the crowd",
             body: "Every phone relays for the others, so the mesh stretches hop-by-hop across a venue. Keep Wi-Fi + Bluetooth radios on for the best range \u{2014} still zero internet.",
             tint: .indigo),
    ]

    var body: some View {
        ZStack {
            NoBarsTheme.immersiveGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish() }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Group {
                    TabView(selection: $index) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { i, page in
                            pageView(page).tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }

                dots
                controls
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private func pageView(_ page: Page) -> some View {
        VStack(spacing: 24) {
            Image(systemName: page.icon)
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 120, height: 120)
                .background(page.tint.opacity(0.35), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
            Text(page.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(page.body)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 8)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i == index ? 1 : 0.3))
                    .frame(width: i == index ? 22 : 8, height: 8)
                    .animation(.spring(duration: 0.3), value: index)
            }
        }
    }

    private var controls: some View {
        Button {
            if index >= pages.count - 1 {
                onFinish()
            } else {
                withAnimation { index += 1 }
            }
        } label: {
            Text(index >= pages.count - 1 ? "Start using NoBars" : "Next")
        }
        .buttonStyle(NoBarsButtonStyle(
            tint: LinearGradient(colors: [.white], startPoint: .top, endPoint: .bottom),
            foreground: NoBarsTheme.accent
        ))
    }
}
