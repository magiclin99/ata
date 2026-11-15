package com.ata.core

import com.ata.core.Msg.bool
import com.ata.core.Msg.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.GeneralSecurityException

/** File records shared by both channels (SPEC §7): 1 type byte ‖ content. */
object Record {
    const val FILE_START: Byte = 0x01
    const val DATA: Byte = 0x02
    const val FILE_END: Byte = 0x03
    const val FILE_RESULT: Byte = 0x04
    const val ALL_DONE: Byte = 0x05

    const val TCP_MAX_DATA = 64 * 1024
    const val RTC_MAX_DATA = 16 * 1024
    const val TCP_MAX_FRAME = 1024 * 1024

    private fun json(type: Byte, o: kotlinx.serialization.json.JsonObject): ByteArray = byteArrayOf(type) + Msg.encode(o)

    fun fileStart(name: String, size: Long) = json(FILE_START, buildJsonObject { put("name", name); put("size", size) })
    fun fileEnd(sha256Hex: String) = json(FILE_END, buildJsonObject { put("sha256", sha256Hex) })
    fun fileResult(ok: Boolean, error: String? = null) = json(FILE_RESULT, buildJsonObject {
        put("ok", ok); if (!ok) put("error", error ?: "")
    })
    fun allDone() = byteArrayOf(ALL_DONE)

    fun data(buf: ByteArray, off: Int, len: Int): ByteArray {
        val r = ByteArray(len + 1)
        r[0] = DATA
        System.arraycopy(buf, off, r, 1, len)
        return r
    }

    data class FileResult(val ok: Boolean, val error: String?)

    fun parseResult(rec: ByteArray): FileResult {
        if (rec.isEmpty() || rec[0] != FILE_RESULT) throw AtaException(ErrorCode.PROTOCOL, "expected file result record, got type ${rec.firstOrNull()}")
        val o = Msg.decode(rec.copyOfRange(1, rec.size))
        val ok = o.bool("ok") ?: throw AtaException(ErrorCode.PROTOCOL, "file result without ok")
        return FileResult(ok, if (ok) null else (o.str("error") ?: "unknown error"))
    }
}

/** A bidirectional record pipe: LAN TCP (encrypted framing) or a WebRTC data channel. */
interface RecordChannel {
    /** Largest `0x02` content this channel accepts. */
    val maxData: Int

    suspend fun send(record: ByteArray)

    /** Next record from the Mac; throws on timeout or a closed/broken channel. */
    suspend fun receive(timeoutMs: Long): ByteArray

    /** Waits until everything sent so far has left the local buffers. */
    suspend fun flush()

    /** Idempotent; may be called from any thread to unblock pending IO. */
    fun close()
}

/** TCP record framing (SPEC §7a): 4-byte BE length N ‖ AES-256-GCM(kFile) of the record. */
object TcpFraming {
    fun frame(cipher: CounterCipher, record: ByteArray): ByteArray {
        val sealed = cipher.seal(record)
        val n = sealed.size
        val out = ByteArray(4 + n)
        out[0] = (n ushr 24).toByte(); out[1] = (n ushr 16).toByte(); out[2] = (n ushr 8).toByte(); out[3] = n.toByte()
        System.arraycopy(sealed, 0, out, 4, n)
        return out
    }

    /** Reads one frame and decrypts it. Throws [EOFException] on clean close, [IOException] on bad framing/auth. */
    fun read(input: DataInputStream, cipher: CounterCipher): ByteArray {
        val n = input.readInt()
        if (n < 16 + 1 || n > Record.TCP_MAX_FRAME) throw IOException("bad TCP frame length $n")
        val sealed = ByteArray(n)
        input.readFully(sealed)
        return try {
            cipher.open(sealed)
        } catch (e: GeneralSecurityException) {
            throw IOException("TCP record failed authentication", e)
        }
    }
}

/**
 * Phone side of SPEC §7a on a connected socket. [open] sends the 16-byte sid first.
 * Blocking socket IO runs on [Dispatchers.IO]; [close] from another coroutine unblocks it.
 */
class TcpRecordChannel(private val socket: Socket, private val keys: SessionKeys) : RecordChannel {
    private val out: OutputStream = BufferedOutputStream(socket.getOutputStream(), 128 * 1024)
    private val input = DataInputStream(socket.getInputStream().buffered(16 * 1024))
    private val tx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_P2M)
    private val rx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_M2P)

    override val maxData = Record.TCP_MAX_DATA

    suspend fun open() = withContext(Dispatchers.IO) {
        out.write(keys.sid)
        out.flush()
    }

    override suspend fun send(record: ByteArray) = withContext(Dispatchers.IO) {
        out.write(TcpFraming.frame(tx, record))
    }

    override suspend fun receive(timeoutMs: Long): ByteArray = withContext(Dispatchers.IO) {
        out.flush()
        socket.soTimeout = timeoutMs.coerceIn(1, Int.MAX_VALUE.toLong()).toInt()
        TcpFraming.read(input, rx)
    }

    override suspend fun flush() = withContext(Dispatchers.IO) { out.flush() }

    override fun close() {
        runCatching { socket.close() }
    }
}

/** Dials `accept.lan` addresses in order (SPEC §7a). */
fun interface LanDialer {
    /** Returns a connected socket, or null if no address worked. */
    suspend fun dial(ips: List<String>, port: Int): Socket?
}

/**
 * Plain [Socket] dialer with a per-address timeout. [prepare] runs before `connect` and may bind the socket
 * to a network (Android: the Wi-Fi network on the same subnet); returning false skips that address.
 */
class TcpLanDialer(
    private val log: AtaLog,
    private val timeoutMs: Int = 1_500,
    private val prepare: (Socket, InetAddress) -> Boolean = { _, _ -> true },
) : LanDialer {
    override suspend fun dial(ips: List<String>, port: Int): Socket? = withContext(Dispatchers.IO) {
        for (ip in ips) {
            val addr = parseIpv4(ip)
            if (addr == null) {
                log.i("TCP skip '$ip': not an IPv4 literal"); continue
            }
            val s = Socket()
            val t0 = System.nanoTime()
            try {
                if (!prepare(s, addr)) {
                    log.i("TCP skip $ip: no matching local network"); s.close(); continue
                }
                s.tcpNoDelay = true
                s.connect(InetSocketAddress(addr, port), timeoutMs)
                log.i("TCP connected $ip:$port in ${(System.nanoTime() - t0) / 1_000_000} ms")
                return@withContext s
            } catch (e: Exception) {
                log.i("TCP connect $ip:$port failed after ${(System.nanoTime() - t0) / 1_000_000} ms: ${e.javaClass.simpleName} ${e.message}")
                runCatching { s.close() }
            }
        }
        null
    }

    companion object {
        /** Parses a dotted-quad without DNS. */
        fun parseIpv4(s: String): Inet4Address? {
            val p = s.trim().split('.')
            if (p.size != 4) return null
            val b = ByteArray(4)
            for (i in 0 until 4) {
                val v = p[i].toIntOrNull() ?: return null
                if (v !in 0..255 || p[i].isEmpty() || p[i].length > 3) return null
                b[i] = v.toByte()
            }
            return InetAddress.getByAddress(b) as Inet4Address
        }

        fun sameSubnet(a: InetAddress, b: InetAddress, prefixLen: Int): Boolean {
            val x = a.address
            val y = b.address
            if (x.size != 4 || y.size != 4 || prefixLen !in 0..32) return false
            if (prefixLen == 0) return true
            fun i(z: ByteArray) = ((z[0].toInt() and 0xff) shl 24) or ((z[1].toInt() and 0xff) shl 16) or
                ((z[2].toInt() and 0xff) shl 8) or (z[3].toInt() and 0xff)
            val mask = (-1) shl (32 - prefixLen)
            return (i(x) and mask) == (i(y) and mask)
        }
    }
}

/** Reads exactly into [buf] until full or EOF; returns bytes read. */
internal fun InputStream.readUpTo(buf: ByteArray, len: Int): Int {
    var n = 0
    while (n < len) {
        val r = read(buf, n, len - n)
        if (r < 0) break
        n += r
    }
    return n
}
