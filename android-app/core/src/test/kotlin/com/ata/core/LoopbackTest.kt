package com.ata.core

import com.ata.core.Msg.bool
import com.ata.core.Msg.str
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonNull
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.InputStream
import java.util.Collections
import kotlin.random.Random

/** The real phone core (handshake, session, engine, TCP channel) against [FakeMac] over in-memory BLE and localhost TCP. */
class LoopbackTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val logLines: MutableList<String> = Collections.synchronizedList(ArrayList())
    private val log = AtaLog { logLines += it }
    private val phoneId = AtaCrypto.random(16)
    private val k = AtaCrypto.random(32)

    @After fun tearDown() {
        // No secret may ever reach the log.
        val all = logLines.joinToString("\n")
        assertFalse(all.contains(Codec.b64url(k)))
        assertFalse(all.contains(Codec.hex(k)))
    }

    private fun file(name: String, size: Int) = Random(name.hashCode()).nextBytes(size).let { bytes ->
        bytes to SourceFile(name, size.toLong()) { bytes.inputStream() }
    }

    private fun pairedMac() = FakeMac(pairedKeys = mutableMapOf(Codec.hex(phoneId) to k))

    private suspend fun connect(mac: FakeMac, key: ByteArray = k, pairing: Boolean = false): SecureSession {
        val (phone, macSide) = MemLink.pair()
        mac.start(scope, macSide)
        val hs = PhoneHandshake(phoneId, "Pixel 測試", log)
        val hello = hs.readHello(phone)
        assertArrayEquals(mac.macId, hello.macId)
        return hs.authenticate(phone, hello, key, pairing)
    }

    private fun engine(mac: FakeMac?, forceRtc: Boolean = false, rtcOpenOk: Boolean = true, timeouts: Timeouts = Timeouts()) =
        TransferEngine(log, TcpLanDialer(log), mac?.let { m -> RtcPeerFactory { FakeRtcPeer(m, rtcOpenOk) } }, forceRtc, timeouts)

    private val progress = object : TransferListener {
        val stages = ArrayList<Stage>()
        var last = 0L
        override fun onStage(stage: Stage) { stages += stage }
        override fun onProgress(fileIndex: Int, fileSent: Long, totalSent: Long) { assertTrue(totalSent >= last); last = totalSent }
    }

    @Test fun pairingThenTransferOverLan() = runBlocking {
        withTimeout(20_000) {
            val mac = FakeMac(pairingKey = k)
            val s = connect(mac, pairing = true)
            assertEquals("Test Mac", s.macName)
            s.send(Msg.bye(true, null, null))
            mac.finished.await()
            assertArrayEquals(k, mac.pairedKeys[Codec.hex(phoneId)])
            assertEquals("Pixel 測試", mac.lastPhoneName)

            // Second session with the stored key; three files including an empty one and a 64 KiB-boundary one.
            val mac2 = FakeMac(macId = mac.macId, pairedKeys = mac.pairedKeys)
            val files = listOf(file("照片.jpg", 300_000), file("empty.txt", 0), file("exact.bin", 2 * Record.TCP_MAX_DATA))
            val out = engine(mac2).run(connect(mac2), files.map { it.second }, progress)
            mac2.finished.await()
            assertTrue(out.error?.toString(), out.ok)
            assertEquals(Path.LAN, out.path)
            assertEquals(3, out.filesOk)
            assertEquals(300_000L + 2 * Record.TCP_MAX_DATA, out.bytesOk)
            assertEquals(true, mac2.sidOk)
            assertTrue(mac2.allDoneSeen)
            for ((bytes, f) in files) assertArrayEquals(bytes, mac2.received[f.name])
            assertEquals(true, mac2.bye!!.bool("ok"))
            assertEquals("lan", mac2.bye!!.str("via"))
            assertEquals(JsonNull, mac2.bye!!["error"])
            assertEquals(listOf(Stage.WaitingAccept, Stage.ConnectingLan, Stage.Sending(Path.LAN)), progress.stages)
        }
    }

    @Test fun fallsBackToRtcWhenLanUnreachable() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { lanIps = listOf("not-an-ip", "127.0.0.1"); advertisedPort = 1 } // port 1: refused
            val files = listOf(file("a.bin", 100_000), file("b.bin", 16 * 1024))
            val out = engine(mac).run(connect(mac), files.map { it.second }, progress)
            mac.finished.await()
            assertTrue(out.error?.toString(), out.ok)
            assertEquals(Path.RTC, out.path)
            for ((bytes, f) in files) assertArrayEquals(bytes, mac.received[f.name])
            assertEquals("rtc", mac.bye!!.str("via"))
            assertTrue(mac.events.contains("ble rtc_offer"))
        }
    }

    @Test fun forceRtcSkipsLan() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac()
            val out = engine(mac, forceRtc = true).run(connect(mac), listOf(file("x", 40_000).second), progress)
            mac.finished.await()
            assertTrue(out.ok)
            assertEquals(Path.RTC, out.path)
            assertNull(mac.sidOk)
        }
    }

    @Test fun noPathWhenLanAndRtcFail() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { advertisedPort = 1 }
            val out = engine(mac, rtcOpenOk = false).run(connect(mac), listOf(file("x", 10).second), progress)
            mac.finished.await()
            assertFalse(out.ok)
            assertEquals(ErrorCode.NO_PATH, out.error!!.code)
            assertEquals(false, mac.bye!!.bool("ok"))
            assertEquals(JsonNull, mac.bye!!["via"])
            assertEquals("no_path", mac.bye!!.str("error"))
        }
    }

    @Test fun rtcErrorFromMacIsNoPath() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { lanIps = emptyList(); rtcError = "no ICE" }
            val out = engine(mac).run(connect(mac), listOf(file("x", 10).second), progress)
            assertEquals(ErrorCode.NO_PATH, out.error!!.code)
        }
    }

    @Test fun badMacFromMacIsRejected() = runBlocking {
        withTimeout(10_000) {
            val mac = pairedMac().apply { tamperAuthMac = true }
            try {
                connect(mac); fail()
            } catch (e: AtaException) {
                assertEquals(ErrorCode.MAC_AUTH_FAILED, e.code)
            }
        }
    }

    @Test fun authFailReasonsMapToCodes() = runBlocking {
        withTimeout(10_000) {
            for ((reason, code) in listOf("busy" to ErrorCode.MAC_BUSY, "unknown_device" to ErrorCode.PAIRING_REMOVED,
                "bad_mac" to ErrorCode.PAIRING_REMOVED, "pairing_expired" to ErrorCode.PAIRING_EXPIRED, "bad_version" to ErrorCode.BAD_VERSION)) {
                val mac = pairedMac().apply { authFailReason = reason }
                try { connect(mac); fail(reason) } catch (e: AtaException) { assertEquals(reason, code, e.code) }
            }
            // Wrong key: the fake Mac answers bad_mac.
            try { connect(pairedMac(), key = AtaCrypto.random(32)); fail() } catch (e: AtaException) { assertEquals(ErrorCode.PAIRING_REMOVED, e.code) }
            // Pairing with an expired QR code.
            try { connect(FakeMac(), pairing = true); fail() } catch (e: AtaException) { assertEquals(ErrorCode.PAIRING_EXPIRED, e.code) }
        }
    }

    @Test fun tamperedBleMessageFromMacDropsConnection() = runBlocking {
        withTimeout(10_000) {
            val mac = pairedMac().apply { tamperBleReply = true }
            val out = engine(mac).run(connect(mac), listOf(file("x", 10).second), progress)
            assertFalse(out.ok)
            assertEquals(ErrorCode.PROTOCOL, out.error!!.code)
        }
    }

    @Test fun rejectIsReported() = runBlocking {
        withTimeout(10_000) {
            val mac = pairedMac().apply { rejectReason = "disk_full" }
            val out = engine(mac).run(connect(mac), listOf(file("x", 10).second), progress)
            assertEquals(ErrorCode.REJECTED, out.error!!.code)
            assertEquals("disk_full", out.error!!.detail)
        }
    }

    @Test fun okFalseForOneFileContinuesWithTheRest() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { failFileIndex = 1 }
            val files = listOf(file("a", 1000), file("b", 2000), file("c", 3000))
            val out = engine(mac).run(connect(mac), files.map { it.second }, progress)
            mac.finished.await()
            assertFalse(out.ok)
            assertEquals(ErrorCode.FILE_FAILED, out.error!!.code)
            assertEquals(listOf(true, false, true), out.files.map { it.ok })
            assertEquals("disk full", out.files[1].error)
            assertEquals(4000L, out.bytesOk)
            assertTrue(mac.allDoneSeen)
            assertEquals("file_failed", mac.bye!!.str("error"))
        }
    }

    @Test fun corruptedResultRecordInterrupts() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { corruptResultIndex = 1 }
            val out = engine(mac).run(connect(mac), listOf(file("a", 1000), file("b", 1000), file("c", 1000)).map { it.second }, progress)
            assertFalse(out.ok)
            assertEquals(ErrorCode.INTERRUPTED, out.error!!.code)
            assertEquals(listOf(true, false, false), out.files.map { it.ok })
        }
    }

    @Test fun droppedConnectionMidFileInterrupts() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac().apply { dropAfterBytes = 500_000 }
            val out = engine(mac, timeouts = Timeouts(fileResult = 5_000)).run(connect(mac), listOf(file("big", 4_000_000).second), progress)
            assertFalse(out.ok)
            assertEquals(ErrorCode.INTERRUPTED, out.error!!.code)
            assertEquals(Path.LAN, out.path)
            mac.finished.await()
            assertEquals(false, mac.bye!!.bool("ok"))
            assertEquals("interrupted", mac.bye!!.str("error"))
        }
    }

    @Test fun sourceShrinkingIsReportedAsUnreadable() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac()
            val lying = SourceFile("lie", 1000) { ByteArray(10).inputStream() }
            val out = engine(mac).run(connect(mac), listOf(lying), progress)
            assertEquals(ErrorCode.FILE_UNREADABLE, out.error!!.code)
        }
    }

    @Test fun cancellationSendsByeAndUnblocks() = runBlocking {
        withTimeout(20_000) {
            val mac = pairedMac()
            val slow = SourceFile("slow", 10_000_000) {
                object : InputStream() {
                    override fun read(): Int = 0
                    override fun read(b: ByteArray, off: Int, len: Int): Int { Thread.sleep(5); return minOf(len, 1000) }
                }
            }
            val session = connect(mac)
            val job = async(Dispatchers.Default) { engine(mac).run(session, listOf(slow), progress) }
            delay(500)
            job.cancelAndJoin()
            mac.finished.await()
            assertEquals("cancelled", mac.bye!!.str("error"))
        }
    }
}
