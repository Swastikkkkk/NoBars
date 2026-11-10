import Foundation
@preconcurrency import CoreBluetooth
import os

/// Bluetooth LE links, alongside MultipeerConnectivity.
///
/// Two reasons it exists:
/// - CoreBluetooth keeps running when the app is in the background or the
///   phone is locked, so chat and SOS keep relaying when MultipeerConnectivity
///   has been suspended.
/// - Android phones speak it too, so they can join the same mesh.
///
/// Every phone is both a peripheral (advertises the NoBars service) and a
/// central (scans and connects). A link is identified by the other side's
/// CoreBluetooth identifier. The transport only moves opaque sealed packets;
/// group checks, hello and routing live in `MeshConnectivityManager`.
/// Wire details are in protocol/PROTOCOL.md.
@MainActor
final class MeshBLETransport: NSObject {

    static let serviceUUID = CBUUID(string: "6E6F6261-7273-4D65-7368-000000000001")
    /// Read: JSON `{"v":1,"g":<discovery tag>,"t":<token>}`.
    static let infoUUID = CBUUID(string: "6E6F6261-7273-4D65-7368-000000000002")
    /// Write without response: frames from a central to this peripheral.
    static let rxUUID = CBUUID(string: "6E6F6261-7273-4D65-7368-000000000003")
    /// Notify: frames from this peripheral to subscribed centrals.
    static let txUUID = CBUUID(string: "6E6F6261-7273-4D65-7368-000000000004")

    // Callbacks into the mesh manager.
    var info: () -> Data = { Data() }
    /// Decides whether to keep a link after reading the other side's info.
    var shouldLink: (_ tag: String, _ token: String) -> Bool = { _, _ in false }
    var onLinkUp: (UUID) -> Void = { _ in }
    var onLinkDown: (UUID) -> Void = { _ in }
    var onData: (Data, UUID) -> Void = { _, _ in }
    var onNote: (String) -> Void = { _ in }

    private(set) var isRunning = false
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var serviceAdded = false

    // Central role: peripherals we connected to.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var rxOf: [UUID: CBCharacteristic] = [:]
    private var infoOK: Set<UUID> = []
    private var notifying: Set<UUID> = []
    private var cooldown: [UUID: Date] = [:]

    // Peripheral role: centrals subscribed to us.
    private var centrals: [UUID: CBCentral] = [:]

    // Shared per link.
    private var up: Set<UUID> = []
    private var reassemblers: [UUID: BLEFraming.Reassembler] = [:]
    private var outQueues: [UUID: [Data]] = [:]
    /// Messages that arrived before the link finished setting up (e.g. their
    /// hello landing before we read their info). Delivered on link up.
    private var early: [UUID: [Data]] = [:]
    private var nextSeq: UInt32 = 1
    private let log = Logger(subsystem: "com.swastik.nobars", category: "ble")

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionRestoreIdentifierKey: "nobars.central"])
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main,
                                                    options: [CBPeripheralManagerOptionRestoreIdentifierKey: "nobars.peripheral"])
        } else {
            startScanning()
            startAdvertising()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        central?.stopScan()
        peripheralManager?.stopAdvertising()
        for p in peripherals.values { central?.cancelPeripheralConnection(p) }
        for id in up { onLinkDown(id) }
        peripherals.removeAll(); rxOf.removeAll(); infoOK.removeAll(); notifying.removeAll()
        centrals.removeAll(); up.removeAll(); reassemblers.removeAll(); outQueues.removeAll(); early.removeAll()
    }

    /// Call when the group changes so peers re-read our info.
    func restart() {
        let was = isRunning
        stop()
        if was { start() }
    }

    func disconnect(_ link: UUID) {
        if let p = peripherals[link] {
            cooldown[link] = Date().addingTimeInterval(30)
            central?.cancelPeripheralConnection(p)
        }
        // A central can't be kicked from the peripheral side; just stop talking to it.
        if centrals[link] != nil { linkDown(link) ; centrals[link] = nil }
    }

    // MARK: Sending

    func send(_ data: Data, to link: UUID) {
        guard up.contains(link) else { return }
        let maxFrame: Int
        if let p = peripherals[link] {
            maxFrame = p.maximumWriteValueLength(for: .withoutResponse)
        } else if let c = centrals[link] {
            maxFrame = c.maximumUpdateValueLength
        } else { return }
        let frames = BLEFraming.split(data, seq: nextSeq, maxFrame: max(20, maxFrame))
        nextSeq &+= 1
        guard !frames.isEmpty else { return }
        // Bluetooth is slow: cap the backlog so a busy link doesn't fall minutes behind.
        var q = outQueues[link, default: []]
        if q.count > 400 { q.removeFirst(q.count - 400) }
        outQueues[link] = q + frames
        pump(link)
    }

    private func pump(_ link: UUID) {
        guard var q = outQueues[link], !q.isEmpty else { return }
        if let p = peripherals[link], let rx = rxOf[link] {
            while let frame = q.first, p.canSendWriteWithoutResponse {
                p.writeValue(frame, for: rx, type: .withoutResponse)
                q.removeFirst()
            }
        } else if let c = centrals[link], let tx = txCharacteristic, let pm = peripheralManager {
            while let frame = q.first {
                guard pm.updateValue(frame, for: tx, onSubscribedCentrals: [c]) else { break }
                q.removeFirst()
            }
        }
        outQueues[link] = q
    }

    // MARK: Links

    private func linkUp(_ id: UUID) {
        guard !up.contains(id) else { return }
        up.insert(id)
        onLinkUp(id)
        for m in early.removeValue(forKey: id) ?? [] { onData(m, id) }
    }

    private func linkDown(_ id: UUID) {
        reassemblers[id] = nil
        outQueues[id] = nil
        early[id] = nil
        guard up.remove(id) != nil else { return }
        onLinkDown(id)
    }

    private func received(_ frame: Data, from id: UUID) {
        var r = reassemblers[id] ?? BLEFraming.Reassembler()
        let message = r.accept(frame)
        reassemblers[id] = r
        guard let message else { return }
        if up.contains(id) {
            onData(message, id)
        } else if early[id, default: []].count < 8 {
            early[id, default: []].append(message)
        }
    }

    private func startScanning() {
        guard isRunning, central?.state == .poweredOn else { return }
        central?.scanForPeripherals(withServices: [Self.serviceUUID],
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func startAdvertising() {
        guard isRunning, let pm = peripheralManager, pm.state == .poweredOn else { return }
        if !serviceAdded {
            let infoChar = CBMutableCharacteristic(type: Self.infoUUID, properties: [.read], value: nil, permissions: [.readable])
            let rx = CBMutableCharacteristic(type: Self.rxUUID, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
            let tx = CBMutableCharacteristic(type: Self.txUUID, properties: [.notify], value: nil, permissions: [.readable])
            let service = CBMutableService(type: Self.serviceUUID, primary: true)
            service.characteristics = [infoChar, rx, tx]
            txCharacteristic = tx
            pm.add(service)
            serviceAdded = true
            return // advertising starts in didAdd
        }
        if !pm.isAdvertising {
            pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]])
        }
    }
}

// MARK: - Central role

extension MeshBLETransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            onNote("Bluetooth (scan): \(central.state == .poweredOn ? "on" : "off")")
            if central.state == .poweredOn { startScanning() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated {
            for p in restored { p.delegate = self; peripherals[p.identifier] = p }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard isRunning, peripherals[id] == nil, centrals[id] == nil else { return }
            if let until = cooldown[id], until > Date() { return }
            peripherals[id] = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { peripheral.discoverServices([Self.serviceUUID]) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { forget(peripheral.identifier) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            forget(peripheral.identifier)
            // Scanning without duplicates reports each phone once; restart so it can be found again.
            central.stopScan(); startScanning()
        }
    }

    private func forget(_ id: UUID) {
        peripherals[id] = nil; rxOf[id] = nil; infoOK.remove(id); notifying.remove(id)
        linkDown(id)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                central?.cancelPeripheralConnection(peripheral); return
            }
            peripheral.discoverCharacteristics([Self.infoUUID, Self.rxUUID, Self.txUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let chars = service.characteristics ?? []
            guard let info = chars.first(where: { $0.uuid == Self.infoUUID }),
                  let rx = chars.first(where: { $0.uuid == Self.rxUUID }),
                  let tx = chars.first(where: { $0.uuid == Self.txUUID }) else {
                central?.cancelPeripheralConnection(peripheral); return
            }
            rxOf[peripheral.identifier] = rx
            peripheral.readValue(for: info)
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        let uuid = characteristic.uuid
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard let value else { return }
            if uuid == Self.infoUUID {
                let obj = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any]
                let tag = obj?["g"] as? String ?? "", token = obj?["t"] as? String ?? ""
                guard shouldLink(tag, token) else {
                    cooldown[id] = Date().addingTimeInterval(30)
                    central?.cancelPeripheralConnection(peripheral)
                    return
                }
                infoOK.insert(id)
                if notifying.contains(id) { linkUp(id) }
            } else if uuid == Self.txUUID {
                received(value, from: id)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let on = characteristic.isNotifying
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard on else { return }
            notifying.insert(id)
            if infoOK.contains(id) { linkUp(id) }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { pump(peripheral.identifier) }
    }
}

// MARK: - Peripheral role

extension MeshBLETransport: CBPeripheralManagerDelegate {

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            onNote("Bluetooth (advertise): \(peripheral.state == .poweredOn ? "on" : "off")")
            if peripheral.state == .poweredOn { startAdvertising() } else { serviceAdded = false }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            // Services are re-added on power-on; nothing else to restore.
            serviceAdded = false
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error { onNote("BLE service failed: \(error.localizedDescription)"); serviceAdded = false; return }
            startAdvertising()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated {
            guard request.characteristic.uuid == Self.infoUUID else {
                peripheral.respond(to: request, withResult: .requestNotSupported); return
            }
            let value = info()
            guard request.offset <= value.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
            request.value = value.subdata(in: request.offset..<value.count)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            for r in requests where r.characteristic.uuid == Self.rxUUID {
                let id = r.central.identifier
                if centrals[id] == nil { centrals[id] = r.central }
                if let v = r.value { received(v, from: id) }
            }
            if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.txUUID else { return }
            centrals[central.identifier] = central
            linkUp(central.identifier)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            centrals[central.identifier] = nil
            linkDown(central.identifier)
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { for id in centrals.keys { pump(id) } }
    }
}
