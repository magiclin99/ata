package io.github.magiclin99.ata

import android.content.Context
import com.ata.core.AtaLog
import com.ata.core.Record
import com.ata.core.RecordChannel
import com.ata.core.RtcPeer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.CandidatePairChangeEvent
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import java.io.IOException
import java.nio.ByteBuffer
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * SPEC §7b: phone is the offerer; ICE uses only the two public STUN servers (never TURN), UDP only,
 * non-trickle. The `ata-file` channel is ordered and reliable; records are binary messages.
 */
class AndroidRtcPeer(ctx: Context, private val log: AtaLog) : RtcPeer {

    companion object {
        val STUN_URLS = listOf("stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478")
        const val LABEL = "ata-file"
        const val HIGH_WATER = 1L * 1024 * 1024

        @Volatile private var factory: PeerConnectionFactory? = null

        @Synchronized
        private fun factory(ctx: Context): PeerConnectionFactory {
            factory?.let { return it }
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(ctx.applicationContext).createInitializationOptions()
            )
            return PeerConnectionFactory.builder().createPeerConnectionFactory().also { factory = it }
        }

        /** "host udp 192.168.1.5:5000" per candidate line, for logs. */
        fun candidates(sdp: String): List<String> = sdp.lineSequence().map { it.trim() }
            .filter { it.startsWith("a=candidate:") || it.startsWith("candidate:") }
            .map { line -> line.split(' ').let { f -> if (f.size >= 8) "${f[7]} ${f[2].lowercase()} ${f[4]}:${f[5]}" else line } }
            .toList()
    }

    private val gathered = CompletableDeferred<Unit>()
    private val opened = CompletableDeferred<Unit>()
    private val inbox = Channel<ByteArray>(Channel.UNLIMITED)
    private val drained = Channel<Unit>(Channel.CONFLATED)
    @Volatile private var closed = false

    private val observer = object : PeerConnection.Observer {
        override fun onSignalingChange(s: PeerConnection.SignalingState) {}
        override fun onIceConnectionChange(s: PeerConnection.IceConnectionState) {
            log.i("rtc: ICE $s")
            if (s == PeerConnection.IceConnectionState.FAILED) {
                opened.completeExceptionally(IOException("ICE failed"))
                inbox.close(IOException("ICE failed"))
            }
        }
        override fun onConnectionChange(s: PeerConnection.PeerConnectionState) {}
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(s: PeerConnection.IceGatheringState) {
            if (s == PeerConnection.IceGatheringState.COMPLETE) gathered.complete(Unit)
        }
        override fun onIceCandidate(c: IceCandidate) {}
        override fun onIceCandidatesRemoved(c: Array<out IceCandidate>) {}
        override fun onSelectedCandidatePairChanged(e: CandidatePairChangeEvent) {
            log.i("rtc: selected pair local ${candidates(e.local.sdp)} remote ${candidates(e.remote.sdp)}")
        }
        override fun onAddStream(s: MediaStream) {}
        override fun onRemoveStream(s: MediaStream) {}
        override fun onDataChannel(dc: DataChannel) {}
        override fun onRenegotiationNeeded() {}
    }

    private val pc: PeerConnection
    private val dc: DataChannel

    init {
        val cfg = PeerConnection.RTCConfiguration(STUN_URLS.map { PeerConnection.IceServer.builder(it).createIceServer() }).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
            iceTransportsType = PeerConnection.IceTransportsType.ALL
            tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.DISABLED
        }
        pc = factory(ctx).createPeerConnection(cfg, observer) ?: throw IOException("createPeerConnection returned null")
        dc = pc.createDataChannel(LABEL, DataChannel.Init().apply { ordered = true })
            ?: throw IOException("createDataChannel returned null")
        dc.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previous: Long) {
                if (!closed && dc.bufferedAmount() <= HIGH_WATER / 4) drained.trySend(Unit)
            }
            override fun onStateChange() {
                val s = dc.state()
                log.i("rtc: data channel $s")
                when (s) {
                    DataChannel.State.OPEN -> opened.complete(Unit)
                    DataChannel.State.CLOSING, DataChannel.State.CLOSED -> {
                        opened.completeExceptionally(IOException("data channel closed"))
                        inbox.close(IOException("data channel closed"))
                    }
                    else -> {}
                }
            }
            override fun onMessage(b: DataChannel.Buffer) {
                val bytes = ByteArray(b.data.remaining()).also { b.data.get(it) }
                if (!b.binary) {
                    log.i("rtc: ignoring text message (${bytes.size} B)"); return
                }
                inbox.trySend(bytes)
            }
        })
    }

    private suspend fun sdpCall(what: String, start: (SdpObserver) -> Unit): SessionDescription? =
        suspendCancellableCoroutine { c ->
            start(object : SdpObserver {
                override fun onCreateSuccess(d: SessionDescription) { if (c.isActive) c.resume(d) }
                override fun onSetSuccess() { if (c.isActive) c.resume(null) }
                override fun onCreateFailure(e: String?) { if (c.isActive) c.resumeWithException(IOException("$what: $e")) }
                override fun onSetFailure(e: String?) { if (c.isActive) c.resumeWithException(IOException("$what: $e")) }
            })
        }

    override suspend fun createOffer(gatherTimeoutMs: Long): String {
        val offer = sdpCall("createOffer") { pc.createOffer(it, MediaConstraints()) }!!
        sdpCall("setLocalDescription") { pc.setLocalDescription(it, offer) }
        if (withTimeoutOrNull(gatherTimeoutMs) { gathered.await() } == null) log.i("rtc: gathering incomplete after $gatherTimeoutMs ms; sending what we have")
        val sdp = pc.localDescription?.description ?: offer.description
        log.i("rtc: offer ${sdp.length} B, candidates ${candidates(sdp)}")
        return sdp
    }

    override suspend fun setAnswer(sdp: String) {
        log.i("rtc: answer ${sdp.length} B, candidates ${candidates(sdp)}")
        sdpCall("setRemoteDescription") { pc.setRemoteDescription(it, SessionDescription(SessionDescription.Type.ANSWER, sdp)) }
    }

    override suspend fun awaitOpen(timeoutMs: Long) {
        try {
            withTimeout(timeoutMs) { opened.await() }
        } catch (e: TimeoutCancellationException) {
            throw IOException("data channel did not open within $timeoutMs ms")
        }
    }

    override val channel: RecordChannel = object : RecordChannel {
        override val maxData = Record.RTC_MAX_DATA

        override suspend fun send(record: ByteArray) {
            while (guarded { dc.bufferedAmount() } > HIGH_WATER) {
                withTimeoutOrNull(1_000) { drained.receive() }
                val st = guarded { dc.state() }
                if (st != DataChannel.State.OPEN) throw IOException("data channel $st")
            }
            if (!guarded { dc.send(DataChannel.Buffer(ByteBuffer.wrap(record), true)) }) throw IOException("data channel send failed")
        }

        override suspend fun receive(timeoutMs: Long): ByteArray = try {
            withTimeout(timeoutMs) { inbox.receive() }
        } catch (e: TimeoutCancellationException) {
            throw IOException("no record from Mac within $timeoutMs ms")
        } catch (e: kotlinx.coroutines.channels.ClosedReceiveChannelException) {
            throw IOException("data channel closed", e)
        }

        /** Waits until libwebrtc has handed every queued byte to SCTP, so closing does not drop the tail. */
        override suspend fun flush() {
            val deadline = System.nanoTime() + 30_000_000_000L
            while (guarded { dc.bufferedAmount() } > 0) {
                val st = guarded { dc.state() }
                if (st != DataChannel.State.OPEN) throw IOException("data channel $st while flushing")
                if (System.nanoTime() > deadline) throw IOException("data channel did not drain")
                delay(20)
            }
        }

        override fun close() = this@AndroidRtcPeer.close()
    }

    /**
     * Native objects must not be touched after dispose, so every call from our coroutines goes through this lock.
     * libwebrtc callbacks never take it (close() blocks on the signaling thread, which runs those callbacks).
     */
    private inline fun <T> guarded(block: () -> T): T = synchronized(this) {
        if (closed) throw IOException("WebRTC peer closed")
        block()
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        runCatching { dc.unregisterObserver(); dc.close(); dc.dispose() }
        runCatching { pc.close(); pc.dispose() }
        inbox.close()
        log.i("rtc: closed")
    }
}
