package com.ata.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.File

/** Reproduces every value in spec/vectors.json (SPEC §8). */
class VectorsTest {
    private val v: JsonObject = Json.parseToJsonElement(
        File(System.getProperty("ata.vectors") ?: "../../spec/vectors.json").readText()
    ).jsonObject

    private fun s(section: String, key: String) = v[section]!!.jsonObject[key]!!.jsonPrimitive.content
    private fun h(section: String, key: String) = Codec.unhex(s(section, key))

    private val k = h("inputs", "K")
    private val macId = h("inputs", "macId")
    private val phoneId = h("inputs", "phoneId")
    private val nM = h("inputs", "nonceM")
    private val nP = h("inputs", "nonceP")
    private val keys = Handshake.deriveKeys(k, nM, nP)

    @Test fun inputsAreTheDocumentedRamps() {
        assertArrayEquals(ByteArray(32) { it.toByte() }, k)
        assertArrayEquals(ByteArray(16) { (0xa0 + it).toByte() }, macId)
        assertArrayEquals(ByteArray(16) { (0xb0 + it).toByte() }, phoneId)
        assertArrayEquals(ByteArray(16) { (0x10 + it).toByte() }, nM)
        assertArrayEquals(ByteArray(16) { (0x20 + it).toByte() }, nP)
    }

    @Test fun pairingKeyBase64Url() {
        assertEquals(s("inputs", "K_b64url"), Codec.b64url(k))
        assertArrayEquals(k, Codec.unb64url(s("inputs", "K_b64url")))
    }

    @Test fun handshakeMacs() {
        val p = Handshake.phoneMac(k, macId, phoneId, nM, nP)
        val m = Handshake.macMac(k, macId, phoneId, nM, nP)
        assertEquals(s("handshake", "auth_phone_mac"), Codec.hex(p))
        assertEquals(s("handshake", "auth_phone_mac_b64"), Codec.b64(p))
        assertEquals(s("handshake", "auth_mac_mac"), Codec.hex(m))
        assertEquals(s("handshake", "auth_mac_mac_b64"), Codec.b64(m))
    }

    @Test fun hkdfKeys() {
        assertEquals(s("keys", "kP2M"), Codec.hex(keys.kP2M))
        assertEquals(s("keys", "kM2P"), Codec.hex(keys.kM2P))
        assertEquals(s("keys", "kFile"), Codec.hex(keys.kFile))
        assertEquals(s("keys", "sid"), Codec.hex(keys.sid))
    }

    @Test fun bleP2mSendMessage() {
        val pt = s("ble_p2m", "plaintext_utf8")
        // Our builder must produce byte-identical JSON for the same message.
        assertEquals(pt, String(Msg.encode(Msg.send(listOf(Msg.FileEntry("a.jpg", 3)))), Charsets.UTF_8))
        val c = CounterCipher(keys.kP2M, CounterCipher.PREFIX_BLE)
        assertEquals(s("ble_p2m", "counter0_wire"), Codec.hex(c.seal(pt.toByteArray())))
        assertEquals(s("ble_p2m", "counter1_wire"), Codec.hex(c.seal(pt.toByteArray())))
        // And the Mac side decrypts both in order.
        val d = CounterCipher(keys.kP2M, CounterCipher.PREFIX_BLE)
        assertEquals(pt, String(d.open(h("ble_p2m", "counter0_wire"))))
        assertEquals(pt, String(d.open(h("ble_p2m", "counter1_wire"))))
    }

    @Test fun bleM2pAcceptMessage() {
        val pt = s("ble_m2p", "plaintext_utf8")
        assertEquals(pt, String(Msg.encode(Msg.accept(47800, listOf("192.168.1.2"))), Charsets.UTF_8))
        val rx = CounterCipher(keys.kM2P, CounterCipher.PREFIX_BLE)
        val opened = rx.open(h("ble_m2p", "counter0_wire"))
        assertEquals(pt, String(opened, Charsets.UTF_8))
        val m = Msg.decode(opened)
        assertEquals(47800, m["tcpPort"]!!.jsonPrimitive.int)
        assertEquals(s("ble_m2p", "counter0_wire"), Codec.hex(CounterCipher(keys.kM2P, 0).seal(pt.toByteArray())))
    }

    @Test fun tcpRecordP2m() {
        val counter = v["tcp_record_p2m"]!!.jsonObject["counter"]!!.jsonPrimitive.int
        assertEquals(5, counter)
        assertEquals(s("tcp_record_p2m", "nonce"), Codec.hex(AtaCrypto.nonce(CounterCipher.PREFIX_TCP_P2M, counter.toLong())))
        val rec = h("tcp_record_p2m", "record_plaintext")
        assertArrayEquals(rec, Record.data("abc".toByteArray(), 0, 3))
        val c = CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_P2M)
        repeat(counter) { c.seal(byteArrayOf(0)) } // advance to counter 5
        assertEquals(s("tcp_record_p2m", "wire_with_length_prefix"), Codec.hex(TcpFraming.frame(c, rec)))
    }

    @Test fun tcpRecordM2p() {
        assertEquals(s("tcp_record_m2p", "nonce"), Codec.hex(AtaCrypto.nonce(CounterCipher.PREFIX_TCP_M2P, 0)))
        val rec = h("tcp_record_m2p", "record_plaintext")
        assertArrayEquals(rec, Record.fileResult(true))
        val sealed = h("tcp_record_m2p", "sealed")
        assertEquals(Codec.hex(sealed), Codec.hex(CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_M2P).seal(rec)))
        // Phone reads it as a framed record.
        val framed = byteArrayOf(0, 0, 0, sealed.size.toByte()) + sealed
        val got = TcpFraming.read(DataInputStream(ByteArrayInputStream(framed)), CounterCipher(keys.kFile, CounterCipher.PREFIX_TCP_M2P))
        assertEquals(Record.FileResult(true, null), Record.parseResult(got))
    }
}
