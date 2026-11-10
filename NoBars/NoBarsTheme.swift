import SwiftUI

enum NoBarsTheme {
    static let accent      = Color(red: 0.45, green: 0.30, blue: 0.95)
    static let alert       = Color(red: 0.95, green: 0.23, blue: 0.30)
    static let accentDeep  = Color(red: 0.30, green: 0.20, blue: 0.85)

    static let brandGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let immersiveGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.07, blue: 0.22),
                 Color(red: 0.20, green: 0.12, blue: 0.42),
                 accent],
        startPoint: .top, endPoint: .bottom
    )

    static let screenGradient = LinearGradient(
        colors: [Color(red: 0.06, green: 0.05, blue: 0.13),
                 Color(red: 0.10, green: 0.07, blue: 0.20)],
        startPoint: .top, endPoint: .bottom
    )
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    func noBarsBackground() -> some View {
        self.background(NoBarsTheme.screenGradient.ignoresSafeArea())
    }
}

struct NoBarsButtonStyle: ButtonStyle {
    var tint: LinearGradient = NoBarsTheme.brandGradient
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(tint, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
