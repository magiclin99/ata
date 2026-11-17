package com.ata.core

import com.ata.core.Msg.bool
import com.ata.core.Msg.int
import com.ata.core.Msg.str
import com.ata.core.Msg.strList
import com.ata.core.Msg.type
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/** A file to send. [size] is declared up front in `send` and `0x01`; the stream must yield exactly that many bytes. */
class SourceFile(val name: String, val size: Long, val open: () -> InputStream)

enum class Path(val wire: String) { LAN("lan"), RTC("rtc"), HOTSPOT("hotspot") }

sealed interface Stage {
    data object WaitingAccept : Stage
    data object ConnectingLan : Stage
    data object ConnectingRtc : Stage
    /** SPEC §7c: starting this phone's temporary hotspot and waiting for the Mac to join it. */
    data object ConnectingHotspot : Stage
    data class Sending(val path: Path) : Stage
}

interface TransferListener {
    fun onStage(stage: Stage) {}

    /** Called after every data record; [fileSent] is bytes of file [fileIndex], [totalSent] across all files. */
    fun onProgress(fileIndex: Int, fileSent: Long, totalSent: Long) {}

    fun onFileDone(fileIndex: Int, ok: Boolean, error: String?) {}
}

data class FileOutcome(val name: String, val size: Long, val ok: Boolean, val error: String?)

data class TransferOutcome(
    val ok: Boolean,
    val path: Path?,
    val files: List<FileOutcome>,
    val error: AtaException?,
    /** The Mac said it can join this phone's temporary hotspot (`accept.hotspot`) and this phone can open one. */
    val hotspotPossible: Boolean = false,
) {
    val filesOk: Int get() = files.count { it.ok }
    val bytesOk: Long get() = files.filter { it.ok }.sumOf { it.size }
}

/** WebRTC peer (phone = offerer, non-trickle). Android implements this with libwebrtc; tests with a fake. */
interface RtcPeer {
    /** createOffer + setLocalDescription, waits for ICE gathering (at most [gatherTimeoutMs]); returns the full SDP. */
    suspend fun createOffer(gatherTimeoutMs: Long): String

    suspend fun setAnswer(sdp: String)

    /** Throws if the data channel does not open within [timeoutMs]. */
    suspend fun awaitOpen(timeoutMs: Long)

    /** The `ata-file` data channel as a record pipe (one binary message per record, back-pressured). */
    val channel: RecordChannel

    fun close()
}

fun interface RtcPeerFactory {
    fun create(): RtcPeer
}

class HotspotCredentials(val ssid: String, val psk: String) {
    override fun toString() = "HotspotCredentials(ssid=$ssid, psk=<redacted>)"
}

/** SPEC §7c: this phone's temporary hotspot. Android implements it with LocalOnlyHotspot; tests with a fake. */
interface HotspotProvider {
    /** Starts the hotspot (at most [timeoutMs]) and returns its name and password. Throws if it cannot. */
    suspend fun start(timeoutMs: Long): HotspotCredentials

    /** Connects to the Mac on the hotspot network; null if no address answered. */
    suspend fun dial(ips: List<String>, port: Int): java.net.Socket?

    /** Closes the hotspot. Safe to call more than once, and when [start] failed. */
    fun stop()
}

class Timeouts(
    val accept: Long = 60_000,
    val rtcAnswer: Long = 30_000,
    val rtcGather: Long = 5_000,
    val rtcOpen: Long = 20_000,
    val fileResult: Long = 60_000,
    val hotspotStart: Long = 15_000,
    /** The Mac scans up to 30 s and waits up to 15 s for an address (SPEC §7c). */
    val hotspotReady: Long = 60_000,
    val hotspotDial: Long = 15_000,
)

/**
 * Runs SPEC §6–§7 over an authenticated [SecureSession]: `send` → `accept` → LAN TCP, else WebRTC → records → `bye`.
 * Never throws for protocol/transport failures: they are reported in [TransferOutcome.error].
 * Rethrows [CancellationException] after a best-effort `bye` with error "cancelled".
 */
class TransferEngine(
    private val log: AtaLog,
    private val lan: LanDialer,
    private val rtc: RtcPeerFactory?,
    private val forceRtc: Boolean = false,
    private val timeouts: Timeouts = Timeouts(),
    /** Null when this phone cannot open a temporary hotspot; then `send` does not offer it. */
    private val hotspot: HotspotProvider? = null,
    /** The user chose "send using this phone's Wi-Fi": skip LAN and WebRTC and go straight to the hotspot. */
    private val viaHotspot: Boolean = false,
) {
    suspend fun run(session: SecureSession, files: List<SourceFile>, listener: TransferListener): TransferOutcome {
        val outcomes = files.map { FileOutcome(it.name, it.size, ok = false, error = null) }.toMutableList()
        var path: Path? = null
        var channel: RecordChannel? = null
        var peer: RtcPeer? = null
        var finishedNormally = false
        var hotspotPossible = false
        var hotspotStarted = false

        fun outcome(error: AtaException?) =
            TransferOutcome(error == null && outcomes.all { it.ok }, path, outcomes.toList(), error, hotspotPossible)

        return try {
            coroutineScope {
                // On cancellation, close transports so blocked socket IO returns promptly.
                val watchdog = launch {
                    try {
                        awaitCancellation()
                    } finally {
                        if (!finishedNormally) {
                            channel?.close(); peer?.close()
                        }
                    }
                }
                val result = try {
                    val caps = if (hotspot != null) listOf(Msg.CAP_HOTSPOT) else emptyList()
                    session.send(Msg.send(files.map { Msg.FileEntry(it.name, it.size) }, caps))
                    listener.onStage(Stage.WaitingAccept)
                    val reply = awaitType(session, setOf("accept", "reject"), timeouts.accept)
                    if (reply.type == "reject") {
                        throw AtaException(ErrorCode.REJECTED, reply.str("reason") ?: "")
                    }
                    val port = reply.int("tcpPort") ?: 0
                    val ips = reply.strList("lan")
                    hotspotPossible = hotspot != null && reply.bool("hotspot") == true && port in 1..65535

                    if (viaHotspot) {
                        val h = hotspot
                        if (h == null || !hotspotPossible) throw AtaException(ErrorCode.NO_PATH, "the Mac cannot join this phone's hotspot")
                        listener.onStage(Stage.ConnectingHotspot)
                        hotspotStarted = true
                        val sock = connectHotspot(session, h, port)
                        val ch = TcpRecordChannel(sock, session.keys)
                        channel = ch
                        try {
                            ch.open()
                        } catch (e: IOException) {
                            throw AtaException(ErrorCode.HOTSPOT_FAILED, "TCP sid write failed: ${e.message}", e)
                        }
                        path = Path.HOTSPOT
                    } else if (forceRtc) log.i("LAN skipped (debugForceRtc)")
                    else if (ips.isEmpty() || port !in 1..65535) log.i("LAN skipped: accept has no usable lan/tcpPort")
                    else {
                        listener.onStage(Stage.ConnectingLan)
                        val sock = lan.dial(ips, port)
                        if (sock != null) {
                            val ch = TcpRecordChannel(sock, session.keys)
                            channel = ch
                            try {
                                ch.open()
                                path = Path.LAN
                            } catch (e: IOException) {
                                log.i("TCP sid write failed: ${e.message}")
                                ch.close(); channel = null
                            }
                        }
                    }

                    if (channel == null) {
                        val factory = rtc ?: throw AtaException(ErrorCode.NO_PATH, "LAN failed and WebRTC unavailable")
                        listener.onStage(Stage.ConnectingRtc)
                        val p = try {
                            factory.create()
                        } catch (e: Exception) {
                            throw AtaException(ErrorCode.NO_PATH, "WebRTC unavailable: ${e.message}", e)
                        }
                        peer = p
                        connectRtc(session, p)
                        channel = p.channel
                        path = Path.RTC
                    }

                    listener.onStage(Stage.Sending(path!!))
                    log.i("path: ${path!!.wire}")
                    sendAll(channel!!, files, outcomes, listener)
                    withContext(Dispatchers.IO) {
                        channel!!.send(Record.allDone())
                        channel!!.flush()
                    }
                    log.i("records: all done sent")
                    outcome(if (outcomes.all { it.ok }) null else AtaException(ErrorCode.FILE_FAILED, outcomes.filter { !it.ok }.joinToString { "${it.name}: ${it.error}" }))
                } catch (e: AtaException) {
                    outcome(e)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    outcome(AtaException(ErrorCode.INTERRUPTED, "${e.javaClass.simpleName}: ${e.message}", e))
                }
                finishedNormally = true
                watchdog.cancel()
                result
            }.also { r ->
                runCatching {
                    session.send(Msg.bye(r.ok, r.path?.wire, r.error?.code?.name?.lowercase()))
                }.onFailure { log.i("bye not delivered: ${it.message}") }
            }
        } catch (e: CancellationException) {
            withContext(NonCancellable) {
                withTimeoutOrNull(2_000) {
                    runCatching { session.send(Msg.bye(false, path?.wire, "cancelled")) }
                }
            }
            throw e
        } finally {
            channel?.close()
            peer?.close()
            // After `bye`: the Mac goes back to its own Wi-Fi once the session ends, then the hotspot can go.
            if (hotspotStarted) hotspot?.stop()
        }
    }

    /** SPEC §7c steps 2–4. Returns a socket to the Mac on the hotspot network. */
    private suspend fun connectHotspot(session: SecureSession, h: HotspotProvider, port: Int): java.net.Socket {
        val creds = try {
            h.start(timeouts.hotspotStart)
        } catch (e: CancellationException) {
            throw e
        } catch (e: AtaException) {
            throw e
        } catch (e: Exception) {
            throw AtaException(ErrorCode.HOTSPOT_FAILED, "hotspot did not start: ${e.javaClass.simpleName} ${e.message}", e)
        }
        log.i("hotspot started")
        session.send(Msg.hotspot(creds.ssid, creds.psk))
        val r = awaitType(session, setOf("hotspot_ready", "hotspot_error"), timeouts.hotspotReady)
        if (r.type == "hotspot_error") throw AtaException(ErrorCode.HOTSPOT_FAILED, "Mac could not join: ${r.str("error")}")
        val ips = r.strList("lan")
        val p = r.int("tcpPort")?.takeIf { it in 1..65535 } ?: port
        val deadline = System.nanoTime() + timeouts.hotspotDial * 1_000_000
        while (true) {
            h.dial(ips, p)?.let { return it }
            if (System.nanoTime() > deadline) throw AtaException(ErrorCode.HOTSPOT_FAILED, "could not reach the Mac on the hotspot")
            delay(500)
        }
    }

    private suspend fun connectRtc(session: SecureSession, p: RtcPeer) {
        val offer = try {
            p.createOffer(timeouts.rtcGather)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw AtaException(ErrorCode.NO_PATH, "WebRTC offer failed: ${e.message}", e)
        }
        session.send(Msg.rtcOffer(offer))
        val r = awaitType(session, setOf("rtc_answer", "rtc_error"), timeouts.rtcAnswer)
        if (r.type == "rtc_error") throw AtaException(ErrorCode.NO_PATH, "Mac WebRTC error: ${r.str("error")}")
        val sdp = r.str("sdp") ?: throw AtaException(ErrorCode.PROTOCOL, "rtc_answer without sdp")
        try {
            p.setAnswer(sdp)
            p.awaitOpen(timeouts.rtcOpen)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw AtaException(ErrorCode.NO_PATH, "WebRTC did not connect: ${e.message}", e)
        }
        log.i("WebRTC data channel open")
    }

    /** Waits for a message whose `t` is in [types]; other types are logged and skipped. */
    private suspend fun awaitType(session: SecureSession, types: Set<String>, timeoutMs: Long): JsonObject {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (true) {
            val left = (deadline - System.nanoTime()) / 1_000_000
            if (left <= 0) throw AtaException(ErrorCode.CONNECTION_LOST, "Mac did not answer (${types.joinToString("/")})")
            val m = session.receive(left)
            if (m.type in types) return m
            log.i("ignored unexpected '${m.type}' while waiting for ${types.joinToString("/")}")
        }
    }

    private suspend fun sendAll(ch: RecordChannel, files: List<SourceFile>, outcomes: MutableList<FileOutcome>, listener: TransferListener) {
        var totalSent = 0L
        val buf = ByteArray(ch.maxData)
        for ((i, f) in files.withIndex()) {
            log.i("file ${i + 1}/${files.size}: start size=${f.size}")
            val t0 = System.nanoTime()
            val md = MessageDigest.getInstance("SHA-256")
            try {
                ch.send(Record.fileStart(f.name, f.size))
                val input = try {
                    withContext(Dispatchers.IO) { f.open() }
                } catch (e: Exception) {
                    throw AtaException(ErrorCode.FILE_UNREADABLE, "cannot open ${f.name}: ${e.message}", e)
                }
                var sent = 0L
                input.use { ins ->
                    while (true) {
                        val n = try {
                            withContext(Dispatchers.IO) { ins.readUpTo(buf, buf.size) }
                        } catch (e: IOException) {
                            throw AtaException(ErrorCode.FILE_UNREADABLE, "read ${f.name}: ${e.message}", e)
                        }
                        if (n == 0) break
                        if (sent + n > f.size) throw AtaException(ErrorCode.FILE_UNREADABLE, "${f.name} grew while sending (> ${f.size} B)")
                        md.update(buf, 0, n)
                        ch.send(Record.data(buf, 0, n))
                        sent += n
                        totalSent += n
                        listener.onProgress(i, sent, totalSent)
                        if (n < buf.size) break
                    }
                }
                if (sent != f.size) throw AtaException(ErrorCode.FILE_UNREADABLE, "${f.name} shrank while sending ($sent of ${f.size} B)")
                val sha = Codec.hex(md.digest())
                ch.send(Record.fileEnd(sha))
                val res = Record.parseResult(ch.receive(timeouts.fileResult))
                outcomes[i] = FileOutcome(f.name, f.size, res.ok, res.error)
                val ms = (System.nanoTime() - t0) / 1_000_000
                log.i("file ${i + 1}/${files.size}: result ok=${res.ok}${res.error?.let { " error=$it" } ?: ""} sha256=$sha in $ms ms")
                listener.onFileDone(i, res.ok, res.error)
            } catch (e: AtaException) {
                outcomes[i] = FileOutcome(f.name, f.size, false, e.detail)
                if (e.code == ErrorCode.PROTOCOL) throw AtaException(ErrorCode.INTERRUPTED, e.detail, e)
                throw e
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                outcomes[i] = FileOutcome(f.name, f.size, false, e.message)
                throw AtaException(ErrorCode.INTERRUPTED, "${e.javaClass.simpleName}: ${e.message}", e)
            }
        }
    }
}
