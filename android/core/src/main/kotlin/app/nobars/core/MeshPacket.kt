package app.nobars.core

import kotlinx.serialization.json.*
import java.util.Base64
import java.util.UUID

/** Seconds between 1970-01-01 and 2001-01-01, the epoch Swift's JSON uses for dates. */
const val APPLE_EPOCH_OFFSET = 978_307_200.0

/**
 * One unit of data on the mesh. Mirrors `MeshRelayPacket` in the iOS app field
 * for field, and serialises to the same JSON so either platform can read the
 * other's packets. `timestamp` is seconds since 2001-01-01 (Apple's reference
 * date), because that is what Swift's JSONEncoder writes.
 */
data class MeshPacket(
    val id: String = UUID.randomUUID().toString().uppercase(),
    var ttl: Int = DEFAULT_TTL,
    val kind: Kind,
    val senderName: String,
    val timestamp: Double = System.currentTimeMillis() / 1000.0 - APPLE_EPOCH_OFFSET,
    val text: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val isEmergency: Boolean? = null,
    var senderKey: ByteArray? = null,
    var signature: ByteArray? = null,
    /** Addressee for calls; relays forward but don't deliver. */
    val to: String? = null,
    val seq: Int? = null,
    val audio: ByteArray? = null,
) {
    enum class Kind(val wire: String) {
        MESSAGE("message"), LOCATION("location"), HELLO("hello"), CALL("call"), VOICE("voice");
        companion object { fun of(s: String) = entries.firstOrNull { it.wire == s } }
    }

    val unixMillis: Long get() = ((timestamp + APPLE_EPOCH_OFFSET) * 1000).toLong()

    fun toJson(): String = buildJsonObject {
        put("id", id)
        put("ttl", ttl)
        put("kind", kind.wire)
        put("senderName", senderName)
        put("timestamp", timestamp)
        text?.let { put("text", it) }
        latitude?.let { put("latitude", it) }
        longitude?.let { put("longitude", it) }
        isEmergency?.let { put("isEmergency", it) }
        senderKey?.let { put("senderKey", b64(it)) }
        signature?.let { put("signature", b64(it)) }
        to?.let { put("to", it) }
        seq?.let { put("seq", it) }
        audio?.let { put("audio", b64(it)) }
    }.toString()

    override fun equals(other: Any?) = other is MeshPacket && other.toJson() == toJson()
    override fun hashCode() = toJson().hashCode()

    companion object {
        const val DEFAULT_TTL = 10
        private fun b64(b: ByteArray) = Base64.getEncoder().encodeToString(b)

        fun fromJson(json: String): MeshPacket? = runCatching {
            val o = Json.parseToJsonElement(json).jsonObject
            fun str(k: String) = o[k]?.jsonPrimitive?.contentOrNull
            fun dbl(k: String) = o[k]?.jsonPrimitive?.doubleOrNull
            fun bytes(k: String) = str(k)?.let { Base64.getDecoder().decode(it) }
            MeshPacket(
                id = UUID.fromString(str("id")!!).toString().uppercase(),
                ttl = o["ttl"]!!.jsonPrimitive.int,
                kind = Kind.of(str("kind")!!)!!,
                senderName = str("senderName")!!,
                timestamp = dbl("timestamp")!!,
                text = str("text"),
                latitude = dbl("latitude"),
                longitude = dbl("longitude"),
                isEmergency = o["isEmergency"]?.jsonPrimitive?.booleanOrNull,
                senderKey = bytes("senderKey"),
                signature = bytes("signature"),
                to = str("to"),
                seq = o["seq"]?.jsonPrimitive?.intOrNull,
                audio = bytes("audio"),
            )
        }.getOrNull()
    }
}

/** Remembers recent packet ids so a packet looping around the mesh is handled once. */
class SeenPacketCache(private val limit: Int = 500) {
    private val order = ArrayDeque<String>()
    private val ids = HashSet<String>()

    fun insertIfNew(id: String): Boolean {
        if (!ids.add(id)) return false
        order.addLast(id)
        if (order.size > limit) ids.remove(order.removeFirst())
        return true
    }
}

/** Same flooding rule as the iOS `MeshRouter`. */
class MeshRouter {
    sealed interface Decision {
        data object Drop : Decision
        /** Deliver locally; forward [forward] to all neighbours but the sender (null when TTL ran out). */
        data class Deliver(val forward: MeshPacket?) : Decision
    }

    private val seen = SeenPacketCache()

    fun markOwn(p: MeshPacket) { seen.insertIfNew(p.id) }

    fun receive(p: MeshPacket): Decision {
        if (!seen.insertIfNew(p.id)) return Decision.Drop
        val fwd = p.copy(ttl = p.ttl - 1)
        return Decision.Deliver(if (fwd.ttl > 0) fwd else null)
    }
}
