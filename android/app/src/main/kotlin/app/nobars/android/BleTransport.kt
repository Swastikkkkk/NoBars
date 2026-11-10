package app.nobars.android

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import app.nobars.core.BleFraming
import java.util.UUID

/**
 * Bluetooth LE links, same GATT layout as the iOS app (see protocol/PROTOCOL.md).
 *
 * Every phone advertises the NoBars service and runs a GATT server (peripheral
 * role), and also scans and connects to others (central role). Links are named
 * "c:<address>" when we connected out and "s:<address>" when they connected
 * in. Everything runs on the main thread; GATT callbacks are posted to it.
 * The transport only moves opaque sealed packets.
 */
@SuppressLint("MissingPermission") // MeshService only starts us once permissions are granted.
class BleTransport(private val context: Context, private val listener: Listener) {

    interface Listener {
        fun info(): ByteArray
        fun shouldLink(tag: String, token: String): Boolean
        fun onLinkUp(link: String)
        fun onLinkDown(link: String)
        fun onData(data: ByteArray, link: String)
        fun onNote(text: String)
    }

    companion object {
        val SERVICE: UUID = UUID.fromString("6E6F6261-7273-4D65-7368-000000000001")
        val INFO: UUID = UUID.fromString("6E6F6261-7273-4D65-7368-000000000002")
        val RX: UUID = UUID.fromString("6E6F6261-7273-4D65-7368-000000000003")
        val TX: UUID = UUID.fromString("6E6F6261-7273-4D65-7368-000000000004")
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val MAX_QUEUE = 400
    }

    private val main = Handler(Looper.getMainLooper())
    private val manager = context.getSystemService(BluetoothManager::class.java)
    private val adapter: BluetoothAdapter? get() = manager?.adapter

    private var running = false
    private var server: BluetoothGattServer? = null
    private var txChar: BluetoothGattCharacteristic? = null

    // Central role
    private val clients = HashMap<String, BluetoothGatt>()       // address -> gatt
    private val clientMtu = HashMap<String, Int>()
    private val clientInfoOk = HashSet<String>()
    private val cooldown = HashMap<String, Long>()
    private val writing = HashSet<String>()                         // a write is in flight

    // Peripheral role
    private val serverDevices = HashMap<String, BluetoothDevice>()  // address -> device
    private val serverMtu = HashMap<String, Int>()
    private var notifying: String? = null                           // one notification in flight

    // Shared
    private val up = HashSet<String>()
    private val reassemblers = HashMap<String, BleFraming.Reassembler>()
    private val queues = HashMap<String, ArrayDeque<ByteArray>>()
    private val early = HashMap<String, MutableList<ByteArray>>()
    private var seq = 1

    val isRunning get() = running

    fun start() {
        if (running) return
        val a = adapter ?: return listener.onNote("No Bluetooth on this phone")
        if (!a.isEnabled) return listener.onNote("Bluetooth is off")
        running = true
        openServer()
        startAdvertising()
        startScan()
    }

    fun stop() {
        if (!running) return
        running = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCallback) }
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) }
        clients.values.forEach { runCatching { it.disconnect(); it.close() } }
        runCatching { server?.close() }
        server = null
        up.toList().forEach { listener.onLinkDown(it) }
        clients.clear(); clientMtu.clear(); clientInfoOk.clear(); writing.clear()
        serverDevices.clear(); serverMtu.clear(); up.clear(); reassemblers.clear(); queues.clear(); early.clear()
        notifying = null
    }

    fun restart() { val was = running; stop(); if (was) start() }

    fun disconnect(link: String) {
        val addr = link.substring(2)
        if (link.startsWith("c:")) {
            cooldown[addr] = System.currentTimeMillis() + 30_000
            clients[addr]?.disconnect()
        } else {
            serverDevices[addr]?.let { server?.cancelConnection(it) }
            linkDown(link)
        }
    }

    // MARK: Sending

    fun send(data: ByteArray, link: String) {
        if (link !in up) return
        val addr = link.substring(2)
        val mtu = if (link.startsWith("c:")) clientMtu[addr] ?: 23 else serverMtu[addr] ?: 23
        val frames = runCatching { BleFraming.split(data, seq++, maxOf(20, mtu - 3)) }.getOrNull() ?: return
        val q = queues.getOrPut(link) { ArrayDeque() }
        frames.forEach { q.addLast(it) }
        while (q.size > MAX_QUEUE) q.removeFirst()
        pump(link)
    }

    private fun pump(link: String) {
        val q = queues[link] ?: return
        if (q.isEmpty()) return
        val addr = link.substring(2)
        if (link.startsWith("c:")) {
            if (addr in writing) return
            val gatt = clients[addr] ?: return
            val rx = gatt.getService(SERVICE)?.getCharacteristic(RX) ?: return
            val frame = q.removeFirst()
            writing += addr
            val ok = if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(rx, frame, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION")
                rx.value = frame
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(rx)
            }
            if (!ok) { writing -= addr; q.addFirst(frame); main.postDelayed({ pump(link) }, 30) }
        } else {
            if (notifying != null) return
            val device = serverDevices[addr] ?: return
            val tx = txChar ?: return
            val frame = q.removeFirst()
            notifying = link
            val ok = if (Build.VERSION.SDK_INT >= 33) {
                server?.notifyCharacteristicChanged(device, tx, false, frame) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                tx.value = frame
                @Suppress("DEPRECATION")
                server?.notifyCharacteristicChanged(device, tx, false) == true
            }
            if (!ok) { notifying = null; q.addFirst(frame); main.postDelayed({ pumpAllServer() }, 30) }
        }
    }

    private fun pumpAllServer() { up.filter { it.startsWith("s:") }.forEach { pump(it) } }

    // MARK: Links

    private fun linkUp(link: String) {
        if (!up.add(link)) return
        listener.onLinkUp(link)
        early.remove(link)?.forEach { listener.onData(it, link) }
    }

    private fun linkDown(link: String) {
        reassemblers.remove(link); queues.remove(link); early.remove(link)
        if (notifying == link) notifying = null
        if (up.remove(link)) listener.onLinkDown(link)
    }

    private fun received(frame: ByteArray, link: String) {
        val msg = reassemblers.getOrPut(link) { BleFraming.Reassembler() }.accept(frame) ?: return
        if (link in up) listener.onData(msg, link)
        else early.getOrPut(link) { mutableListOf() }.let { if (it.size < 8) it += msg }
    }

    // MARK: Peripheral role

    private fun openServer() {
        val s = manager?.openGattServer(context, serverCallback) ?: return
        val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(BluetoothGattCharacteristic(INFO,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        service.addCharacteristic(BluetoothGattCharacteristic(RX,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE))
        val tx = BluetoothGattCharacteristic(TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY, BluetoothGattCharacteristic.PERMISSION_READ)
        tx.addDescriptor(BluetoothGattDescriptor(CCCD,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        service.addCharacteristic(tx)
        txChar = tx
        s.addService(service)
        server = s
    }

    private fun startAdvertising() {
        val adv = adapter?.bluetoothLeAdvertiser ?: return listener.onNote("This phone can't advertise over Bluetooth LE")
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build()
        adv.startAdvertising(settings, data, advertiseCallback)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) { main.post { listener.onNote("Bluetooth advertise failed ($errorCode)") } }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) = main.post {
            val link = "s:${device.address}"
            if (newState == BluetoothProfile.STATE_CONNECTED) serverDevices[device.address] = device
            else { serverDevices.remove(device.address); serverMtu.remove(device.address); linkDown(link) }
        }.let { }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) = main.post { serverMtu[device.address] = mtu }.let { }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
            main.post {
                val value = if (characteristic.uuid == INFO) listener.info() else ByteArray(0)
                val ok = offset <= value.size
                server?.sendResponse(device, requestId,
                    if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET, offset,
                    if (ok) value.copyOfRange(offset, value.size) else null)
            }
        }

        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
                                                  preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            main.post {
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                if (characteristic.uuid != RX || value == null) return@post
                serverDevices[device.address] = device
                received(value, "s:${device.address}")
            }
        }

        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
                                              preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            main.post {
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                if (descriptor.uuid != CCCD) return@post
                val link = "s:${device.address}"
                serverDevices[device.address] = device
                if (value != null && value.isNotEmpty() && value[0].toInt() != 0) linkUp(link) else linkDown(link)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) = main.post {
            notifying = null
            pumpAllServer()
        }.let { }
    }

    // MARK: Central role

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { maybeConnect(result.device) }
        }
        override fun onScanFailed(errorCode: Int) { main.post { listener.onNote("Bluetooth scan failed ($errorCode)") } }
    }

    private fun maybeConnect(device: BluetoothDevice) {
        val addr = device.address
        if (!running || clients.containsKey(addr) || serverDevices.containsKey(addr)) return
        if ((cooldown[addr] ?: 0) > System.currentTimeMillis()) return
        clients[addr] = device.connectGatt(context, false, clientCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private fun forgetClient(addr: String) {
        clients.remove(addr)?.close()
        clientMtu.remove(addr); clientInfoOk.remove(addr); writing.remove(addr)
        linkDown("c:$addr")
    }

    private val clientCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) = main.post {
            val addr = gatt.device.address
            if (newState == BluetoothProfile.STATE_CONNECTED) gatt.requestMtu(517)
            else forgetClient(addr)
        }.let { }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) = main.post {
            clientMtu[gatt.device.address] = mtu
            gatt.discoverServices()
        }.let { }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) = main.post {
            val info = gatt.getService(SERVICE)?.getCharacteristic(INFO)
            if (info == null) gatt.disconnect() else gatt.readCharacteristic(info)
        }.let { }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION") val v = characteristic.value ?: ByteArray(0)
            handleRead(gatt, characteristic.uuid, v)
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            handleRead(gatt, characteristic.uuid, value)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = main.post {
            if (descriptor.uuid == CCCD && status == BluetoothGatt.GATT_SUCCESS) linkUp("c:${gatt.device.address}")
            else gatt.disconnect()
        }.let { }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") val v = characteristic.value ?: return
            main.post { received(v, "c:${gatt.device.address}") }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            main.post { received(value, "c:${gatt.device.address}") }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) = main.post {
            writing -= gatt.device.address
            pump("c:${gatt.device.address}")
        }.let { }
    }

    private fun handleRead(gatt: BluetoothGatt, uuid: UUID, value: ByteArray) = main.post {
        if (uuid != INFO) return@post
        val addr = gatt.device.address
        val obj = runCatching { org.json.JSONObject(String(value)) }.getOrNull()
        val tag = obj?.optString("g").orEmpty()
        val token = obj?.optString("t").orEmpty()
        if (!listener.shouldLink(tag, token)) {
            cooldown[addr] = System.currentTimeMillis() + 30_000
            gatt.disconnect()
            return@post
        }
        clientInfoOk += addr
        val tx = gatt.getService(SERVICE)?.getCharacteristic(TX) ?: return@post gatt.disconnect()
        gatt.setCharacteristicNotification(tx, true)
        val cccd = tx.getDescriptor(CCCD) ?: return@post gatt.disconnect()
        if (Build.VERSION.SDK_INT >= 33) {
            gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } else {
            @Suppress("DEPRECATION")
            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            @Suppress("DEPRECATION")
            gatt.writeDescriptor(cccd)
        }
    }
}
