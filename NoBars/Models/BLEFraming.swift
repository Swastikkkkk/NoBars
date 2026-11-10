import Foundation

/// Splits sealed packets into Bluetooth LE writes and puts them back together.
/// Same format as `BleFraming` in the Android app (see protocol/PROTOCOL.md).
///
/// Frame: [version=1][message seq u32 big-endian][index u8][count u8][chunk...]
nonisolated enum BLEFraming {
    static let version: UInt8 = 1
    static let header = 7
    static let maxChunks = 255

    static func split(_ message: Data, seq: UInt32, maxFrame: Int) -> [Data] {
        let chunkSize = maxFrame - header
        guard chunkSize > 0 else { return [] }
        let count = max(1, (message.count + chunkSize - 1) / chunkSize)
        guard count <= maxChunks else { return [] }
        let bytes = [UInt8](message)
        return (0..<count).map { i in
            let from = i * chunkSize, to = min(bytes.count, from + chunkSize)
            var frame = Data([version])
            withUnsafeBytes(of: seq.bigEndian) { frame.append(contentsOf: $0) }
            frame.append(UInt8(i)); frame.append(UInt8(count))
            frame.append(contentsOf: bytes[from..<to])
            return frame
        }
    }

    /// Reassembles frames from one link. Returns the message once its last chunk lands.
    struct Reassembler {
        private struct Partial { let count: Int; let started: Date; var parts: [Data?]; var have = 0 }
        private var partials: [UInt32: Partial] = [:]

        init() {}

        mutating func accept(_ frame: Data, now: Date = Date()) -> Data? {
            let b = [UInt8](frame)
            guard b.count >= BLEFraming.header, b[0] == BLEFraming.version else { return nil }
            let seq = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
            let index = Int(b[5]), count = Int(b[6])
            guard count > 0, index < count else { return nil }
            partials = partials.filter { now.timeIntervalSince($0.value.started) < 30 }
            var p = partials[seq] ?? Partial(count: count, started: now, parts: Array(repeating: nil, count: count))
            guard p.count == count else { return nil }
            if p.parts[index] == nil { p.parts[index] = Data(b[BLEFraming.header...]); p.have += 1 }
            guard p.have == count else { partials[seq] = p; return nil }
            partials[seq] = nil
            return p.parts.reduce(into: Data()) { $0.append($1!) }
        }
    }
}
