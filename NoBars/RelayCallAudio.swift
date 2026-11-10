import Foundation
@preconcurrency import AVFoundation

/// Audio for calls that hop through other phones.
///
/// Direct calls stream 48 kHz float PCM, which is far too much to relay. Here
/// the mic is downsampled to 8 kHz and mu-law encoded (G.711, 8 KB/s), cut into
/// 160 ms chunks, and each chunk travels the mesh as a signed, sealed `.voice`
/// packet. The far end plays chunks in order and skips late ones.
nonisolated final class RelayCallAudio: @unchecked Sendable {

    static let sampleRate = 8_000.0
    /// 160 ms per packet: few enough packets for the mesh, short enough to feel live.
    static let chunkSamples = 1_280

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let netFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RelayCallAudio.sampleRate,
                                          channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let onChunk: (Data) -> Void
    private let lock = NSLock()
    private var pending: [Float] = []
    private var lastPlayedSeq = -1
    private var queued = 0
    private var muted = false
    private let playbackGain: Float = 2.0

    init(onChunk: @escaping (Data) -> Void) {
        self.onChunk = onChunk
    }

    func setMuted(_ value: Bool) { lock.lock(); muted = value; lock.unlock() }

    func setSpeaker(_ on: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
    }

    func start(speaker: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try? session.setActive(true)
        setSpeaker(speaker)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: netFormat)
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: netFormat)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { callLog.error("relay audio engine failed: \(error.localizedDescription, privacy: .public)") }
        player.play()
        callLog.info("relay call audio started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let isMuted = muted; lock.unlock()
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * netFormat.sampleRate / buffer.format.sampleRate) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: netFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        // Keep sending silence while muted so the other side's playback stays in step.
        pending.append(contentsOf: isMuted ? [Float](repeating: 0, count: samples.count) : Array(samples))
        while pending.count >= Self.chunkSamples {
            let chunk = pending.prefix(Self.chunkSamples)
            pending.removeFirst(Self.chunkSamples)
            onChunk(Data(chunk.map { MuLaw.encode($0) }))
        }
    }

    // MARK: Playback

    func play(_ data: Data, seq: Int) {
        lock.lock()
        // Skip chunks that arrive after a later one, and don't let a backlog build up.
        let late = seq <= lastPlayedSeq && lastPlayedSeq - seq < 10_000
        let backlog = queued > 6
        if !late && !backlog { lastPlayedSeq = seq; queued += 1 }
        lock.unlock()
        guard !late && !backlog,
              let buffer = AVAudioPCMBuffer(pcmFormat: netFormat, frameCapacity: AVAudioFrameCount(data.count)),
              let ch = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(data.count)
        for (i, b) in data.enumerated() { ch[0][i] = max(-1, min(1, MuLaw.decode(b) * playbackGain)) }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }
}

/// G.711 mu-law, 8 bits per sample.
nonisolated enum MuLaw {
    private static let bias = 0x84
    private static let clip = 32_635

    static func encode(_ x: Float) -> UInt8 {
        var s = Int(max(-1, min(1, x)) * 32_767)
        let sign = s < 0 ? 0x80 : 0
        if s < 0 { s = -s }
        s = min(s, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0 && s & mask == 0 { exponent -= 1; mask >>= 1 }
        let mantissa = (s >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    static func decode(_ b: UInt8) -> Float {
        let u = Int(~b & 0xFF)
        let sign = u & 0x80, exponent = (u >> 4) & 0x07, mantissa = u & 0x0F
        var s = ((mantissa << 3) + bias) << exponent
        s -= bias
        return Float(sign != 0 ? -s : s) / 32_768
    }
}
