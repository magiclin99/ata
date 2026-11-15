package com.ata.core

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress

class FragmentTest {
    @Test fun maxFragmentLen() {
        assertEquals(20, Ble.maxFragmentLen(23))
        assertEquals(512, Ble.maxFragmentLen(517))
        assertEquals(182, Ble.maxFragmentLen(185))
    }

    @Test fun emptyMessageIsOneLastFragment() {
        val f = Ble.fragment(ByteArray(0), 20)
        assertEquals(1, f.size)
        assertArrayEquals(byteArrayOf(1), f[0])
        assertArrayEquals(ByteArray(0), Reassembler().accept(f[0]))
    }

    @Test fun exactMultipleAndRemainder() {
        for (len in listOf(1, 18, 19, 20, 38, 39, 40, 1000)) {
            val msg = ByteArray(len) { (it * 7).toByte() }
            val frags = Ble.fragment(msg, 20)
            assertEquals((len + 18) / 19, frags.size)
            frags.forEachIndexed { i, f ->
                assertTrue(f.size <= 20)
                assertEquals(if (i == frags.lastIndex) Ble.FLAG_LAST else Ble.FLAG_MORE, f[0])
            }
            val r = Reassembler()
            frags.dropLast(1).forEach { assertNull(r.accept(it)) }
            assertArrayEquals(msg, r.accept(frags.last()))
        }
    }

    @Test fun reassemblerRejectsBadInputAndRecovers() {
        val r = Reassembler(maxMessageBytes = 10)
        try { r.accept(ByteArray(0)); fail() } catch (_: IllegalArgumentException) {}
        try { r.accept(byteArrayOf(2, 1)); fail() } catch (_: IllegalArgumentException) {}
        try { r.accept(ByteArray(12) { if (it == 0) 0 else 1 }); fail() } catch (_: IllegalArgumentException) {}
        assertArrayEquals(byteArrayOf(9), r.accept(byteArrayOf(1, 9)))
    }

    @Test fun encryptedMessageRoundTripThroughFragments() {
        val k = AtaCrypto.random(32)
        val msg = Msg.encode(Msg.rtcOffer("v=0\r\n" + "a=candidate:x\r\n".repeat(200)))
        val sealed = CounterCipher(k, 0).seal(msg)
        val r = Reassembler()
        var out: ByteArray? = null
        for (f in Ble.fragment(sealed, Ble.maxFragmentLen(517))) out = r.accept(f)
        assertArrayEquals(msg, CounterCipher(k, 0).open(out!!))
    }
}

class RecordTest {
    private val keys = Handshake.deriveKeys(ByteArray(32) { 1 }, ByteArray(16) { 2 }, ByteArray(16) { 3 })

    @Test fun recordEncodings() {
        assertEquals("\u0001{\"name\":\"資料 \\\"x\\\".jpg\",\"size\":12345}", String(Record.fileStart("資料 \"x\".jpg", 12345), Charsets.UTF_8))
        assertEquals("\u0003{\"sha256\":\"ab\"}", String(Record.fileEnd("ab"), Charsets.UTF_8))
        assertArrayEquals(byteArrayOf(5), Record.allDone())
        assertArrayEquals(byteArrayOf(2, 9, 8), Record.data(byteArrayOf(7, 9, 8, 6), 1, 2))
        assertEquals("\u0004{\"ok\":false,\"error\":\"disk full\"}", String(Record.fileResult(false, "disk full"), Charsets.UTF_8))
        assertEquals(Record.FileResult(false, "disk full"), Record.parseResult(Record.fileResult(false, "disk full")))
        assertEquals(Record.FileResult(true, null), Record.parseResult("\u0004{\"ok\":true}".toByteArray()))
        try { Record.parseResult(byteArrayOf(2)); fail() } catch (e: AtaException) { assertEquals(ErrorCode.PROTOCOL, e.code) }
        try { Record.parseResult("\u0004{}".toByteArray()); fail() } catch (e: AtaException) { assertEquals(ErrorCode.PROTOCOL, e.code) }
    }

    @Test fun tcpFramingRoundTripWithCounters() {
        val tx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_P2M)
        val records = listOf(Record.fileStart("a", 3), Record.data(ByteArray(Record.TCP_MAX_DATA), 0, Record.TCP_MAX_DATA), Record.fileEnd("00"), Record.allDone())
        val wire = records.map { TcpFraming.frame(tx, it) }.reduce { a, b -> a + b }
        val ins = DataInputStream(ByteArrayInputStream(wire))
        val rx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_P2M)
        for (r in records) assertArrayEquals(r, TcpFraming.read(ins, rx))
        try { TcpFraming.read(ins, rx); fail() } catch (_: EOFException) {}
        // The largest data record is well below the 1 MiB frame cap.
        assertTrue(4 + 1 + Record.TCP_MAX_DATA + 16 < Record.TCP_MAX_FRAME)
    }

    @Test fun tcpFramingRejectsTamperReorderAndBadLengths() {
        val tx = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_M2P)
        val a = TcpFraming.frame(tx, Record.fileResult(true))
        val b = TcpFraming.frame(tx, Record.fileResult(true))
        fun read(bytes: ByteArray, prefix: Int = CounterCipher.PREFIX_TCP_M2P) =
            TcpFraming.read(DataInputStream(ByteArrayInputStream(bytes)), CounterCipher(keys.kFile, prefix))
        read(a)
        val flipped = a.copyOf().also { it[10] = (it[10].toInt() xor 1).toByte() }
        try { read(flipped); fail() } catch (e: IOException) { assertTrue(e.message!!.contains("authentication")) }
        try { read(b); fail("counter 1 record must not open at counter 0") } catch (_: IOException) {}
        try { read(a, CounterCipher.PREFIX_TCP_P2M); fail("wrong direction") } catch (_: IOException) {}
        try { read(byteArrayOf(0, 0x10, 0, 1) + ByteArray(8)); fail("> 1 MiB") } catch (e: IOException) { assertTrue(e.message!!.contains("length")) }
        try { read(byteArrayOf(0, 0, 0, 3, 1, 2, 3)); fail("too short") } catch (e: IOException) { assertTrue(e.message!!.contains("length")) }
        try { read(a.copyOf(a.size - 1)); fail("truncated") } catch (_: EOFException) {}
    }

    @Test fun dataChannelRecordsAreUnencryptedRecords() {
        // SPEC §7b: one binary message per record, same type-byte format, no extra encryption.
        val rec = Record.data(ByteArray(Record.RTC_MAX_DATA) { 1 }, 0, Record.RTC_MAX_DATA)
        assertEquals(Record.RTC_MAX_DATA + 1, rec.size)
        assertEquals(Record.DATA, rec[0])
    }

    @Test fun nonceLayout() {
        assertEquals("000000010000000000000005", Codec.hex(AtaCrypto.nonce(1, 5)))
        assertEquals("00000000ffffffffffffffff", Codec.hex(AtaCrypto.nonce(0, -1)))
        assertEquals("000000020000000100000000", Codec.hex(AtaCrypto.nonce(2, 1L shl 32)))
    }

    @Test fun subnetAndIpParsing() {
        val a = TcpLanDialer.parseIpv4("192.168.1.20")!!
        assertTrue(TcpLanDialer.sameSubnet(a, InetAddress.getByName("192.168.1.2"), 24))
        assertFalse(TcpLanDialer.sameSubnet(a, InetAddress.getByName("192.168.2.2"), 24))
        assertNull(TcpLanDialer.parseIpv4("fe80::1"))
        assertNull(TcpLanDialer.parseIpv4("example.com"))
        assertNull(TcpLanDialer.parseIpv4("1.2.3.256"))
    }

    @Test fun hkdfRfc5869Case1() {
        val okm = AtaCrypto.hkdfSha256(
            Codec.unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"),
            Codec.unhex("000102030405060708090a0b0c"),
            Codec.unhex("f0f1f2f3f4f5f6f7f8f9"), 42,
        )
        assertEquals("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", Codec.hex(okm))
    }
}

class PairingUriTest {
    private val id = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    private val k = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    @Test fun parsesValidUri() {
        val p = PairingInfo.parse("ata://pair?v=2&id=$id&name=Ann%E7%9A%84%20MacBook+Pro&k=$k")
        assertEquals(id, p.macIdHex)
        assertEquals("Ann的 MacBook+Pro", p.macName)
        assertArrayEquals(ByteArray(32) { it.toByte() }, p.key)
        assertFalse(p.toString().contains(k))
    }

    @Test fun acceptsUppercaseIdAndPaddedKeyAndAnyOrder() {
        val p = PairingInfo.parse("ata://pair?k=$k=&name=M&id=${id.uppercase()}&v=2&extra=1")
        assertEquals(id, p.macIdHex)
    }

    @Test fun rejectsBadInput() {
        fun bad(uri: String, code: ErrorCode = ErrorCode.BAD_PAIRING_CODE) {
            try { PairingInfo.parse(uri); fail(uri) } catch (e: AtaException) { assertEquals(uri, code, e.code) }
        }
        bad("https://pair?v=2&id=$id&name=M&k=$k")
        bad("ata://pair?v=1&id=$id&name=M&k=$k", ErrorCode.BAD_VERSION)
        bad("ata://pair?v=2&id=a0a1&name=M&k=$k")
        bad("ata://pair?v=2&id=$id&name=M&k=AAEC")
        bad("ata://pair?v=2&id=$id&k=$k")
        bad("ata://pair?v=2&id=$id&name=%E7%9&k=$k")
        bad("not a uri at all")
    }
}
