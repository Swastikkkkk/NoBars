import Foundation
import Observation
@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import ImageIO
import MultipeerConnectivity
import os

/// Shared logger for the call pipeline. View live with:
/// `log stream --predicate 'subsystem == "com.swastik.nobars"'`
nonisolated let callLog = Logger(subsystem: "com.swastik.nobars", category: "call")

/// Offline voice calls that ride over the same `MCSession` as the mesh.
///
/// There is no signalling server and no WebRTC: on a local mesh you already
/// hold a direct, encrypted peer connection, so audio is streamed as raw PCM
/// over an `MCSession` byte stream. Each direction is its own one-way stream —
/// the caller opens one to the callee, and the callee answers by opening one
/// back — giving full-duplex audio.
///
/// This class is the main-actor, observable UI facade. The realtime audio +
/// stream I/O lives in `AudioBridge`, which runs off the main actor.
@MainActor
@Observable
final class MeshVoiceCallManager {

    /// Display name of the buddy we're on a call with, or `nil` if idle.
    private(set) var activePeer: String?

    var isInCall: Bool { activePeer != nil }

    /// Mute our microphone without ending the call.
    var isMuted = false {
        didSet { bridge?.setMuted(isMuted); relayAudio?.setMuted(isMuted) }
    }

    /// Route audio out of the loudspeaker (on) vs. the earpiece (off).
    var isSpeakerOn = true {
        didSet { bridge?.setSpeaker(isSpeakerOn); relayAudio?.setSpeaker(isSpeakerOn) }
    }

    /// True when the call hops through other phones instead of a direct link.
    /// Relayed calls are audio only.
    private(set) var isRelayCall = false

    /// Set by the mesh manager: sends one encoded audio chunk to `activePeer`.
    @ObservationIgnored var sendRelayAudio: ((Data, Int) -> Void)?
    /// Set by the mesh manager: tells the other side a relayed call ended.
    @ObservationIgnored var sendRelayEnd: ((String) -> Void)?
    @ObservationIgnored private var relayAudio: RelayCallAudio?
    @ObservationIgnored private var relaySeq = 0

    /// Whether our camera is on and streaming.
    private(set) var isVideoOn = false

    /// Latest decoded video frame from the remote buddy.
    private(set) var remoteFrame: CGImage?

    /// Our own latest camera frame, for the local preview.
    private(set) var localFrame: CGImage?

    @ObservationIgnored private var bridge: AudioBridge?
    @ObservationIgnored private var videoBridge: VideoBridge?
    @ObservationIgnored private var peerID: MCPeerID?
    @ObservationIgnored private weak var session: MCSession?

    /// Kept for symmetry with the connectivity manager; the session is passed
    /// per-call so calls always use the current session instance.
    func attach(session: MCSession) {}

    /// Places a call to `peerID`. We open the outbound audio stream immediately;
    /// the callee answers by opening a stream back to us.
    func startCall(to peerID: MCPeerID, session: MCSession) {
        guard activePeer == nil else { return }
        callLog.info("startCall to \(peerID.displayName, privacy: .public)")
        self.peerID = peerID
        self.session = session
        AudioBridge.prewarmMic()    // engine needs mic permission to start (and to play back)
        VideoBridge.prewarmCamera() // so a two-way video upgrade is instant
        startBridge(with: peerID, session: session)
        activePeer = peerID.displayName
    }

    /// Routes an incoming named stream to the audio or video pipeline.
    func handleIncomingStream(_ stream: InputStream, name: String, from peerID: MCPeerID, session: MCSession) {
        self.peerID = peerID
        self.session = session

        if name == AudioBridge.streamName {
            if bridge == nil {
                callLog.info("incoming call from \(peerID.displayName, privacy: .public)")
                AudioBridge.prewarmMic()
                VideoBridge.prewarmCamera()
                startBridge(with: peerID, session: session)
                if activePeer == nil { activePeer = peerID.displayName }
            }
            bridge?.attachInputStream(stream)
        } else if name == VideoBridge.streamName {
            callLog.info("incoming VIDEO stream from \(peerID.displayName, privacy: .public) -> auto-answer")
            if activePeer == nil { activePeer = peerID.displayName }
            ensureVideoBridge(peer: peerID, session: session)
            videoBridge?.attachInputStream(stream)
            // The buddy turned their camera on — auto-answer with ours so it's a
            // two-way video call (like FaceTime), not one-directional.
            if !isVideoOn { startVideo() }
        }
    }

    // MARK: Video controls

    func toggleVideo() {
        guard !isRelayCall else { return }
        isVideoOn ? stopVideo() : startVideo()
    }

    /// Turns video on if it isn't already (used to start a call as video).
    func enableVideo() {
        guard !isRelayCall else { return }
        if !isVideoOn { startVideo() }
    }

    // MARK: Relayed calls

    /// Starts (or answers) a call that hops through other phones.
    func startRelayCall(with name: String) {
        guard activePeer == nil else { return }
        callLog.info("relay call with \(name, privacy: .public)")
        AudioBridge.prewarmMic()
        activePeer = name
        isRelayCall = true
        relaySeq = 0
        let audio = RelayCallAudio { [weak self] chunk in
            Task { @MainActor in
                guard let self, self.isRelayCall else { return }
                self.relaySeq += 1
                self.sendRelayAudio?(chunk, self.relaySeq)
            }
        }
        relayAudio = audio
        audio.setMuted(isMuted)
        audio.start(speaker: isSpeakerOn)
    }

    func playRelay(_ audio: Data, seq: Int) {
        relayAudio?.play(audio, seq: seq)
    }

    func flipCamera() {
        videoBridge?.flipCamera()
    }

    private func startVideo() {
        guard let peerID, let session else { callLog.error("startVideo: no peer/session"); return }
        callLog.info("startVideo -> sending our camera to \(peerID.displayName, privacy: .public)")
        ensureVideoBridge(peer: peerID, session: session)
        videoBridge?.startSending()
        isVideoOn = true
    }

    private func stopVideo() {
        videoBridge?.stopSending()
        isVideoOn = false
        localFrame = nil
    }

    func endCall(notifyRemote: Bool = true) {
        if isRelayCall {
            relayAudio?.stop()
            relayAudio = nil
            isRelayCall = false
            if notifyRemote, let peer = activePeer { sendRelayEnd?(peer) }
        }
        bridge?.stop()
        bridge = nil
        videoBridge?.stop()
        videoBridge = nil
        isMuted = false
        isVideoOn = false
        remoteFrame = nil
        localFrame = nil
        activePeer = nil
        peerID = nil
    }

    private func startBridge(with peerID: MCPeerID, session: MCSession) {
        let newBridge = AudioBridge(peerID: peerID, session: session) { [weak self] in
            // Fired when the remote stream ends (peer hung up).
            Task { @MainActor in self?.endCall() }
        }
        bridge = newBridge
        newBridge.setMuted(isMuted)
        newBridge.setSpeaker(isSpeakerOn)
        newBridge.start()
    }

    private func ensureVideoBridge(peer: MCPeerID?, session: MCSession?) {
        guard videoBridge == nil else { return }
        videoBridge = VideoBridge(
            peerID: peer,
            session: session,
            onLocalFrame: { [weak self] frame in
                Task { @MainActor in self?.localFrame = frame }
            },
            onRemoteFrame: { [weak self] frame in
                Task { @MainActor in self?.remoteFrame = frame }
            }
        )
    }
}

/// Runs the realtime audio engine and the MultipeerConnectivity byte streams.
///
/// Runs off the main actor: a dedicated thread hosts the run loop that the input
/// and output `Stream`s are scheduled on, while `AVAudioEngine` captures the mic
/// and plays back received audio. Audio frames are length-prefixed Float32 PCM
/// at a fixed 48 kHz mono format so both ends can reconstruct buffers.
///
/// NOTE: This is a prototype pipeline — it compiles and is architecturally
/// complete, but buffer sizes, the audio-session category, and jitter handling
/// will need tuning on real devices.
nonisolated final class AudioBridge: NSObject, StreamDelegate, @unchecked Sendable {

    /// Name used for the voice audio stream on the `MCSession`.
    static let streamName = "nobars-voice"
    private static let maxFrameBytes: UInt32 = 256 * 1024

    private let peerID: MCPeerID
    private weak var session: MCSession?
    private let onEnded: () -> Void

    // Audio
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let ioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!
    private var converter: AVAudioConverter?

    // Streams (touched only on `thread`, except writes which take `writeLock`)
    private var thread: Thread?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    private var pendingInput: InputStream?
    private var inbound = Data()
    private let writeLock = NSLock()
    private var running = false
    private var muted = false
    private var speaker = true

    // Outbound frame queue (drained on the stream thread, handles partial writes).
    private var outQueue: [Data] = []
    private var partial: Data?
    private var partialOffset = 0
    private let queueLock = NSLock()
    private let maxQueuedFrames = 16

    private let playbackGain: Float = 2.5 // software amplification for loudness
    private var loggedFirstSend = false
    private var loggedFirstPlay = false

    init(peerID: MCPeerID, session: MCSession, onEnded: @escaping () -> Void) {
        self.peerID = peerID
        self.session = session
        self.onEnded = onEnded
        super.init()
    }

    /// Requests microphone permission ahead of the call. The shared audio engine
    /// needs mic access to start — and if it fails to start, playback is dead too.
    static func prewarmMic() {
        #if os(iOS)
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { granted in
                callLog.info("mic prewarm granted=\(granted, privacy: .public)")
            }
        }
        #endif
    }

    func setMuted(_ value: Bool) { muted = value }

    func setSpeaker(_ value: Bool) {
        speaker = value
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(value ? .speaker : .none)
        #endif
    }

    // MARK: Lifecycle

    func start() {
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "MeshVoiceCall"
        thread = t
        running = true
        t.start()
    }

    func stop() {
        running = false
        writeLock.lock()
        outputStream?.close()
        outputStream = nil
        writeLock.unlock()
        inputStream?.close()
        inputStream = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Schedules an incoming stream onto our run-loop thread.
    func attachInputStream(_ stream: InputStream) {
        guard let thread else { return }
        pendingInput = stream
        perform(#selector(scheduleInputOnThread), on: thread, with: nil, waitUntilDone: false)
    }

    // MARK: Thread / run loop

    private func threadMain() {
        configureAudioSession()

        if let session, let output = try? session.startStream(withName: Self.streamName, toPeer: peerID) {
            outputStream = output
            output.delegate = self
            output.schedule(in: .current, forMode: .default)
            output.open()
            callLog.info("audio output stream opened to \(self.peerID.displayName, privacy: .public)")
        } else {
            callLog.error("audio output stream FAILED to open")
        }

        startAudioEngine()

        // Keep the run loop alive so scheduled streams deliver events.
        while running {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        }
    }

    @objc private func scheduleInputOnThread() {
        guard let stream = pendingInput else { return }
        pendingInput = nil
        inputStream = stream
        stream.delegate = self
        stream.schedule(in: .current, forMode: .default)
        stream.open()
    }

    // MARK: Audio engine

    private func configureAudioSession() {
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            // `.voiceChat` reliably produces audio and does echo cancellation; we
            // amplify in software for loudness and force the loudspeaker route.
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                         options: [.allowBluetoothHFP, .defaultToSpeaker])
            try audioSession.setActive(true)
            try audioSession.overrideOutputAudioPort(speaker ? .speaker : .none)
            callLog.info("audio session active (speaker=\(self.speaker, privacy: .public))")
        } catch {
            callLog.error("audio session FAILED: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func startAudioEngine() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: ioFormat)

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: ioFormat)

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.sendCapturedAudio(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
            callLog.info("audio engine started")
        } catch {
            callLog.error("audio engine FAILED to start: \(error.localizedDescription, privacy: .public)")
        }
        player.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
        player.play()
    }

    // MARK: Capture -> network

    private func sendCapturedAudio(_ buffer: AVAudioPCMBuffer) {
        guard !muted, let converter else { return }

        let ratio = ioFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: ioFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var fed = false
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.floatChannelData else { return }

        let sampleCount = Int(out.frameLength)
        let byteCount = sampleCount * MemoryLayout<Float>.size

        // Frame = 4-byte big-endian length + Float32 samples.
        var frame = Data(capacity: byteCount + 4)
        var length = UInt32(byteCount).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        channel[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
            frame.append(bytes, count: byteCount)
        }

        if !loggedFirstSend { loggedFirstSend = true; callLog.info("sending first audio frame") }
        enqueue(frame)
    }

    /// Queues a complete length-prefixed frame and kicks the drain on the stream thread.
    private func enqueue(_ frame: Data) {
        queueLock.lock()
        outQueue.append(frame)
        if outQueue.count > maxQueuedFrames { outQueue.removeFirst(outQueue.count - maxQueuedFrames) }
        queueLock.unlock()
        if let thread { perform(#selector(pumpOutput), on: thread, with: nil, waitUntilDone: false) }
    }

    /// Drains queued frames to the output stream, correctly handling partial
    /// writes (the previous code lost bytes and desynced the receiver's framing).
    @objc private func pumpOutput() {
        guard let out = outputStream else { return }
        while out.hasSpaceAvailable {
            if partial == nil {
                queueLock.lock()
                if !outQueue.isEmpty { partial = outQueue.removeFirst(); partialOffset = 0 }
                queueLock.unlock()
            }
            guard let frame = partial else { break }
            let written = frame.withUnsafeBytes { raw -> Int in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: partialOffset)
                return out.write(base, maxLength: frame.count - partialOffset)
            }
            if written > 0 {
                partialOffset += written
                if partialOffset >= frame.count { partial = nil }
            } else {
                break
            }
        }
    }

    // MARK: Network -> playback

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable:
            pumpOutput()
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let read = input.read(&chunk, maxLength: chunk.count)
            if read > 0 {
                inbound.append(contentsOf: chunk[0..<read])
                drainFrames()
            }
        case .endEncountered, .errorOccurred:
            onEnded()
        default:
            break
        }
    }

    /// Parses as many complete length-prefixed frames as are buffered and
    /// schedules them for playback.
    private func drainFrames() {
        while inbound.count >= 4 {
            let length = inbound.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            // A corrupt header would otherwise make us buffer forever.
            guard length <= Self.maxFrameBytes else { inbound.removeAll(); break }
            let total = 4 + Int(length)
            guard inbound.count >= total else { break }

            let payload = inbound.subdata(in: 4..<total)
            inbound.removeSubrange(0..<total)
            scheduleForPlayback(payload)
        }
    }

    private func scheduleForPlayback(_ data: Data) {
        let sampleCount = data.count / MemoryLayout<Float>.size
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: ioFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)),
              let channel = buffer.floatChannelData else { return }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let dst = channel[0]
            let gain = playbackGain
            for i in 0..<sampleCount {
                var v = base[i] * gain
                if v > 1 { v = 1 } else if v < -1 { v = -1 } // clamp to avoid clipping
                dst[i] = v
            }
        }
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
        if !loggedFirstPlay { loggedFirstPlay = true; callLog.info("playing first received audio (\(sampleCount, privacy: .public) samples)") }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

/// Captures the camera, JPEG-compresses low-resolution frames, and streams them
/// over an `MCSession` byte stream — and decodes incoming frames for display.
///
/// Video is point-to-point (not relayed) and independent of the audio pipeline,
/// so a call can be audio-only, then upgrade to video mid-call. If no `session`
/// is provided (demo mode), it captures + previews locally without networking.
///
/// NOTE: prototype pipeline — JPEG-over-stream at low res/fps. Fine for a demo;
/// front-camera orientation and adaptive bitrate are follow-ups. Needs on-device
/// verification with two phones.
nonisolated final class VideoBridge: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, StreamDelegate, @unchecked Sendable {

    /// Name used for the video stream on the `MCSession`.
    static let streamName = "nobars-video"
    private static let maxFrameBytes: UInt32 = 2 * 1024 * 1024

    private let peerID: MCPeerID?
    private weak var session: MCSession?
    private let onLocalFrame: (CGImage) -> Void
    private let onRemoteFrame: (CGImage) -> Void

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: nil)
    private let videoQueue = DispatchQueue(label: "MeshVideoCapture")
    private var cameraPosition: AVCaptureDevice.Position = .front
    private var videoInput: AVCaptureDeviceInput?
    private var frameCounter = 0

    private var thread: Thread?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    private var pendingInput: InputStream?
    private var inbound = Data()
    private let writeLock = NSLock()
    private var running = false
    private var sending = false

    // Outbound frame queue (drained on the stream thread, handles partial writes).
    private var outQueue: [Data] = []
    private var partial: Data?
    private var partialOffset = 0
    private let queueLock = NSLock()
    private let maxQueuedFrames = 2 // realtime video: only keep the freshest frames

    private var loggedFirstSend = false
    private var loggedFirstReceive = false

    init(peerID: MCPeerID?,
         session: MCSession?,
         onLocalFrame: @escaping (CGImage) -> Void,
         onRemoteFrame: @escaping (CGImage) -> Void) {
        self.peerID = peerID
        self.session = session
        self.onLocalFrame = onLocalFrame
        self.onRemoteFrame = onRemoteFrame
        super.init()
    }

    /// Requests camera permission ahead of time so a two-way video upgrade is
    /// instant (and never blocked mid-call by an unanswered prompt).
    static func prewarmCamera() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                callLog.info("camera prewarm granted=\(granted, privacy: .public)")
            }
        }
    }

    // MARK: Sending (camera capture)

    func startSending() {
        guard !sending else { return }
        sending = true
        callLog.info("VideoBridge.startSending (auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue, privacy: .public))")
        videoQueue.async { [weak self] in self?.configureAndStartCapture() }
        ensureThread()
        if let thread {
            perform(#selector(openOutputOnThread), on: thread, with: nil, waitUntilDone: false)
        }
    }

    func stopSending() {
        sending = false
        videoQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
        }
        writeLock.lock()
        outputStream?.close()
        outputStream = nil
        writeLock.unlock()
    }

    func stop() {
        stopSending()
        running = false
        inputStream?.close()
        inputStream = nil
    }

    func flipCamera() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.cameraPosition = (self.cameraPosition == .front) ? .back : .front
            self.captureSession.beginConfiguration()
            if let input = self.videoInput { self.captureSession.removeInput(input) }
            self.addCameraInput()
            self.captureSession.commitConfiguration()
        }
    }

    private func configureAndStartCapture() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            reallyConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                callLog.info("camera request granted=\(granted, privacy: .public)")
                guard granted, let self else { return }
                self.videoQueue.async { self.reallyConfigure() }
            }
        default:
            callLog.error("camera DENIED — this phone won't send video (enable in Settings)")
        }
    }

    private func reallyConfigure() {
        captureSession.beginConfiguration()
        // Modest capture resolution — JPEG-per-frame over the mesh must stay small
        // to be smooth. (High-res is what made it laggy.)
        if captureSession.canSetSessionPreset(.vga640x480) {
            captureSession.sessionPreset = .vga640x480
        } else {
            captureSession.sessionPreset = .medium
        }
        addCameraInput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if captureSession.canAddOutput(videoOutput) { captureSession.addOutput(videoOutput) }
        captureSession.commitConfiguration()
        captureSession.startRunning()
        callLog.info("camera running, preset=\(self.captureSession.sessionPreset.rawValue, privacy: .public)")
    }

    private func addCameraInput() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else { return }
        captureSession.addInput(input)
        videoInput = input
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter &+= 1
        if frameCounter % 3 != 0 { return } // ~10 fps — smooth over the mesh

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Rotate the landscape sensor buffer to portrait (mirror the front camera).
        let oriented = ciImage.oriented(cameraPosition == .front ? .leftMirrored : .right)

        // Downscale ONCE, then reuse the small image for both the local preview
        // and transmission — half the Core Image work per frame (less lag).
        let targetWidth: CGFloat = 400
        let small: CIImage
        if oriented.extent.width > targetWidth {
            let scale = targetWidth / oriented.extent.width
            small = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            small = oriented
        }

        if let cg = ciContext.createCGImage(small, from: small.extent) {
            onLocalFrame(cg)
        }

        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.4
        ]
        guard let jpeg = ciContext.jpegRepresentation(of: small,
                                                      colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: options) else { return }

        var frame = Data(capacity: jpeg.count + 4)
        var length = UInt32(jpeg.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(jpeg)
        if !loggedFirstSend { loggedFirstSend = true; callLog.info("sending first video frame (\(jpeg.count, privacy: .public) bytes)") }
        enqueue(frame)
    }

    /// Queues a complete length-prefixed frame and kicks the drain on the stream thread.
    private func enqueue(_ frame: Data) {
        queueLock.lock()
        outQueue.append(frame)
        if outQueue.count > maxQueuedFrames { outQueue.removeFirst(outQueue.count - maxQueuedFrames) }
        queueLock.unlock()
        if let thread { perform(#selector(pumpOutput), on: thread, with: nil, waitUntilDone: false) }
    }

    /// Drains queued frames to the output stream, correctly handling partial writes.
    @objc private func pumpOutput() {
        guard let out = outputStream else { return }
        while out.hasSpaceAvailable {
            if partial == nil {
                queueLock.lock()
                if !outQueue.isEmpty { partial = outQueue.removeFirst(); partialOffset = 0 }
                queueLock.unlock()
            }
            guard let frame = partial else { break }
            let written = frame.withUnsafeBytes { raw -> Int in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: partialOffset)
                return out.write(base, maxLength: frame.count - partialOffset)
            }
            if written > 0 {
                partialOffset += written
                if partialOffset >= frame.count { partial = nil }
            } else {
                break
            }
        }
    }

    // MARK: Receiving

    func attachInputStream(_ stream: InputStream) {
        ensureThread()
        pendingInput = stream
        if let thread {
            perform(#selector(scheduleInputOnThread), on: thread, with: nil, waitUntilDone: false)
        }
    }

    private func ensureThread() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "MeshVideoStreams"
        thread = t
        running = true
        t.start()
    }

    private func threadMain() {
        while running {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
        }
    }

    @objc private func openOutputOnThread() {
        guard outputStream == nil, let session, let peerID else { return }
        guard let out = try? session.startStream(withName: Self.streamName, toPeer: peerID) else {
            callLog.error("FAILED to open video output stream to \(peerID.displayName, privacy: .public)")
            return
        }
        callLog.info("video output stream opened to \(peerID.displayName, privacy: .public)")
        outputStream = out
        out.delegate = self
        out.schedule(in: .current, forMode: .default)
        out.open()
    }

    @objc private func scheduleInputOnThread() {
        guard let stream = pendingInput else { return }
        pendingInput = nil
        inputStream = stream
        stream.delegate = self
        stream.schedule(in: .current, forMode: .default)
        stream.open()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasSpaceAvailable:
            pumpOutput()
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let read = input.read(&chunk, maxLength: chunk.count)
            if read > 0 {
                inbound.append(contentsOf: chunk[0..<read])
                drainFrames()
            }
        default:
            break
        }
    }

    private func drainFrames() {
        while inbound.count >= 4 {
            let length = inbound.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            // A corrupt header would otherwise make us buffer forever.
            guard length <= Self.maxFrameBytes else { inbound.removeAll(); break }
            let total = 4 + Int(length)
            guard inbound.count >= total else { break }

            let payload = inbound.subdata(in: 4..<total)
            inbound.removeSubrange(0..<total)
            if !loggedFirstReceive { loggedFirstReceive = true; callLog.info("received first video frame (\(payload.count, privacy: .public) bytes)") }
            if let ci = CIImage(data: payload), let cg = ciContext.createCGImage(ci, from: ci.extent) {
                onRemoteFrame(cg)
            }
        }
    }
}
