package app.nobars.android

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import android.util.Base64
import app.nobars.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val sender: String,
    val text: String,
    val time: Long,
    val pending: Boolean = false,
    val system: Boolean = false,
)

data class Buddy(val name: String, val lat: Double, val lon: Double, val time: Long)

data class MeshState(
    val name: String = "",
    val group: String = "",
    val live: Boolean = false,
    val connected: List<String> = emptyList(),
    val viaMesh: List<String> = emptyList(),
    val messages: List<ChatMessage> = emptyList(),
    val buddies: Map<String, Buddy> = emptyMap(),
    val emergencies: Set<String> = emptySet(),
    val sos: Boolean = false,
    val me: Location? = null,
    val toast: String? = null,
    val log: List<String> = emptyList(),
    val fingerprint: String = "",
)

/**
 * The Android side of the mesh. Same rules as `MeshConnectivityManager` on
 * iOS: packets are sealed with the group key and signed per phone, links must
 * pass an encrypted hello, keys are pinned on first use, and everything floods
 * with a TTL through `MeshRouter`. Runs on the main thread inside MeshService.
 *
 * Android talks Bluetooth LE only, so it does chat, live location and SOS.
 * Calls stay on iPhones, which have the faster Wi-Fi links they need.
 */
class MeshEngine(private val context: Context) : BleTransport.Listener {

    companion object {
        private const val HELLO_TIMEOUT_MS = 10_000L
        private const val MESH_BUDDY_WINDOW_MS = 120_000L
        private const val SOS_INTERVAL_MS = 5_000L

        @Volatile var instance: MeshEngine? = null
        fun get(context: Context) = instance ?: synchronized(this) {
            instance ?: MeshEngine(context.applicationContext).also { instance = it }
        }
    }

    private val prefs = context.getSharedPreferences("nobars", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val signer: SigningKey = loadSigningKey()
    private val token = UUID.randomUUID().toString().uppercase()
    private val ble = BleTransport(context, this)
    private var router = MeshRouter()
    private var keys = GroupKeys(prefs.getString("group", "") ?: "")
    private var pins = loadPins()
    private val outbox = mutableListOf<Pair<MeshPacket, String>>()
    private val nameByLink = HashMap<String, String>()
    private val unverified = HashSet<String>()
    private val lastHeard = HashMap<String, Long>()
    private val notifier = Notifier(context)

    private val _state = MutableStateFlow(
        MeshState(
            name = prefs.getString("name", "") ?: "",
            group = prefs.getString("group", "") ?: "",
            fingerprint = MeshCrypto.fingerprint(signer.publicKey),
        )
    )
    val state: StateFlow<MeshState> = _state.asStateFlow()
    private inline fun update(f: (MeshState) -> MeshState) { _state.value = f(_state.value) }

    val isOnboarded get() = prefs.getBoolean("onboarded", false)
    var appVisible = false

    init {
        loadChat()
        main.postDelayed(object : Runnable {
            override fun run() { refreshViaMesh(); main.postDelayed(this, 15_000) }
        }, 15_000)
    }

    // MARK: Identity and group

    fun join(name: String, group: String) {
        val n = name.trim().ifEmpty { android.os.Build.MODEL }
        val g = group.trim()
        val groupChanged = g != _state.value.group
        prefs.edit().putString("name", n).putString("group", g).putBoolean("onboarded", true).apply()
        if (groupChanged) {
            saveChat()
            keys = GroupKeys(g)
            pins = loadPins()
            router = MeshRouter()
            nameByLink.clear(); unverified.clear()
            update { it.copy(group = g, connected = emptyList(), viaMesh = emptyList(), buddies = emptyMap(), emergencies = emptySet()) }
            loadChat()
            ble.restart()
        }
        update { it.copy(name = n) }
    }

    fun start() {
        if (_state.value.live) return
        ble.start()
        update { it.copy(live = ble.isRunning) }
        if (ble.isRunning) note("Mesh live as ${_state.value.name}")
        else { note("Couldn't start Bluetooth"); flash("Turn on Bluetooth to join the mesh") }
    }

    fun stop() {
        stopSos()
        ble.stop()
        nameByLink.clear(); unverified.clear()
        update { it.copy(live = false, connected = emptyList(), viaMesh = emptyList()) }
    }

    fun leave() {
        stop()
        prefs.edit().putBoolean("onboarded", false).apply()
    }

    // MARK: BleTransport.Listener

    override fun info(): ByteArray =
        JSONObject().put("v", 1).put("g", keys.discoveryTag).put("t", token).toString().toByteArray()

    override fun shouldLink(tag: String, token: String) = tag == keys.discoveryTag && token != this.token

    override fun onLinkUp(link: String) {
        unverified += link
        note("Bluetooth link up, checking group key")
        sendHello(link)
        main.postDelayed({ if (link in unverified) reject(link, "no hello") }, HELLO_TIMEOUT_MS)
    }

    override fun onLinkDown(link: String) {
        unverified -= link
        if (nameByLink.remove(link) != null) refreshConnected()
    }

    override fun onData(data: ByteArray, link: String) = handleData(data, link)

    override fun onNote(text: String) = note(text)

    // MARK: Sending

    fun sendMessage(text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        val p = MeshPacket(kind = MeshPacket.Kind.MESSAGE, senderName = _state.value.name, text = t)
        MeshCrypto.sign(p, signer)
        router.markOwn(p)
        val queued = _state.value.connected.isEmpty()
        val msg = ChatMessage(sender = p.senderName, text = t, time = p.unixMillis, pending = queued)
        if (queued) { outbox += p to msg.id; flash("Queued. Sends when a buddy connects") } else broadcast(p, null)
        appendMessage(msg)
    }

    private fun flushOutbox() {
        if (outbox.isEmpty()) return
        val ids = outbox.map { it.second }.toSet()
        outbox.forEach { broadcast(it.first, null) }
        note("Delivered ${outbox.size} queued message(s)")
        outbox.clear()
        update { s -> s.copy(messages = s.messages.map { if (it.id in ids) it.copy(pending = false) else it }) }
        saveChat()
    }

    private fun broadcast(p: MeshPacket, excluding: String?) {
        // Call traffic needs Wi-Fi speed; Android only has Bluetooth LE links.
        if (p.kind == MeshPacket.Kind.CALL || p.kind == MeshPacket.Kind.VOICE) return
        val sealed = MeshCrypto.seal(p, keys.key)
        nameByLink.keys.filter { it != excluding }.forEach { ble.send(sealed, it) }
    }

    private fun sendHello(link: String) {
        val p = MeshPacket(ttl = 1, kind = MeshPacket.Kind.HELLO, senderName = _state.value.name)
        MeshCrypto.sign(p, signer)
        ble.send(MeshCrypto.seal(p, keys.key), link)
    }

    private fun reject(link: String, reason: String) {
        unverified -= link
        note("Dropped link: $reason")
        ble.disconnect(link)
    }

    // MARK: Receiving

    private fun handleData(data: ByteArray, link: String) {
        val p = MeshCrypto.open(data, keys.key) ?: run {
            note("Dropped unreadable packet (wrong group key)")
            if (link in unverified) reject(link, "can't prove the group code")
            return
        }
        val key = p.senderKey
        if (!MeshCrypto.verify(p) || key == null) return note("Dropped unsigned packet")
        val nowApple = System.currentTimeMillis() / 1000.0 - APPLE_EPOCH_OFFSET
        if (p.kind != MeshPacket.Kind.MESSAGE && kotlin.math.abs(nowApple - p.timestamp) > MeshCrypto.MAX_POSITION_AGE) {
            return note("Dropped stale ${p.kind.wire} from ${p.senderName}")
        }
        val me = _state.value.name
        if (p.kind == MeshPacket.Kind.HELLO && p.senderName == me) return reject(link, "uses my name")
        if (p.senderName == me) {
            if (!key.contentEquals(signer.publicKey)) return note("Rejected packet using my name")
        } else when (pins.check(p.senderName, key)) {
            KeyPins.Result.NEW -> { savePins(); note("Trusted ${p.senderName} (key ${MeshCrypto.fingerprint(key)})") }
            KeyPins.Result.MATCH -> Unit
            KeyPins.Result.MISMATCH -> {
                note("Rejected packet claiming to be ${p.senderName}")
                flash("Someone tried to send as ${p.senderName}. Ignored.")
                if (p.kind == MeshPacket.Kind.HELLO) reject(link, "identity doesn't match")
                return
            }
        }
        if (p.kind == MeshPacket.Kind.HELLO) {
            unverified -= link
            if (nameByLink[link] != p.senderName) {
                nameByLink[link] = p.senderName
                refreshConnected()
            }
            heard(p.senderName)
            return
        }
        if (link !in nameByLink) return
        deliver(p, link)
    }

    private fun deliver(p: MeshPacket, link: String) {
        val decision = router.receive(p) as? MeshRouter.Decision.Deliver ?: return
        heard(p.senderName)
        when (p.kind) {
            MeshPacket.Kind.MESSAGE -> p.text?.let { text ->
                note("Message from ${p.senderName}")
                appendMessage(ChatMessage(sender = p.senderName, text = text, time = p.unixMillis))
                if (!appVisible) notifier.message(p.senderName, text)
            }
            MeshPacket.Kind.LOCATION -> {
                val lat = p.latitude; val lon = p.longitude
                if (lat != null && lon != null) {
                    val wasSos = p.senderName in _state.value.emergencies
                    val sos = p.isEmergency == true
                    update { s ->
                        s.copy(
                            buddies = s.buddies + (p.senderName to Buddy(p.senderName, lat, lon, p.unixMillis)),
                            emergencies = if (sos) s.emergencies + p.senderName else s.emergencies - p.senderName,
                        )
                    }
                    if (sos && !wasSos) {
                        flash("SOS from ${p.senderName}")
                        note("SOS from ${p.senderName}")
                        notifier.sos(p.senderName)
                    }
                }
            }
            else -> Unit // hello handled earlier; calls are iPhone to iPhone over Wi-Fi.
        }
        decision.forward?.let { broadcast(it, link) }
    }

    private fun refreshConnected() {
        val now = nameByLink.values.toSet()
        val old = _state.value.connected.toSet()
        (now - old).sorted().forEach {
            appendMessage(ChatMessage(sender = "", text = "$it joined the mesh", time = System.currentTimeMillis(), system = true))
            flash("$it joined the mesh")
            note("Connected: $it")
        }
        (old - now).sorted().forEach {
            appendMessage(ChatMessage(sender = "", text = "$it left the mesh", time = System.currentTimeMillis(), system = true))
            note("Disconnected: $it")
        }
        update { s -> s.copy(connected = s.connected.filter { it in now } + (now - old).sorted()) }
        if ((now - old).isNotEmpty()) flushOutbox()
        refreshViaMesh()
        MeshService.refreshNotification(context)
    }

    private fun heard(name: String) {
        if (name == _state.value.name) return
        lastHeard[name] = System.currentTimeMillis()
        refreshViaMesh()
    }

    private fun refreshViaMesh() {
        val cutoff = System.currentTimeMillis() - MESH_BUDDY_WINDOW_MS
        lastHeard.entries.removeIf { it.value < cutoff }
        val direct = _state.value.connected.toSet()
        val list = lastHeard.keys.filter { it !in direct }.sorted()
        if (list != _state.value.viaMesh) update { it.copy(viaMesh = list) }
    }

    // MARK: SOS and location

    private val locationManager = context.getSystemService(LocationManager::class.java)
    private val locationListener = LocationListener { loc -> update { it.copy(me = loc) }; if (_state.value.sos) broadcastLocation(loc) }
    private var sosTicker: Runnable? = null

    @SuppressLint("MissingPermission")
    fun startSos() {
        if (_state.value.sos) return
        update { it.copy(sos = true) }
        note("SOS started")
        flash("Sharing your live location")
        runCatching {
            val provider = if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER
            locationManager.requestLocationUpdates(provider, 3_000L, 5f, locationListener, Looper.getMainLooper())
            (locationManager.getLastKnownLocation(provider) ?: locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER))
                ?.let { loc -> update { it.copy(me = loc) }; broadcastLocation(loc) }
        }.onFailure { flash("Turn on Location to share") }
        sosTicker = object : Runnable {
            override fun run() {
                if (!_state.value.sos) return
                _state.value.me?.let { broadcastLocation(it) }
                main.postDelayed(this, SOS_INTERVAL_MS)
            }
        }.also { main.postDelayed(it, SOS_INTERVAL_MS) }
        MeshService.refreshNotification(context)
    }

    fun stopSos() {
        if (!_state.value.sos) return
        update { it.copy(sos = false) }
        note("SOS stopped")
        _state.value.me?.let { broadcastLocation(it) } // all-clear
        sosTicker?.let { main.removeCallbacks(it) }
        runCatching { locationManager.removeUpdates(locationListener) }
        flash("Stopped sharing location")
        MeshService.refreshNotification(context)
    }

    private fun broadcastLocation(loc: Location) {
        val p = MeshPacket(kind = MeshPacket.Kind.LOCATION, senderName = _state.value.name,
            latitude = loc.latitude, longitude = loc.longitude, isEmergency = _state.value.sos)
        MeshCrypto.sign(p, signer)
        router.markOwn(p)
        broadcast(p, null)
    }

    // MARK: Settings actions

    fun resetTrustedBuddies() { pins.clear(); savePins(); flash("Trusted buddies reset") }

    fun clearChat() {
        outbox.clear()
        update { it.copy(messages = emptyList()) }
        chatFile().delete()
        flash("Chat history cleared")
    }

    // MARK: Storage

    private fun loadSigningKey(): SigningKey {
        prefs.getString("seed", null)?.let { return SigningKey(Base64.decode(it, Base64.NO_WRAP)) }
        return SigningKey().also { prefs.edit().putString("seed", Base64.encodeToString(it.seed, Base64.NO_WRAP)).apply() }
    }

    private fun loadPins(): KeyPins {
        val json = prefs.getString("pins.${keys.discoveryTag}", null) ?: return KeyPins()
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return KeyPins()
        return KeyPins(o.keys().asSequence().associateWith { Base64.decode(o.getString(it), Base64.NO_WRAP) })
    }

    private fun savePins() {
        val o = JSONObject()
        pins.snapshot.forEach { (k, v) -> o.put(k, Base64.encodeToString(v, Base64.NO_WRAP)) }
        prefs.edit().putString("pins.${keys.discoveryTag}", o.toString()).apply()
    }

    private fun chatFile() = File(context.filesDir, "chat-${keys.discoveryTag}.json")

    private fun appendMessage(m: ChatMessage) {
        update { it.copy(messages = (it.messages + m).takeLast(1000)) }
        saveChat()
    }

    private fun saveChat() {
        val arr = JSONArray()
        _state.value.messages.forEach {
            arr.put(JSONObject().put("id", it.id).put("sender", it.sender).put("text", it.text)
                .put("time", it.time).put("system", it.system).put("pending", it.pending))
        }
        val queued = JSONArray()
        outbox.forEach { (p, id) -> queued.put(JSONObject().put("packet", p.toJson()).put("id", id)) }
        runCatching { chatFile().writeText(JSONObject().put("messages", arr).put("outbox", queued).toString()) }
    }

    private fun loadChat() {
        outbox.clear()
        val o = runCatching { JSONObject(chatFile().readText()) }.getOrNull()
        val arr = o?.optJSONArray("messages") ?: JSONArray()
        val list = (0 until arr.length()).map { i ->
            val m = arr.getJSONObject(i)
            ChatMessage(m.getString("id"), m.getString("sender"), m.getString("text"), m.getLong("time"),
                m.optBoolean("pending"), m.optBoolean("system"))
        }
        val q = o?.optJSONArray("outbox") ?: JSONArray()
        for (i in 0 until q.length()) {
            val item = q.getJSONObject(i)
            MeshPacket.fromJson(item.getString("packet"))?.let { outbox += it to item.getString("id") }
        }
        update { it.copy(messages = list) }
    }

    // MARK: UI feedback

    private var toastClear: Runnable? = null

    private fun flash(text: String) {
        update { it.copy(toast = text) }
        toastClear?.let { main.removeCallbacks(it) }
        toastClear = Runnable { update { it.copy(toast = null) } }.also { main.postDelayed(it, 2_500) }
    }

    private fun note(text: String) {
        android.util.Log.i("NoBars", text)
        update { it.copy(log = (it.log + text).takeLast(40)) }
    }
}
