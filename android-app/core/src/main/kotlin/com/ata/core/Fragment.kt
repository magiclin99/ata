package com.ata.core

import java.io.ByteArrayOutputStream
import java.util.UUID

/** BLE GATT layout and message fragmentation (SPEC §3). */
object Ble {
    val SERVICE: UUID = UUID.fromString("8E7F0101-3A5B-4C6D-9E1F-A7A0C0FFEE01")
    val RX: UUID = UUID.fromString("8E7F0102-3A5B-4C6D-9E1F-A7A0C0FFEE01")
    val TX: UUID = UUID.fromString("8E7F0103-3A5B-4C6D-9E1F-A7A0C0FFEE01")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val FLAG_MORE: Byte = 0x00
    const val FLAG_LAST: Byte = 0x01
    const val REQUESTED_MTU = 517

    /** An attribute value can never exceed 512 bytes, even when MTU - 3 is larger. */
    const val MAX_ATTR_VALUE = 512

    /** Max fragment length (flag byte included) for a given ATT MTU: min(MTU - 3, 512). */
    fun maxFragmentLen(mtu: Int): Int = minOf(mtu - 3, MAX_ATTR_VALUE)

    /**
     * Splits a message into fragments of at most [maxFragmentLen] bytes (flag byte included).
     * An empty message yields one fragment `[0x01]`.
     */
    fun fragment(message: ByteArray, maxFragmentLen: Int): List<ByteArray> {
        require(maxFragmentLen >= 2) { "maxFragmentLen must be >= 2, was $maxFragmentLen" }
        if (message.isEmpty()) return listOf(byteArrayOf(FLAG_LAST))
        val chunk = maxFragmentLen - 1
        val out = ArrayList<ByteArray>((message.size + chunk - 1) / chunk)
        var off = 0
        while (off < message.size) {
            val n = minOf(chunk, message.size - off)
            val f = ByteArray(n + 1)
            f[0] = if (off + n == message.size) FLAG_LAST else FLAG_MORE
            System.arraycopy(message, off, f, 1, n)
            out += f
            off += n
        }
        return out
    }
}

/** Reassembles fragments of one direction. Not thread-safe; feed from one callback thread. */
class Reassembler(private val maxMessageBytes: Int = 256 * 1024) {
    private val buf = ByteArrayOutputStream()

    /** Returns the complete message on the last fragment, else null. Throws on malformed input (state is reset). */
    fun accept(fragment: ByteArray): ByteArray? {
        if (fragment.isEmpty()) {
            reset(); throw IllegalArgumentException("empty fragment")
        }
        val flag = fragment[0]
        if (flag != Ble.FLAG_MORE && flag != Ble.FLAG_LAST) {
            reset(); throw IllegalArgumentException("bad fragment flag 0x%02x".format(flag))
        }
        buf.write(fragment, 1, fragment.size - 1)
        if (buf.size() > maxMessageBytes) {
            reset(); throw IllegalArgumentException("message exceeds $maxMessageBytes bytes")
        }
        if (flag == Ble.FLAG_LAST) {
            val msg = buf.toByteArray()
            buf.reset()
            return msg
        }
        return null
    }

    fun reset() = buf.reset()
}

/**
 * SPEC §3: the Mac advertises local name `ATA-` + the first 8 hex chars of its macId. The name is only a hint
 * (it may be missing, or shortened by the advertiser), so a match must still be confirmed by `hello.id`.
 */
object NameHint {
    sealed interface Match {
        /** Exactly one paired Mac has this prefix. */
        data class Paired(val idHex: String) : Match
        /** A well-formed ATA name that matches none of our paired Macs. */
        data object Unpaired : Match
        /** Too short to tell several paired Macs apart; connect and read `hello`. */
        data object Ambiguous : Match
        /** No usable name in the scan record; connect and read `hello`. */
        data object NoHint : Match
    }

    private val PATTERN = Regex("^ATA-([0-9a-fA-F]{4,32})$")

    /** Lowercase hex prefix from a local name, or null if the name is not an ATA v2 name. */
    fun prefix(localName: String?): String? = localName?.trim()?.let { PATTERN.matchEntire(it) }?.groupValues?.get(1)?.lowercase()

    fun match(localName: String?, pairedIdHex: Collection<String>): Match {
        val p = prefix(localName) ?: return Match.NoHint
        val hits = pairedIdHex.filter { it.lowercase().startsWith(p) }
        return when (hits.size) {
            0 -> Match.Unpaired
            1 -> Match.Paired(hits[0].lowercase())
            else -> Match.Ambiguous
        }
    }

    fun nameFor(macIdHex: String) = "ATA-" + macIdHex.lowercase().take(8)
}
