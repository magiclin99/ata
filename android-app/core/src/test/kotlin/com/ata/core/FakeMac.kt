package com.ata.core

import com.ata.core.Msg.bool
import com.ata.core.Msg.long
import com.ata.core.Msg.str
import com.ata.core.Msg.type
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest

/** In-memory BLE link: each [send] is fragmented at [mtu] and reassembled on the other side, like GATT. */
class MemLink(private val outFrags: Channel<ByteArray>, private val inFrags: Channel<ByteArray>, private val mtu: Int) : MessageLink {
    private val reassembler = Reassembler()
    var sentMessages = 0

    override suspend fun send(message: ByteArray) {
        sentMessages++
        try {
            for (f in Ble.fragment(message, Ble.maxFragmentLen(mtu))) outFrags.send(f)
        } catch (e: Exception) {
            throw LinkClosedException("closed", e)
        }
    }

    override suspend fun receive(): ByteArray {
        while (true) {
            val f = try {
                inFrags.receive()
            } catch (e: Exception) {
                throw LinkClosedException("closed", e)
            }
            reassembler.accept(f)?.let { return it }
        }
    }

    override fun close() {
        outFrags.close(); inFrags.cancel()
    }

    companion object {
        fun pair(mtu: Int = 185): Pair<MemLink, MemLink> {
            val a = Channel<ByteArray>(Channel.UNLIMITED)
            val b = Channel<ByteArray>(Channel.UNLIMITED)
            return MemLink(a, b, mtu) to MemLink(b, a, mtu)
        }
    }
}

/** In-memory data channel: records are passed through unchanged (SPEC §7b). */
class MemRecordChannel(private val out: Channel<ByteArray>, private val inbox: Channel<ByteArray>) : RecordChannel {
    override val maxData = Record.RTC_MAX_DATA
    override suspend fun send(record: ByteArray) {
        require(record.size <= maxData + 1) { "data channel record too large: ${record.size}" }
        try { out.send(record) } catch (e: Exception) { throw IOException("dc closed", e) }
    }
    override suspend fun receive(timeoutMs: Long): ByteArray = try {
        withTimeout(timeoutMs) { inbox.receive() }
    } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
        throw IOException("dc receive timeout")
    } catch (e: Exception) {
        throw IOException("dc closed", e)
    }
    override suspend fun flush() {}
    override fun close() { out.close(); inbox.cancel() }
}

/** Phone-side fake WebRTC peer wired to a [FakeMac]. */
class FakeRtcPeer(private val mac: FakeMac, private val openOk: Boolean = true) : RtcPeer {
    private val toMac = Channel<ByteArray>(Channel.UNLIMITED)
    private val toPhone = Channel<ByteArray>(Channel.UNLIMITED)
    override val channel = MemRecordChannel(toMac, toPhone)
    var answered: String? = null

    override suspend fun createOffer(gatherTimeoutMs: Long) = "v=0 fake-offer"
    override suspend fun setAnswer(sdp: String) { answered = sdp }
    override suspend fun awaitOpen(timeoutMs: Long) {
        if (!openOk) throw IOException("ICE failed")
        mac.attachRtc(MemRecordChannel(toPhone, toMac))
    }
    override fun close() = channel.close()
}

/**
 * A test-side Mac receiver implementing SPEC §4–§7 independently of the phone code paths
 * (it shares only the crypto primitives that the vector tests pin down).
 */
class FakeMac(
    val macId: ByteArray = AtaCrypto.random(16),
    val name: String = "Test Mac",
    val pairedKeys: MutableMap<String, ByteArray> = HashMap(),
    var pairingKey: ByteArray? = null,
) {
    // ---- behaviour knobs
    var tamperAuthMac = false
    var authFailReason: String? = null
    var rejectReason: String? = null
    var lanIps: List<String>? = null
    var advertisedPort: Int? = null
    var failFileIndex = -1
    var corruptResultIndex = -1
    var dropAfterBytes = -1L
    var tamperBleReply = false
    var rtcError: String? = null

    // ---- observations
    val received = LinkedHashMap<String, ByteArray>()
    val events = ArrayList<String>()
    var bye: JsonObject? = null
    var lastPhoneName: String? = null
    var sidOk: Boolean? = null
    var allDoneSeen = false
    val finished = CompletableDeferred<Unit>()

    private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val rtcAttached = CompletableDeferred<RecordChannel>()
    private lateinit var keys: SessionKeys

    fun attachRtc(ch: RecordChannel) { rtcAttached.complete(ch) }

    fun start(scope: CoroutineScope, link: MessageLink): Job = scope.launch(Dispatchers.Default) {
        try {
            serve(link)
        } catch (e: Exception) {
            events += "mac error: ${e.javaClass.simpleName} ${e.message}"
        } finally {
            runCatching { server.close() }
            finished.complete(Unit)
        }
    }

    private suspend fun serve(link: MessageLink) {
        val nonceM = AtaCrypto.random(16)
        link.send(Msg.encode(Msg.hello(macId, nonceM)))
        val auth = Msg.decode(link.receive())
        check(auth.type == "auth")
        val phoneId = Codec.unhex(auth.str("id")!!)
        val nonceP = Codec.unb64(auth.str("n")!!)
        lastPhoneName = auth.str("name")
        val pairing = auth.bool("pairing") == true
        authFailReason?.let {
            link.send(Msg.encode(Msg.authFail(it))); link.close(); return
        }
        val k = if (pairing) pairingKey else pairedKeys[Codec.hex(phoneId)]
        if (k == null) {
            link.send(Msg.encode(Msg.authFail(if (pairing) "pairing_expired" else "unknown_device"))); link.close(); return
        }
        val expect = Handshake.phoneMac(k, macId, phoneId, nonceM, nonceP)
        if (!AtaCrypto.constantTimeEquals(expect, Codec.unb64(auth.str("mac")!!))) {
            link.send(Msg.encode(Msg.authFail("bad_mac"))); link.close(); return
        }
        val okMac = Handshake.macMac(k, macId, phoneId, nonceM, nonceP).also { if (tamperAuthMac) it[0] = (it[0].toInt() xor 1).toByte() }
        link.send(Msg.encode(Msg.authOk(name, okMac)))
        if (pairing) {
            pairedKeys[Codec.hex(phoneId)] = k; pairingKey = null
        }
        keys = Handshake.deriveKeys(k, nonceM, nonceP)
        val rx = CounterCipher(keys.kP2M, 0)
        val tx = CounterCipher(keys.kM2P, 0)
        suspend fun sendMsg(o: JsonObject) {
            val sealed = tx.seal(Msg.encode(o))
            if (tamperBleReply) sealed[sealed.size - 1] = (sealed[sealed.size - 1].toInt() xor 1).toByte()
            link.send(sealed)
        }

        var transfer: Job? = null
        while (true) {
            val m = try {
                Msg.decode(rx.open(link.receive()))
            } catch (e: LinkClosedException) {
                events += "ble closed"; break
            }
            events += "ble ${m.type}"
            when (m.type) {
                "send" -> {
                    val files = m["files"]!!.jsonArray.map { it.jsonObject }
                    check(m.long("total") == files.sumOf { it.long("size")!! })
                    if (rejectReason != null) {
                        sendMsg(Msg.reject(rejectReason!!)); continue
                    }
                    sendMsg(Msg.accept(advertisedPort ?: server.localPort, lanIps ?: listOf("127.0.0.1")))
                    transfer = CoroutineScope(Dispatchers.IO).launch {
                        val sock = withContext(Dispatchers.IO) { server.accept() }
                        try {
                            receiveTcp(sock)
                        } catch (e: Exception) {
                            events += "tcp error: ${e.javaClass.simpleName} ${e.message}"
                        } finally {
                            sock.close()
                        }
                    }
                }
                "rtc_offer" -> {
                    transfer?.cancel(); runCatching { server.close() }
                    if (rtcError != null) {
                        sendMsg(Msg.rtcError(rtcError!!)); continue
                    }
                    sendMsg(Msg.rtcAnswer("v=0 fake-answer"))
                    transfer = CoroutineScope(Dispatchers.IO).launch {
                        val ch = rtcAttached.await()
                        try {
                            receiveRecords({ ch.receive(10_000) }, { ch.send(it) })
                        } catch (e: Exception) {
                            events += "rtc error: ${e.message}"
                        }
                    }
                }
                "bye" -> {
                    bye = m
                    if (m.bool("ok") == true) transfer?.join() else transfer?.cancel()
                    break
                }
            }
        }
        link.close()
    }

    private suspend fun receiveTcp(sock: Socket) {
        val ins = DataInputStream(sock.getInputStream().buffered())
        val out = sock.getOutputStream()
        val sid = ByteArray(16).also { ins.readFully(it) }
        sidOk = sid.contentEquals(keys.sid)
        if (sidOk != true) return
        val rx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_P2M)
        val tx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_M2P)
        var index = 0
        receiveRecords(
            read = { TcpFraming.read(ins, rx) },
            write = { rec ->
                val framed = TcpFraming.frame(tx, rec)
                if (index++ == corruptResultIndex) framed[framed.size - 3] = (framed[framed.size - 3].toInt() xor 0x40).toByte()
                out.write(framed); out.flush()
            },
            onBytes = { total -> if (dropAfterBytes in 0..total) { sock.close(); throw IOException("dropped by test") } },
        )
    }

    private suspend fun receiveRecords(read: suspend () -> ByteArray, write: suspend (ByteArray) -> Unit, onBytes: (Long) -> Unit = {}) {
        var current: String? = null
        var size = 0L
        var buf = ByteArrayOutputStream()
        var md = MessageDigest.getInstance("SHA-256")
        var fileIndex = 0
        var total = 0L
        while (true) {
            val rec = read()
            when (rec[0]) {
                Record.FILE_START -> {
                    val o = Msg.decode(rec.copyOfRange(1, rec.size))
                    current = o.str("name"); size = o.long("size")!!
                    buf = ByteArrayOutputStream(); md = MessageDigest.getInstance("SHA-256")
                }
                Record.DATA -> {
                    check(current != null)
                    buf.write(rec, 1, rec.size - 1); md.update(rec, 1, rec.size - 1)
                    total += rec.size - 1
                    onBytes(total)
                }
                Record.FILE_END -> {
                    val sha = Msg.decode(rec.copyOfRange(1, rec.size)).str("sha256")
                    val ok = sha == Codec.hex(md.digest()) && buf.size().toLong() == size && fileIndex != failFileIndex
                    if (ok) received[current!!] = buf.toByteArray()
                    write(if (ok) Record.fileResult(true) else Record.fileResult(false, if (fileIndex == failFileIndex) "disk full" else "sha256 mismatch"))
                    fileIndex++; current = null
                }
                Record.ALL_DONE -> {
                    allDoneSeen = true; return
                }
                else -> error("unknown record ${rec[0]}")
            }
        }
    }
}
