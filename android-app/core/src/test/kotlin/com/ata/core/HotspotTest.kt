package com.ata.core

import com.ata.core.Msg.str
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.Socket
import java.util.Collections
import kotlin.random.Random

/** SPEC §7c on the phone side: the real engine against [FakeMac] with a fake hotspot that dials localhost. */
class HotspotTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val logLines: MutableList<String> = Collections.synchronizedList(ArrayList())
    private val log = AtaLog { logLines += it }
    private val phoneId = AtaCrypto.random(16)
    private val k = AtaCrypto.random(32)
    private val psk = "Ph0ne-hotspot-pw"

    @After fun noSecretsInTheLog() {
        val all = logLines.joinToString("\n")
        assertFalse("hotspot password logged", all.contains(psk))
        assertFalse(all.contains(Codec.b64url(k)))
    }

    private class FakeHotspot(
        private val log: AtaLog, private val psk: String, private val failStart: Boolean = false,
        /** The Mac "does not answer" this many dials first (a firewall prompt waiting for a click); -1 = never answers. */
        private var unreachableDials: Int = 0,
    ) : HotspotProvider {
        var started = 0
        var stopped = 0
        override suspend fun start(timeoutMs: Long): HotspotCredentials {
            started++
            if (failStart) throw IOException("incompatible mode")
            return HotspotCredentials("Phone-AB12", psk)
        }
        override suspend fun dial(ips: List<String>, port: Int): Socket? {
            if (unreachableDials < 0) return null
            if (unreachableDials > 0) { unreachableDials--; return null }
            return TcpLanDialer(log).dial(ips, port)
        }
        override fun stop() { stopped++ }
    }

    private fun file(name: String, size: Int) = Random(name.hashCode()).nextBytes(size).let { bytes ->
        bytes to SourceFile(name, size.toLong()) { bytes.inputStream() }
    }

    private suspend fun connect(mac: FakeMac): SecureSession {
        val (phone, macSide) = MemLink.pair()
        mac.start(scope, macSide)
        val hs = PhoneHandshake(phoneId, "Pixel 測試", log)
        return hs.authenticate(phone, hs.readHello(phone), k, false)
    }

    private fun pairedMac() = FakeMac(pairedKeys = mutableMapOf(Codec.hex(phoneId) to k))

    private val listener = object : TransferListener {
        val stages = ArrayList<Stage>()
        override fun onStage(stage: Stage) { stages += stage }
    }

    @Test fun sendsOverTheHotspotWhenChosen() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true; lanIps = listOf("192.0.2.1") }
            val h = FakeHotspot(log, psk)
            val (bytes, src) = file("photo.jpg", 200_000)
            val out = TransferEngine(log, TcpLanDialer(log), null, hotspot = h, viaHotspot = true).run(connect(mac), listOf(src), listener)
            mac.finished.await()
            assertTrue(out.error?.toString(), out.ok)
            assertEquals(Path.HOTSPOT, out.path)
            assertArrayEquals(bytes, mac.received["photo.jpg"])
            assertEquals("hotspot", mac.bye!!.str("via"))
            assertEquals(listOf(Msg.CAP_HOTSPOT), mac.sendCaps)
            assertEquals("Phone-AB12", mac.hotspotMsg!!.str("ssid"))
            assertEquals(psk, mac.hotspotMsg!!.str("psk"))
            assertTrue(Stage.ConnectingHotspot in listener.stages)
            assertFalse("LAN is not tried when the user chose the hotspot", Stage.ConnectingLan in listener.stages)
            assertEquals(1, h.started); assertEquals(1, h.stopped)
        }
    }

    @Test fun noPathReportsThatTheHotspotIsPossible() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true; advertisedPort = 1 }
            val h = FakeHotspot(log, psk)
            val out = TransferEngine(log, TcpLanDialer(log), RtcPeerFactory { FakeRtcPeer(mac, openOk = false) }, hotspot = h)
                .run(connect(mac), listOf(file("x", 10).second), listener)
            mac.finished.await()
            assertEquals(ErrorCode.NO_PATH, out.error!!.code)
            assertTrue(out.hotspotPossible)
            assertEquals("no hotspot unless the user chooses it", 0, h.started)
            assertNull(mac.hotspotMsg)
        }
    }

    @Test fun oldMacNeverOffersTheHotspot() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { advertisedPort = 1 }   // hotspotSupported = false: an older Mac
            val h = FakeHotspot(log, psk)
            val out = TransferEngine(log, TcpLanDialer(log), RtcPeerFactory { FakeRtcPeer(mac, openOk = false) }, hotspot = h)
                .run(connect(mac), listOf(file("x", 10).second), listener)
            mac.finished.await()
            assertEquals(ErrorCode.NO_PATH, out.error!!.code)
            assertFalse(out.hotspotPossible)

            val mac2 = pairedMac()
            val out2 = TransferEngine(log, TcpLanDialer(log), null, hotspot = h, viaHotspot = true)
                .run(connect(mac2), listOf(file("x", 10).second), listener)
            mac2.finished.await()
            assertEquals(ErrorCode.NO_PATH, out2.error!!.code)
            assertEquals(0, h.started)
        }
    }

    @Test fun phoneWithoutHotspotDoesNotOfferIt() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true }
            val out = TransferEngine(log, TcpLanDialer(log), null).run(connect(mac), listOf(file("x", 10).second), listener)
            mac.finished.await()
            assertTrue(out.ok)
            assertEquals(emptyList<String>(), mac.sendCaps)
            assertFalse(out.hotspotPossible)
        }
    }

    @Test fun macCannotJoin() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true; hotspotError = "not_found" }
            val h = FakeHotspot(log, psk)
            val out = TransferEngine(log, TcpLanDialer(log), null, hotspot = h, viaHotspot = true)
                .run(connect(mac), listOf(file("x", 10).second), listener)
            mac.finished.await()
            assertEquals(ErrorCode.HOTSPOT_FAILED, out.error!!.code)
            assertEquals("hotspot_failed", mac.bye!!.str("error"))
            assertEquals(1, h.stopped)
        }
    }

    @Test fun hotspotThatWillNotStart() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true }
            val h = FakeHotspot(log, psk, failStart = true)
            val out = TransferEngine(log, TcpLanDialer(log), null, hotspot = h, viaHotspot = true)
                .run(connect(mac), listOf(file("x", 10).second), listener)
            mac.finished.await()
            assertEquals(ErrorCode.HOTSPOT_FAILED, out.error!!.code)
            assertNull("nothing was sent to the Mac", mac.hotspotMsg)
            assertEquals(1, h.stopped)
        }
    }

    @Test fun keepsTryingWhileTheMacAsksAndShowsTheHint() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true }
            val h = FakeHotspot(log, psk, unreachableDials = 4)   // ~2 s of "no answer"
            val (bytes, src) = file("a.bin", 5_000)
            val out = TransferEngine(log, TcpLanDialer(log), null, timeouts = Timeouts(hotspotHintAfter = 300), hotspot = h, viaHotspot = true)
                .run(connect(mac), listOf(src), listener)
            mac.finished.await()
            assertTrue(out.error?.toString(), out.ok)
            assertArrayEquals(bytes, mac.received["a.bin"])
            assertTrue(Stage.WaitingForMacOnHotspot in listener.stages)
        }
    }

    @Test fun macJoinedButUnreachableIsItsOwnError() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true }
            val h = FakeHotspot(log, psk, unreachableDials = -1)
            val out = TransferEngine(log, TcpLanDialer(log), null, timeouts = Timeouts(hotspotDial = 1_000, hotspotHintAfter = 300), hotspot = h, viaHotspot = true)
                .run(connect(mac), listOf(file("x", 10).second), listener)
            mac.finished.await()
            assertEquals(ErrorCode.HOTSPOT_UNREACHABLE, out.error!!.code)
            assertEquals("hotspot_unreachable", mac.bye!!.str("error"))
            assertEquals(1, h.stopped)
        }
    }

    @Test fun choosingTheHotspotWhileWebRtcTriesEndsTheRunAtOnce() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { hotspotSupported = true; advertisedPort = 1 }
            val hanging = object : RtcPeer {
                override suspend fun createOffer(gatherTimeoutMs: Long) = "v=0 fake-offer"
                override suspend fun setAnswer(sdp: String) {}
                override suspend fun awaitOpen(timeoutMs: Long) { awaitCancellation() }
                override val channel: RecordChannel get() = error("not open")
                override fun close() {}
            }
            var offered = false
            val l = object : TransferListener {
                override fun onHotspotPossible() { offered = true }
            }
            val engine = TransferEngine(log, TcpLanDialer(log), RtcPeerFactory { hanging }, hotspot = FakeHotspot(log, psk))
            val session = connect(mac)
            val skipper = scope.launch { while (!offered) delay(20); delay(300); engine.skipToHotspot() }
            val t0 = System.nanoTime()
            val out = engine.run(session, listOf(file("x", 10).second), l)
            mac.finished.await()
            skipper.join()
            assertEquals(ErrorCode.NO_PATH, out.error!!.code)
            assertTrue(out.hotspotPossible)
            assertEquals("no_path", mac.bye!!.str("error"))
            assertTrue("ended promptly", (System.nanoTime() - t0) / 1_000_000 < 5_000)
        }
    }

    @Test fun summaryRedactsThePassword() {
        val line = Msg.summary(Msg.hotspot("Phone-AB12", psk))
        assertFalse(line.contains(psk))
        assertTrue(line.contains("Phone-AB12"))
        assertFalse(HotspotCredentials("a", psk).toString().contains(psk))
    }
}
