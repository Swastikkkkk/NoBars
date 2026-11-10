import Foundation

/// Chat history and unsent messages for one group, kept on disk so they
/// survive the app being closed. Each group gets its own file, named by the
/// group's discovery tag, protected with iOS data protection.
struct ChatArchive: Codable {
    struct Queued: Codable {
        let packet: MeshRelayPacket
        let messageID: UUID
    }

    var messages: [MeshMessage] = []
    var outbox: [Queued] = []

    /// Oldest messages are dropped past this so the file stays small.
    static let limit = 1000
}

enum ChatStore {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Chats", isDirectory: true)
    }

    private static func url(for tag: String) -> URL {
        folder.appendingPathComponent("\(tag).json")
    }

    static func load(tag: String) -> ChatArchive {
        guard let data = try? Data(contentsOf: url(for: tag)),
              let archive = try? JSONDecoder().decode(ChatArchive.self, from: data) else { return ChatArchive() }
        return archive
    }

    static func save(_ archive: ChatArchive, tag: String) {
        var trimmed = archive
        if trimmed.messages.count > ChatArchive.limit {
            trimmed.messages.removeFirst(trimmed.messages.count - ChatArchive.limit)
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: tag), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func delete(tag: String) {
        try? FileManager.default.removeItem(at: url(for: tag))
    }
}
