package com.ata.core

import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Encodings used on the wire (SPEC §2, §4). */
object Codec {
    private const val DIGITS = "0123456789abcdef"

    fun hex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xff
            sb.append(DIGITS[v ushr 4]).append(DIGITS[v and 0x0f])
        }
        return sb.toString()
    }

    /** Accepts upper or lower case; throws [IllegalArgumentException] on odd length or non-hex. */
    fun unhex(s: String): ByteArray {
        require(s.length % 2 == 0) { "odd hex length" }
        return ByteArray(s.length / 2) { i ->
            val hi = Character.digit(s[2 * i], 16)
            val lo = Character.digit(s[2 * i + 1], 16)
            require(hi >= 0 && lo >= 0) { "not hex" }
            ((hi shl 4) or lo).toByte()
        }
    }

    /** Standard base64 with padding ("b64" in SPEC §4). */
    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    fun unb64(s: String): ByteArray = Base64.getDecoder().decode(s)

    /** base64url without padding (the `k` parameter of the pairing URI). */
    fun b64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    /** Decodes base64url with or without padding. */
    fun unb64url(s: String): ByteArray = Base64.getUrlDecoder().decode(s)
}

object AtaCrypto {
    private val rng = SecureRandom()

    fun random(n: Int): ByteArray = ByteArray(n).also { rng.nextBytes(it) }

    fun hmacSha256(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        for (p in parts) mac.update(p)
        return mac.doFinal()
    }

    /** RFC 5869 HKDF-SHA256 (extract + expand). */
    fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32) { "bad HKDF length" }
        val prk = hmacSha256(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var t = ByteArray(0)
        var off = 0
        var counter = 1
        while (off < length) {
            t = hmacSha256(prk, t, info, byteArrayOf(counter.toByte()))
            val n = minOf(t.size, length - off)
            System.arraycopy(t, 0, out, off, n)
            off += n
            counter++
        }
        return out
    }

    /** Constant-time comparison (length is not secret). */
    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    /** 12-byte nonce = 4-byte big-endian [prefix] || 8-byte big-endian [counter] (SPEC §5, §7a). */
    fun nonce(prefix: Int, counter: Long): ByteArray {
        val n = ByteArray(12)
        for (i in 0 until 4) n[i] = (prefix ushr (24 - 8 * i)).toByte()
        for (i in 0 until 8) n[4 + i] = (counter ushr (56 - 8 * i)).toByte()
        return n
    }

    /** AES-256-GCM, 128-bit tag appended, no AAD. */
    fun seal(key: ByteArray, nonce: ByteArray, plaintext: ByteArray, off: Int = 0, len: Int = plaintext.size): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return c.doFinal(plaintext, off, len)
    }

    /** Throws [javax.crypto.AEADBadTagException] (a [java.security.GeneralSecurityException]) on tampering. */
    fun open(key: ByteArray, nonce: ByteArray, sealed: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return c.doFinal(sealed)
    }
}

/**
 * One direction of an AES-GCM stream with an implicit counter (SPEC §5 BLE, §7a TCP).
 * Each instance either seals or opens, never both; the counter starts at 0 and advances per message.
 */
class CounterCipher(private val key: ByteArray, private val prefix: Int) {
    private var counter = 0L

    val nextCounter: Long get() = counter

    @Synchronized
    fun seal(plaintext: ByteArray, off: Int = 0, len: Int = plaintext.size): ByteArray =
        AtaCrypto.seal(key, AtaCrypto.nonce(prefix, counter++), plaintext, off, len)

    /** On failure the counter is not advanced and the caller must drop the connection. */
    @Synchronized
    fun open(sealed: ByteArray): ByteArray {
        val pt = AtaCrypto.open(key, AtaCrypto.nonce(prefix, counter), sealed)
        counter++
        return pt
    }

    companion object {
        const val PREFIX_BLE = 0x00000000
        const val PREFIX_TCP_P2M = 0x00000001
        const val PREFIX_TCP_M2P = 0x00000002
    }
}
