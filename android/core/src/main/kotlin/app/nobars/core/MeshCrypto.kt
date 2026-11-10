package app.nobars.core

import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Keys derived from a group code. Same derivation as `GroupKeys` on iOS. */
class GroupKeys(code: String) {
    val key: ByteArray
    val discoveryTag: String

    init {
        val sha = MessageDigest.getInstance("SHA-256")
        var d = sha.digest("NoBars.group.v1|$code".toByteArray(Charsets.UTF_8))
        repeat(STRETCH_ROUNDS) { d = sha.digest(d) }
        val salt = "NoBars.v1".toByteArray()
        key = hkdf(d, salt, "payload".toByteArray())
        val tagKey = hkdf(d, salt, "discovery".toByteArray())
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(tagKey, "HmacSHA256")) }
        discoveryTag = mac.doFinal("tag".toByteArray()).copyOf(8).toHex()
    }

    companion object {
        const val STRETCH_ROUNDS = 50_000

        private fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray {
            val gen = HKDFBytesGenerator(SHA256Digest())
            gen.init(HKDFParameters(ikm, salt, info))
            return ByteArray(32).also { gen.generateBytes(it, 0, 32) }
        }
    }
}

/** This phone's Ed25519 signing key. `seed` is the 32-byte private key, as CryptoKit stores it. */
class SigningKey(val seed: ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }) {
    private val priv = Ed25519PrivateKeyParameters(seed, 0)
    val publicKey: ByteArray = priv.generatePublicKey().encoded

    fun sign(message: ByteArray): ByteArray =
        Ed25519Signer().run { init(true, priv); update(message, 0, message.size); generateSignature() }
}

object MeshCrypto {
    val MAGIC = "NB1".toByteArray()
    /** Location and hello packets older than this (seconds) are treated as replays. */
    const val MAX_POSITION_AGE = 10 * 60.0
    private val random = SecureRandom()

    fun seal(p: MeshPacket, key: ByteArray): ByteArray {
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        val plain = p.toJson().toByteArray(Charsets.UTF_8)
        val c = ChaCha20Poly1305().apply { init(true, AEADParameters(KeyParameter(key), 128, nonce)) }
        val out = ByteArray(c.getOutputSize(plain.size))
        val n = c.processBytes(plain, 0, plain.size, out, 0)
        c.doFinal(out, n)
        // Same layout as CryptoKit's ChaChaPoly.SealedBox.combined: nonce | ciphertext | tag.
        return MAGIC + nonce + out
    }

    fun open(data: ByteArray, key: ByteArray): MeshPacket? = runCatching {
        if (data.size < MAGIC.size + 12 + 16 || !data.copyOf(MAGIC.size).contentEquals(MAGIC)) return null
        val nonce = data.copyOfRange(MAGIC.size, MAGIC.size + 12)
        val body = data.copyOfRange(MAGIC.size + 12, data.size)
        val c = ChaCha20Poly1305().apply { init(false, AEADParameters(KeyParameter(key), 128, nonce)) }
        val out = ByteArray(c.getOutputSize(body.size))
        val n = c.processBytes(body, 0, body.size, out, 0)
        val total = n + c.doFinal(out, n)
        MeshPacket.fromJson(String(out, 0, total, Charsets.UTF_8))
    }.getOrNull()

    /** Bytes the signature covers: every field but `ttl`, length-prefixed. Matches iOS exactly. */
    fun signingBytes(p: MeshPacket): ByteArray {
        fun bits(d: Double?) = d?.let { java.lang.Long.toUnsignedString(it.toRawBits()) } ?: "-"
        val fields = listOf(
            "NB1",
            p.id.uppercase(),
            p.kind.wire,
            p.senderName,
            bits(p.timestamp),
            p.text ?: "-",
            bits(p.latitude),
            bits(p.longitude),
            p.isEmergency?.let { if (it) "1" else "0" } ?: "-",
            p.senderKey?.let { java.util.Base64.getEncoder().encodeToString(it) } ?: "-",
            p.to ?: "-",
            p.seq?.toString() ?: "-",
            p.audio?.let { java.util.Base64.getEncoder().encodeToString(it) } ?: "-",
        )
        val out = ByteArrayOutputStream()
        for (f in fields) {
            val b = f.toByteArray(Charsets.UTF_8)
            out.write(ByteBuffer.allocate(4).putInt(b.size).array())
            out.write(b)
        }
        return out.toByteArray()
    }

    fun sign(p: MeshPacket, key: SigningKey) {
        p.senderKey = key.publicKey
        p.signature = key.sign(signingBytes(p))
    }

    fun verify(p: MeshPacket): Boolean = runCatching {
        val pub = p.senderKey ?: return false
        val sig = p.signature ?: return false
        if (pub.size != 32) return false
        Ed25519Signer().run {
            init(false, Ed25519PublicKeyParameters(pub, 0))
            val msg = signingBytes(p)
            update(msg, 0, msg.size)
            verifySignature(sig)
        }
    }.getOrDefault(false)

    /** Short fingerprint, e.g. "3F2A 91C0". Same as iOS. */
    fun fingerprint(publicKey: ByteArray): String {
        val hex = MessageDigest.getInstance("SHA-256").digest(publicKey).copyOf(4).toHex().uppercase()
        return "${hex.take(4)} ${hex.takeLast(4)}"
    }
}

/** Trust-on-first-use pinning of names to signing keys. */
class KeyPins(initial: Map<String, ByteArray> = emptyMap()) {
    enum class Result { NEW, MATCH, MISMATCH }

    private val keys = initial.toMutableMap()
    val snapshot: Map<String, ByteArray> get() = keys.toMap()

    fun check(name: String, key: ByteArray): Result {
        val pinned = keys[name] ?: run { keys[name] = key; return Result.NEW }
        return if (pinned.contentEquals(key)) Result.MATCH else Result.MISMATCH
    }

    fun clear() = keys.clear()
}

fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
fun String.hexToBytes() = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
