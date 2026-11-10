package app.nobars.core

import kotlinx.serialization.json.*
import java.io.File
import kotlin.test.*

class VectorTest {
    private val v = Json.parseToJsonElement(File(System.getProperty("vectors")).readText()).jsonObject

    @Test fun groupKeysMatchReference() {
        for (g in v["groups"]!!.jsonArray.map { it.jsonObject }) {
            val keys = GroupKeys(g["code"]!!.jsonPrimitive.content)
            assertEquals(g["tag"]!!.jsonPrimitive.content, keys.discoveryTag)
            assertEquals(g["key"]!!.jsonPrimitive.content, keys.key.toHex())
        }
    }

    @Test fun opensAndVerifiesReferencePackets() {
        val key = GroupKeys(v["sealedWithGroup"]!!.jsonPrimitive.content).key
        for (p in v["packets"]!!.jsonArray.map { it.jsonObject }) {
            val opened = assertNotNull(MeshCrypto.open(p["sealed"]!!.jsonPrimitive.content.hexToBytes(), key))
            assertTrue(MeshCrypto.verify(opened), "signature for ${opened.kind}")
            assertEquals(p["signingBytes"]!!.jsonPrimitive.content, MeshCrypto.signingBytes(opened).toHex())
            assertEquals(p["packet"]!!.jsonObject["id"]!!.jsonPrimitive.content, opened.id)
        }
    }

    @Test fun referenceSeedGivesSameKeyAsIos() {
        val packet = v["packets"]!!.jsonArray[0].jsonObject["packet"]!!.jsonObject
        val signer = SigningKey(v["signingKeySeed"]!!.jsonPrimitive.content.hexToBytes())
        assertEquals(packet["senderKey"]!!.jsonPrimitive.content, java.util.Base64.getEncoder().encodeToString(signer.publicKey))
    }

    @Test fun rejectsTamperedReferencePacket() {
        val bad = assertNotNull(MeshPacket.fromJson(v["badSignature"]!!.toString()))
        assertFalse(MeshCrypto.verify(bad))
    }
}

class CryptoTest {
    private val keys = GroupKeys("ci")
    private val me = SigningKey()

    private fun signed() = MeshPacket(kind = MeshPacket.Kind.LOCATION, senderName = "Asha",
        latitude = 28.4744, longitude = 77.504, isEmergency = true).also { MeshCrypto.sign(it, me) }

    @Test fun roundTripSurvivesRelay() {
        val opened = assertNotNull(MeshCrypto.open(MeshCrypto.seal(signed(), keys.key), keys.key))
        opened.ttl -= 4
        val again = assertNotNull(MeshCrypto.open(MeshCrypto.seal(opened, keys.key), keys.key))
        assertTrue(MeshCrypto.verify(again))
    }

    @Test fun wrongGroupCannotOpen() {
        assertNull(MeshCrypto.open(MeshCrypto.seal(signed(), keys.key), GroupKeys("other").key))
    }

    @Test fun tamperingRejected() {
        val sealed = MeshCrypto.seal(signed(), keys.key)
        sealed[sealed.size - 20] = (sealed[sealed.size - 20].toInt() xor 1).toByte()
        assertNull(MeshCrypto.open(sealed, keys.key))
        val p = signed(); val edited = p.copy(isEmergency = false).also { it.senderKey = p.senderKey; it.signature = p.signature }
        assertFalse(MeshCrypto.verify(edited))
    }

    @Test fun pins() {
        val pins = KeyPins()
        assertEquals(KeyPins.Result.NEW, pins.check("A", byteArrayOf(1)))
        assertEquals(KeyPins.Result.MATCH, pins.check("A", byteArrayOf(1)))
        assertEquals(KeyPins.Result.MISMATCH, pins.check("A", byteArrayOf(2)))
    }
}

class RouterAndFramingTest {
    @Test fun routerDedupesAndDecrements() {
        val r = MeshRouter()
        val p = MeshPacket(ttl = 2, kind = MeshPacket.Kind.MESSAGE, senderName = "A", text = "x")
        val d = assertIs<MeshRouter.Decision.Deliver>(r.receive(p))
        assertEquals(1, d.forward?.ttl)
        assertEquals(MeshRouter.Decision.Drop, r.receive(p))
        assertNull(assertIs<MeshRouter.Decision.Deliver>(MeshRouter().receive(p.copy(ttl = 1))).forward)
    }

    @Test fun framingRoundTripOutOfOrder() {
        val msg = ByteArray(1000) { it.toByte() }
        val frames = BleFraming.split(msg, seq = 42, maxFrame = 182)
        assertTrue(frames.size > 1)
        val r = BleFraming.Reassembler()
        val results = frames.reversed().map { r.accept(it) }
        assertContentEquals(msg, results.last())
        assertTrue(results.dropLast(1).all { it == null })
    }

    @Test fun framingSingle() {
        val r = BleFraming.Reassembler()
        assertContentEquals(byteArrayOf(9), r.accept(BleFraming.split(byteArrayOf(9), 1, 20).single()))
    }
}

/**
 * Writes protocol/vectors-android.json: packets sealed and signed by this
 * Kotlin code, which the iOS tests then open and verify. Run with
 * `gradle :core:test -PwriteVectors` after changing the format.
 */
class AndroidVectorWriter {
    @Test fun write() {
        val out = System.getProperty("writeVectors") ?: return
        val key = GroupKeys("fest24")
        val signer = SigningKey("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f".hexToBytes())
        val packets = listOf(
            MeshPacket(kind = MeshPacket.Kind.MESSAGE, senderName = "Asha", text = "from android: gate 3 → stage", timestamp = 784555123.456),
            MeshPacket(ttl = 9, kind = MeshPacket.Kind.LOCATION, senderName = "Asha", latitude = 28.4744, longitude = 77.504, isEmergency = true, timestamp = 784555200.125),
            MeshPacket(ttl = 1, kind = MeshPacket.Kind.HELLO, senderName = "Asha", timestamp = 784555300.0),
            MeshPacket(kind = MeshPacket.Kind.CALL, senderName = "Asha", text = "invite", to = "Arjun", timestamp = 784555400.5),
            MeshPacket(kind = MeshPacket.Kind.VOICE, senderName = "Asha", to = "Arjun", seq = 7, audio = ByteArray(160) { (it * 3).toByte() }, timestamp = 784555401.0),
        ).onEach { MeshCrypto.sign(it, signer) }
        val json = buildJsonObject {
            put("group", "fest24")
            put("packets", buildJsonArray {
                packets.forEach { p -> add(buildJsonObject {
                    put("id", p.id); put("kind", p.kind.wire)
                    put("signingBytes", MeshCrypto.signingBytes(p).toHex())
                    put("sealed", MeshCrypto.seal(p, key.key).toHex())
                }) }
            })
        }
        File(out).writeText(Json { prettyPrint = true }.encodeToString(JsonObject.serializer(), json) + "\n")
    }
}

class FramingLayoutTest {
    /** Byte layout must match the iOS framer exactly. */
    @Test fun headerLayout() {
        val f = BleFraming.split(byteArrayOf(0xAB.toByte()), seq = 0x01020304, maxFrame = 20).single()
        assertContentEquals(byteArrayOf(1, 1, 2, 3, 4, 0, 1, 0xAB.toByte()), f)
    }
}
