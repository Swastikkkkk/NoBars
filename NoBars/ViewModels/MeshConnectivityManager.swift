import Foundation
import Observation
@preconcurrency import MultipeerConnectivity
import CoreLocation
import UIKit
import ActivityKit
import AVFoundation
import WidgetKit
import os
import CryptoKit

@MainActor
@Observable
final class MeshConnectivityManager: NSObject {

    /// One mesh per app process. Views, App Intents and URL actions all share it.
    static let shared = MeshConnectivityManager()

    // MARK: State

    private(set) var connectedPeers: [String] = []
    private(set) var receivedMessages: [MeshMessage] = []
    private(set) var buddyLocations: [String: BuddyLocation] = [:]
    private(set) var isHosting = false
    private(set) var isBrowsing = false
    var isLive: Bool { isHosting || isBrowsing }
    private(set) var emergencyBuddies: Set<String> = []
    private(set) var isPanicBroadcasting = false
    private(set) var deviceHeading: Double = 0
    private(set) var headingActive = false
    var myCoordinate: CLLocationCoordinate2D? { lastKnownCoordinate }

    let voice = MeshVoiceCallManager()
    @ObservationIgnored private let liveActivity = LiveActivityController()

    private(set) var statusLog: [String] = []
    private(set) var toast: String?
    private(set) var meshStartError: String?
    private(set) var myName: String
    private(set) var groupCode: String
    /// Short fingerprint of this phone's signing key, shown in Settings so
    /// buddies can compare it in person.
    var myFingerprint: String { MeshCrypto.fingerprint(signingKey.publicKey.rawRepresentation) }

    // MARK: MPC internals

    private static let serviceType = "nobars-mesh"
    static let nameKey = "nobars.displayName"
    static let groupKey = "nobars.groupCode"
    private static let pinsKeyPrefix = "nobars.pins."
    /// Seconds a new link gets to complete the encrypted hello before it's dropped.
    private static let helloTimeout: Double = 10

    private var myPeerID: MCPeerID
    private var session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser
    private var browser: MCNearbyServiceBrowser
    private let myToken: String
    @ObservationIgnored private var groupKeys: GroupKeys
    @ObservationIgnored private let signingKey = MeshIdentity.loadOrCreate()
    @ObservationIgnored private var pins = KeyPins()
    /// Linked over MultipeerConnectivity but not yet proven to hold the group key.
    @ObservationIgnored private var unverifiedPeers: [String: MCPeerID] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    @ObservationIgnored private var router = MeshRouter()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.swastik.nobars", category: "mesh")
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var lastKnownCoordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var panicTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var outbox: [ChatArchive.Queued] = []
    @ObservationIgnored private var peerIDsByName: [String: MCPeerID] = [:]
    @ObservationIgnored private var compassActive = false
    @ObservationIgnored private var compassBroadcastTask: Task<Void, Never>?

    // MARK: Init

    override init() {
        let token = UUID().uuidString
        let name = UserDefaults.standard.string(forKey: Self.nameKey).flatMap { $0.isEmpty ? nil : $0 } ?? UIDevice.current.name
        let group = UserDefaults.standard.string(forKey: Self.groupKey) ?? ""
        let peerID = MCPeerID(displayName: name)
        let keys = GroupKeys(code: group)
        self.myName = name
        self.groupCode = group
        self.groupKeys = keys
        self.myToken = token
        self.myPeerID = peerID
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        // Only the one-way tag is advertised. The group code never leaves the phone.
        self.advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["token": token, "g": keys.discoveryTag],
            serviceType: Self.serviceType
        )
        self.browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
        voice.attach(session: session)
        loadGroupState()
    }

    // MARK: Persistence

    /// Loads this group's chat history, unsent messages and trusted keys.
    private func loadGroupState() {
        let archive = ChatStore.load(tag: groupKeys.discoveryTag)
        receivedMessages = archive.messages
        outbox = archive.outbox
        if let data = UserDefaults.standard.data(forKey: Self.pinsKeyPrefix + groupKeys.discoveryTag),
           let saved = try? JSONDecoder().decode(KeyPins.self, from: data) {
            pins = saved
        } else {
            pins = KeyPins()
        }
    }

    private func saveChatSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.saveChatNow()
        }
    }

    private func saveChatNow() {
        ChatStore.save(ChatArchive(messages: receivedMessages, outbox: outbox), tag: groupKeys.discoveryTag)
    }

    private func savePins() {
        if let data = try? JSONEncoder().encode(pins) {
            UserDefaults.standard.set(data, forKey: Self.pinsKeyPrefix + groupKeys.discoveryTag)
        }
    }

    private func appendMessage(_ message: MeshMessage) {
        receivedMessages.append(message)
        saveChatSoon()
    }

    func clearChatHistory() {
        receivedMessages.removeAll()
        outbox.removeAll()
        ChatStore.delete(tag: groupKeys.discoveryTag)
        flashToast("Chat history cleared")
    }

    /// Forgets every pinned buddy key, e.g. after a friend reinstalls the app.
    func resetTrustedBuddies() {
        pins.removeAll()
        savePins()
        flashToast("Trusted buddies reset")
    }

    func note(_ message: String) {
        log.notice("\(message, privacy: .public)")
        statusLog.append(message)
        if statusLog.count > 40 { statusLog.removeFirst(statusLog.count - 40) }
    }

    // MARK: Utilities

    static func haptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func flashToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.toast = nil
        }
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    var isLocationDenied: Bool {
        locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted
    }

    private var isLocationAuthorized: Bool {
        let s = locationManager.authorizationStatus
        return s == .authorizedWhenInUse || s == .authorizedAlways
    }

    private func syncLiveActivity() {
        let nearest = nearestBuddyWithDistance()
        liveActivity.update(
            connectedPeers: connectedPeers,
            group: groupCode,
            sharingLocation: isPanicBroadcasting,
            nearestPeer: nearest
        )
    }

    private func nearestBuddyWithDistance() -> (name: String, distance: Double)? {
        guard let myLoc = lastKnownCoordinate else { return nil }
        let myLocation = CLLocation(latitude: myLoc.latitude, longitude: myLoc.longitude)
        return buddyLocations
            .compactMap { name, buddy -> (String, Double)? in
                guard name != myName else { return nil }
                let buddyLoc = CLLocation(latitude: buddy.coordinate.latitude, longitude: buddy.coordinate.longitude)
                return (name, myLocation.distance(from: buddyLoc))
            }
            .min(by: { $0.1 < $1.1 })
    }

    func testLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            flashToast("Live Activities disabled — go to Settings \u{2192} NoBars \u{2192} Live Activities")
            return
        }
        syncLiveActivity()
        flashToast("Lock your phone — banner appears at the bottom of the lock screen")
    }

    // MARK: Identity

    func configure(name: String? = nil, group: String? = nil) {
        let newName = (name ?? myName).trimmingCharacters(in: .whitespacesAndNewlines)
        let newGroup = (group ?? groupCode).trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = !newName.isEmpty && newName != myName
        let groupChanged = newGroup != groupCode
        guard nameChanged || groupChanged else { return }
        if nameChanged { myName = newName; UserDefaults.standard.set(newName, forKey: Self.nameKey) }
        if groupChanged {
            saveTask?.cancel(); saveChatNow()
            groupCode = newGroup
            UserDefaults.standard.set(newGroup, forKey: Self.groupKey)
            groupKeys = GroupKeys(code: newGroup)
            loadGroupState()
        }
        rebuildNetworking()
        note("Identity: \(myName) \u{00B7} group \u{201C}\(groupCode)\u{201D}")
    }

    func joinMesh(name: String, group: String) {
        configure(name: name, group: group)
        startHosting()
        startBrowsing()
    }

    func leaveMesh() {
        stopPanicMode()
        stopHosting()
        stopBrowsing()
        session.disconnect()
        reconnectTask?.cancel()
        connectedPeers.removeAll()
        peerIDsByName.removeAll()
        unverifiedPeers.removeAll()
        emergencyBuddies.removeAll()
        publishWidgetState()
        liveActivity.end()
    }

    private func rebuildNetworking() {
        let wasHosting = isHosting; let wasBrowsing = isBrowsing
        stopHosting(); stopBrowsing(); session.disconnect()
        myPeerID = MCPeerID(displayName: myName)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: ["token": myToken, "g": groupKeys.discoveryTag], serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.serviceType)
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
        voice.attach(session: session)
        connectedPeers.removeAll(); peerIDsByName.removeAll(); unverifiedPeers.removeAll()
        buddyLocations.removeValue(forKey: myName)
        if wasHosting { startHosting() }
        if wasBrowsing { startBrowsing() }
    }

    // MARK: Start / stop

    func startHosting() {
        guard !isHosting else { return }
        meshStartError = nil
        advertiser.startAdvertisingPeer()
        isHosting = true
        note("Hosting started as \(myName)")
    }

    func stopHosting() {
        guard isHosting else { return }
        advertiser.stopAdvertisingPeer()
        isHosting = false
    }

    func startBrowsing() {
        guard !isBrowsing else { return }
        browser.startBrowsingForPeers()
        isBrowsing = true
        note("Browsing for buddies…")
    }

    func stopBrowsing() {
        guard isBrowsing else { return }
        browser.stopBrowsingForPeers()
        isBrowsing = false
    }

    // MARK: Messaging

    func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var packet = MeshRelayPacket(kind: .message, senderName: myName, text: trimmed)
        MeshCrypto.sign(&packet, with: signingKey)
        router.markOwn(packet)
        let queued = connectedPeers.isEmpty
        var message = MeshMessage(sender: myName, text: trimmed, date: packet.timestamp)
        message.pending = queued
        if queued { outbox.append(.init(packet: packet, messageID: message.id)) }
        appendMessage(message)
        if queued {
            flashToast("Queued — sends when a buddy connects")
        } else {
            broadcast(packet, excluding: nil)
        }
    }

    private func flushOutbox() {
        guard !outbox.isEmpty else { return }
        for item in outbox {
            broadcast(item.packet, excluding: nil)
            if let i = receivedMessages.firstIndex(where: { $0.id == item.messageID }) {
                receivedMessages[i].pending = false
            }
        }
        note("Delivered \(outbox.count) queued message(s)")
        outbox.removeAll()
        saveChatSoon()
    }

    // MARK: Location & panic

    /// Floods our position. The SOS flag always reflects panic mode, so a compass
    /// or timer broadcast can never silently clear an active emergency.
    private func broadcastMyLocation(_ coordinate: CLLocationCoordinate2D) {
        lastKnownCoordinate = coordinate
        var packet = MeshRelayPacket(kind: .location, senderName: myName,
                                     latitude: coordinate.latitude, longitude: coordinate.longitude,
                                     isEmergency: isPanicBroadcasting)
        MeshCrypto.sign(&packet, with: signingKey)
        router.markOwn(packet)
        buddyLocations[myName] = BuddyLocation(name: myName, coordinate: coordinate, date: packet.timestamp)
        broadcast(packet, excluding: nil)
    }

    func togglePanic() { isPanicBroadcasting ? stopPanicMode() : startPanicMode() }

    func startPanicMode() {
        guard !isPanicBroadcasting else { return }
        if isLocationDenied { flashToast("Turn on Location in Settings to share"); return }
        isPanicBroadcasting = true
        note("SOS started")
        flashToast("Sharing your live location")
        syncLiveActivity()
        locationManager.requestAlwaysAuthorization()
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        if isLocationAuthorized {
            locationManager.startUpdatingLocation()
            if let coord = lastKnownCoordinate { broadcastMyLocation(coord) }
        } else if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        panicTask?.cancel()
        panicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.isPanicBroadcasting else { return }
                if let coord = self.lastKnownCoordinate { self.broadcastMyLocation(coord) }
            }
        }
    }

    func stopPanicMode() {
        guard isPanicBroadcasting else { return }
        isPanicBroadcasting = false
        note("SOS stopped")
        // One last packet without the SOS flag so buddies see the all-clear.
        if let coord = lastKnownCoordinate { broadcastMyLocation(coord) }
        flashToast("Stopped sharing location")
        syncLiveActivity()
        panicTask?.cancel(); panicTask = nil
        if !compassActive { locationManager.stopUpdatingLocation() }
        locationManager.allowsBackgroundLocationUpdates = false
    }

    // MARK: Compass

    func startCompass() {
        compassActive = true
        if isLocationAuthorized {
            locationManager.startUpdatingLocation()
            if let coord = lastKnownCoordinate { broadcastMyLocation(coord) }
        } else if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if CLLocationManager.headingAvailable() { locationManager.startUpdatingHeading() }
        compassBroadcastTask?.cancel()
        compassBroadcastTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.compassActive else { return }
                if let coord = self.lastKnownCoordinate { self.broadcastMyLocation(coord) }
            }
        }
    }

    func stopCompass() {
        compassActive = false
        compassBroadcastTask?.cancel()
        compassBroadcastTask = nil
        locationManager.stopUpdatingHeading()
        headingActive = false
        if !isPanicBroadcasting { locationManager.stopUpdatingLocation() }
    }

    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180, lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: Calls

    /// Calls run point-to-point over a direct link, so the buddy must be in range.
    func startCall(with peerName: String, video: Bool = false) {
        guard let peerID = peerIDsByName[peerName] else {
            flashToast("\(peerName) isn't directly connected")
            return
        }
        Task {
            if AVAudioApplication.shared.recordPermission == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
            }
            guard AVAudioApplication.shared.recordPermission == .granted else {
                flashToast("Allow Microphone in Settings to call")
                return
            }
            voice.startCall(to: peerID, session: session)
            if video { voice.enableVideo() }
        }
    }

    func endCall() { voice.endCall() }

    // MARK: Relay

    /// Seals and sends to every verified neighbour except `excluding`.
    private func broadcast(_ packet: MeshRelayPacket, excluding: MCPeerID?) {
        let targets = peerIDsByName.values.filter { $0 != excluding }
        guard !targets.isEmpty, let data = MeshCrypto.seal(packet, with: groupKeys.key) else { return }
        try? session.send(data, toPeers: Array(targets), with: .reliable)
    }

    /// Sent straight to a new neighbour. Only a phone holding the group key can
    /// open it, and the signature pins our key to our name on their side.
    private func sendHello(to peerID: MCPeerID) {
        var hello = MeshRelayPacket(kind: .hello, senderName: myName, ttl: 1)
        MeshCrypto.sign(&hello, with: signingKey)
        guard let data = MeshCrypto.seal(hello, with: groupKeys.key) else { return }
        try? session.send(data, toPeers: [peerID], with: .reliable)
    }

    private func handleIncoming(data: Data, from peerID: MCPeerID) {
        let name = peerID.displayName
        guard let packet = MeshCrypto.open(data, with: groupKeys.key) else {
            note("Dropped unreadable packet from \(name) (wrong group key)")
            if unverifiedPeers[name] != nil { reject(peerID, reason: "can't prove the group code") }
            return
        }
        guard MeshCrypto.verify(packet), let key = packet.senderKey else {
            note("Dropped unsigned packet from \(name)")
            return
        }
        if packet.kind != .message, abs(packet.timestamp.timeIntervalSinceNow) > MeshCrypto.maxPositionAge {
            note("Dropped stale \(packet.kind.rawValue) packet from \(packet.senderName)")
            return
        }
        if packet.kind == .hello, packet.senderName != name {
            reject(peerID, reason: "hello name doesn't match")
            return
        }
        if packet.senderName == myName {
            guard key == signingKey.publicKey.rawRepresentation else {
                note("Rejected packet using my name with another key")
                return
            }
        } else {
            switch pins.check(name: packet.senderName, key: key) {
            case .new:
                savePins()
                note("Trusted \(packet.senderName) (key \(MeshCrypto.fingerprint(key)))")
            case .match:
                break
            case .mismatch:
                note("Rejected packet claiming to be \(packet.senderName): key doesn't match")
                flashToast("Someone tried to send as \(packet.senderName). Ignored.")
                if packet.kind == .hello { reject(peerID, reason: "identity doesn't match") }
                return
            }
        }
        if packet.kind == .hello {
            verify(peerID)
            return
        }
        // Everything else must come over a verified link.
        guard peerIDsByName[name] == peerID else { return }
        handleIncoming(packet, from: peerID)
    }

    private func reject(_ peerID: MCPeerID, reason: String) {
        unverifiedPeers.removeValue(forKey: peerID.displayName)
        note("Dropped link to \(peerID.displayName): \(reason)")
        session.cancelConnectPeer(peerID)
    }

    private func handleIncoming(_ packet: MeshRelayPacket, from peerID: MCPeerID) {
        guard case .deliver(let forward) = router.receive(packet) else { return }
        switch packet.kind {
        case .hello:
            return
        case .message:
            if let text = packet.text {
                note("Message from \(packet.senderName) via \(peerID.displayName): \(text)")
                appendMessage(MeshMessage(sender: packet.senderName, text: text, date: packet.timestamp))
            }
        case .location:
            if let lat = packet.latitude, let lng = packet.longitude {
                buddyLocations[packet.senderName] = BuddyLocation(
                    name: packet.senderName,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    date: packet.timestamp
                )
                let wasEmergency = emergencyBuddies.contains(packet.senderName)
                if packet.isEmergency == true {
                    emergencyBuddies.insert(packet.senderName)
                    if !wasEmergency {
                        flashToast("SOS from \(packet.senderName)")
                        note("SOS from \(packet.senderName)")
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                } else {
                    emergencyBuddies.remove(packet.senderName)
                }
                SharedStore.saveBuddies(buddyLocations.values.map {
                    SharedStore.BuddySnapshot(name: $0.name, lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, date: $0.date)
                })
                if wasEmergency != emergencyBuddies.contains(packet.senderName) { publishWidgetState() }
            }
        }
        if let forward { broadcast(forward, excluding: peerID) }
    }

    // MARK: Widgets, permissions, deep links

    private func publishWidgetState() {
        SharedStore.saveConnectedPeers(connectedPeers)
        SharedStore.saveEmergencies(Array(emergencyBuddies))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Asks for everything up front so the first call or SOS is never blocked
    /// by a prompt the other person can't see.
    func requestPermissions() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { _ in }
        }
    }

    /// `nobars://sos` starts panic mode (used by the Control Center
    /// button and the SOS shortcut). `nobars://open` just opens the app.
    func handle(url: URL) {
        guard url.scheme == "nobars" else { return }
        if !isLive { startHosting(); startBrowsing() }
        if url.host == "sos" { startPanicMode() }
    }

    /// MultipeerConnectivity won't report a peer again while it's still in
    /// range, so after a drop we restart browsing to pick it back up.
    private func scheduleRediscovery() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isBrowsing else { return }
            self.browser.stopBrowsingForPeers()
            self.browser.startBrowsingForPeers()
            self.note("Re-scanning for buddies")
        }
    }

    /// Promotes a linked phone to a buddy once its hello checks out.
    private func verify(_ peerID: MCPeerID) {
        let name = peerID.displayName
        unverifiedPeers.removeValue(forKey: name)
        guard peerIDsByName[name] != peerID else { return }
        let isNew = !connectedPeers.contains(name)
        peerIDsByName[name] = peerID
        if isNew {
            connectedPeers.append(name)
            appendMessage(MeshMessage(sender: "", text: "\(name) joined the mesh", date: Date(), isSystem: true))
            flashToast("\(name) joined the mesh")
            Self.haptic()
            publishWidgetState()
        }
        flushOutbox()
        startTestSenderIfNeeded()
        note("Connected: \(name)")
        syncLiveActivity()
    }
}

// MARK: - CI hooks (Debug builds only)
//
// Used by Tests/sim-mesh-test.sh to drive several simulators without touching
// the UI. `-meshTestOnly Bob,Carol` limits who this phone links to (forcing a
// chain so multi-hop is really exercised), `-meshTestSend text` sends a few
// chat messages once connected. Release builds ignore both.

extension MeshConnectivityManager {
    private static var testSending = false

    fileprivate func testAllows(_ name: String) -> Bool {
        #if DEBUG
        if let only = UserDefaults.standard.string(forKey: "meshTestOnly") {
            return only.split(separator: ",").map(String.init).contains(name)
        }
        #endif
        return true
    }

    fileprivate func startTestSenderIfNeeded() {
        #if DEBUG
        guard !Self.testSending else { return }
        Self.testSending = true
        let text = UserDefaults.standard.string(forKey: "meshTestSend")
        let script = UserDefaults.standard.string(forKey: "meshTestScript")
        let sos = UserDefaults.standard.bool(forKey: "meshTestSOS")
        Task { [weak self] in
            if let text {
                for i in 1...6 {
                    try? await Task.sleep(for: .seconds(8))
                    self?.sendMessage("\(text) \(i)")
                }
            }
            if let script {
                let delay = UserDefaults.standard.double(forKey: "meshTestScriptDelay")
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                for line in script.split(separator: "|") {
                    try? await Task.sleep(for: .seconds(6))
                    self?.sendMessage(String(line))
                }
            }
            if sos {
                try? await Task.sleep(for: .seconds(5))
                self?.startPanicMode()
            }
        }
        #endif
    }
}

// MARK: - MCSessionDelegate

extension MeshConnectivityManager: MCSessionDelegate {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                self.meshStartError = nil
                // Not a buddy yet: both sides first swap an encrypted, signed hello.
                self.sendHello(to: peerID)
                // Their hello can land before this callback runs.
                guard self.peerIDsByName[peerID.displayName] != peerID else { return }
                self.unverifiedPeers[peerID.displayName] = peerID
                self.note("Linked to \(peerID.displayName), checking group key")
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.helloTimeout))
                    guard let self, self.unverifiedPeers[peerID.displayName] == peerID else { return }
                    self.reject(peerID, reason: "no hello")
                }
            case .notConnected:
                let wasConnected = self.connectedPeers.contains(peerID.displayName)
                self.unverifiedPeers.removeValue(forKey: peerID.displayName)
                self.peerIDsByName.removeValue(forKey: peerID.displayName)
                self.connectedPeers.removeAll { $0 == peerID.displayName }
                if wasConnected { self.appendMessage(MeshMessage(sender: "", text: "\(peerID.displayName) left the mesh", date: Date(), isSystem: true)) }
                self.note("Disconnected: \(peerID.displayName)")
                if self.voice.activePeer == peerID.displayName { self.voice.endCall() }
                self.publishWidgetState()
                self.syncLiveActivity()
                self.scheduleRediscovery()
            case .connecting:
                self.note("Connecting to \(peerID.displayName)…")
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.handleIncoming(data: data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // The stream is handed straight to the call thread and never touched here again.
        nonisolated(unsafe) let stream = stream
        Task { @MainActor in
            // Calls only from buddies who passed the hello check.
            guard self.peerIDsByName[peerID.displayName] == peerID else { stream.close(); return }
            self.voice.handleIncomingStream(stream, name: streamName, from: peerID, session: session)
        }
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshConnectivityManager: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let theirTag = context.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor in
            guard self.testAllows(peerID.displayName) else { invitationHandler(false, nil); return }
            guard theirTag == self.groupKeys.discoveryTag else {
                self.note("Invitation from \(peerID.displayName) ignored (different group)")
                invitationHandler(false, nil)
                return
            }
            self.note("Invitation from \(peerID.displayName) → accepting")
            invitationHandler(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.note("Advertise failed: \(msg)")
            self.meshStartError = "Local Network access is off. Enable it in Settings so nearby phones can find you."
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshConnectivityManager: MCNearbyServiceBrowserDelegate {

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let theirToken = info?["token"]; let theirTag = info?["g"] ?? ""
        Task { @MainActor in
            guard theirTag == self.groupKeys.discoveryTag, self.testAllows(peerID.displayName) else { return }
            self.note("Found \(peerID.displayName)")
            if let theirToken, self.myToken >= theirToken {
                self.note("Waiting for \(peerID.displayName) to invite (tie-break)")
                return
            }
            self.note("Inviting \(peerID.displayName)…")
            browser.invitePeer(peerID, to: self.session, withContext: Data(self.groupKeys.discoveryTag.utf8), timeout: 30)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.note("Lost \(peerID.displayName)") }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in
            self.note("Browse failed: \(msg)")
            self.meshStartError = "Local Network access is off. Enable it in Settings so nearby phones can find you."
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension MeshConnectivityManager: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isLocationAuthorized else { return }
            if self.isPanicBroadcasting || self.compassActive {
                self.locationManager.startUpdatingLocation()
            }
            if self.compassActive && CLLocationManager.headingAvailable() {
                self.locationManager.startUpdatingHeading()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.lastKnownCoordinate = location.coordinate
            if self.isPanicBroadcasting {
                self.broadcastMyLocation(location.coordinate)
            } else if self.compassActive {
                self.broadcastMyLocation(location.coordinate)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.deviceHeading = value
            self.headingActive = true
        }
    }
}
