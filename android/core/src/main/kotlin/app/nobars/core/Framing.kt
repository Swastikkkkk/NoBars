package app.nobars.core

import java.nio.ByteBuffer

/**
 * Splits sealed packets into Bluetooth LE writes and puts them back together.
 * Same format on iOS (`BLEFraming`).
 *
 * Frame: [version=1][message seq u32 big-endian][index u8][count u8][chunk...]
 */
object BleFraming {
    const val VERSION: Byte = 1
    const val HEADER = 7
    const val MAX_CHUNKS = 255

    fun split(message: ByteArray, seq: Int, maxFrame: Int): List<ByteArray> {
        val chunkSize = maxFrame - HEADER
        require(chunkSize > 0) { "frame too small" }
        val count = maxOf(1, (message.size + chunkSize - 1) / chunkSize)
        require(count <= MAX_CHUNKS) { "message too large" }
        return (0 until count).map { i ->
            val from = i * chunkSize
            val to = minOf(message.size, from + chunkSize)
            ByteBuffer.allocate(HEADER + (to - from)).apply {
                put(VERSION); putInt(seq); put(i.toByte()); put(count.toByte())
                put(message, from, to - from)
            }.array()
        }
    }

    /** Reassembles frames from one link. Returns a whole message once its last chunk lands. */
    class Reassembler {
        private class Partial(val count: Int, val startedAt: Long) { val parts = arrayOfNulls<ByteArray>(count); var have = 0 }
        private val partials = HashMap<Int, Partial>()

        fun accept(frame: ByteArray, now: Long = System.currentTimeMillis()): ByteArray? {
            if (frame.size < HEADER || frame[0] != VERSION) return null
            val b = ByteBuffer.wrap(frame)
            b.get()
            val seq = b.int
            val index = b.get().toInt() and 0xFF
            val count = b.get().toInt() and 0xFF
            if (count == 0 || index >= count) return null
            partials.entries.removeIf { now - it.value.startedAt > 30_000 }
            val p = partials.getOrPut(seq) { Partial(count, now) }
            if (p.count != count) return null
            if (p.parts[index] == null) { p.parts[index] = frame.copyOfRange(HEADER, frame.size); p.have++ }
            if (p.have < count) return null
            partials.remove(seq)
            return p.parts.fold(ByteArray(0)) { acc, part -> acc + part!! }
        }
    }
}
