import AppIntents

/// "Hey Siri, go live on NoBars": opens the app and starts the mesh.
nonisolated struct GoLiveIntent: AppIntent {
    static let title: LocalizedStringResource = "Go Live on Mesh"
    static let description = IntentDescription("Opens NoBars and starts finding nearby buddies.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mesh = MeshConnectivityManager.shared
        if !mesh.isLive { mesh.startHosting(); mesh.startBrowsing() }
        let count = mesh.connectedPeers.count
        return .result(dialog: count == 0 ? "You're live. Looking for buddies." : "You're live with \(count) nearby.")
    }
}

/// "Hey Siri, send SOS on NoBars": floods your location to the group.
nonisolated struct SendSOSIntent: AppIntent {
    static let title: LocalizedStringResource = "Send SOS"
    static let description = IntentDescription("Shares your live location with everyone on your mesh until you stop it.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        MeshConnectivityManager.shared.handle(url: URL(string: "nobars://sos")!)
        return .result(dialog: "Sharing your location with your mesh.")
    }
}

nonisolated struct NoBarsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GoLiveIntent(),
            phrases: ["Go live on \(.applicationName)", "Find my crew on \(.applicationName)"],
            shortTitle: "Go Live",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: SendSOSIntent(),
            phrases: ["Send SOS on \(.applicationName)", "Share my location on \(.applicationName)"],
            shortTitle: "Send SOS",
            systemImageName: "location.fill"
        )
    }
}
