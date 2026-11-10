import SwiftUI

/// Guided first-run journey: Welcome → your name → create/join a mesh group →
/// enter. On finish it configures the mesh identity and goes live.
struct OnboardingView: View {

    let mesh: MeshConnectivityManager
    var onFinish: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, name, group, ready
    }

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var group = ""

    var body: some View {
        ZStack {
            NoBarsTheme.immersiveGradient.ignoresSafeArea()

            VStack(spacing: 28) {
                progressDots
                Spacer(minLength: 0)
                content
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                Spacer(minLength: 0)
                controls
            }
            .padding(24)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear {
            if name.isEmpty { name = mesh.myName == "iPhone" ? "" : mesh.myName }
            if group.isEmpty { group = mesh.groupCode }
        }
    }

    // MARK: Progress

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(.white.opacity(s.rawValue <= step.rawValue ? 1 : 0.3))
                    .frame(width: s == step ? 22 : 8, height: 8)
                    .animation(.spring(duration: 0.3), value: step)
            }
        }
    }

    // MARK: Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .name:    nameStep
        case .group:   groupStep
        case .ready:   readyStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 72, weight: .semibold))
            Text("NoBars")
                .font(.largeTitle.bold())
            Text("Like AirDrop \u{2014} but for chat, calls & location.\nWorks with no Wi-Fi network, no cell, no internet.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))

            VStack(spacing: 8) {
                offGridChip("wifi.slash", "No network needed")
                offGridChip("antenna.radiowaves.left.and.right.slash", "No cell towers")
                offGridChip("airplane", "Works in Airplane Mode")
            }
            .padding(.top, 6)

            Text("Just keep Wi-Fi & Bluetooth toggled on (like you do for AirDrop) \u{2014} phones talk directly, nothing leaves your group.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private func offGridChip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.white.opacity(0.12), in: Capsule())
    }

    private var nameStep: some View {
        VStack(spacing: 18) {
            stepIcon("person.fill")
            Text("What should buddies\ncall you?")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            glassField("Your name", text: $name)
            Text("iOS hides your real device name, so pick one your crew will recognise.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    private var groupStep: some View {
        VStack(spacing: 18) {
            stepIcon("person.3.fill")
            Text("Create or join\na mesh")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            glassField("Group code — or leave blank for open mesh", text: $group)
            Button {
                group = Self.suggestGroupCode()
            } label: {
                Label("Suggest a code", systemImage: "wand.and.stars")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text("**Leave blank** — connects to any NoBars device nearby.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                Text("**Enter a code** — only phones with the same code can join. Share it with your crew.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var readyStep: some View {
        VStack(spacing: 18) {
            stepIcon("checkmark.seal.fill")
            Text("You\u{2019}re set, \(name.isEmpty ? "friend" : name)!")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                summaryRow("person.fill", "Name", name)
                Divider().overlay(.white.opacity(0.2))
                summaryRow("person.3.fill", "Mesh group", group.trimmingCharacters(in: .whitespaces).isEmpty ? "Open mesh" : group)
            }
            .padding(18)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

            Text("Next you\u{2019}ll be asked for Local Network, Location, Mic & Camera \u{2014} tap Allow so buddies, pings and calls work offline.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            Button(action: advance) {
                Text(step == .ready ? "Enter the Mesh" : "Continue")
            }
            .buttonStyle(NoBarsButtonStyle(
                tint: LinearGradient(colors: [.white], startPoint: .top, endPoint: .bottom),
                foreground: NoBarsTheme.accent
            ))
            .disabled(!canAdvance)

            if step != .welcome {
                Button("Back") { back() }
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: Logic

    private var canAdvance: Bool {
        switch step {
        case .name:  return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .group: return true
        default:     return true
        }
    }

    private func advance() {
        if step == .ready {
            mesh.joinMesh(name: name, group: group)
            UserDefaults.standard.set(true, forKey: "nobars.onboarded")
            onFinish()
            return
        }
        withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .ready }
    }

    private func back() {
        withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
    }

    private static func suggestGroupCode() -> String {
        let words = ["squad", "crew", "party", "pack", "gang"]
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(words.randomElement() ?? "crew")-\(suffix)"
    }

    // MARK: Small helpers

    private func stepIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 52, weight: .semibold))
            .foregroundStyle(.white)
            .padding(24)
            .background(.white.opacity(0.14), in: Circle())
    }

    private func glassField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(.white.opacity(0.5)))
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .autocorrectionDisabled()
            .padding(16)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.25), lineWidth: 1))
    }

    private func summaryRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack {
            Label(label, systemImage: symbol)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Text(value.isEmpty ? "\u{2014}" : value)
                .fontWeight(.semibold)
        }
    }
}
