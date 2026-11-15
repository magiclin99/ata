package com.ata.core

import com.ata.core.Msg.str
import com.ata.core.Msg.int
import com.ata.core.Msg.type
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import java.security.GeneralSecurityException

/**
 * A reliable, ordered, message-oriented link to one Mac (BLE GATT on Android; in-memory in tests).
 * Fragmentation is the link's job: [send] and [receive] deal in whole messages.
 */
interface MessageLink {
    /** Sends one whole message; returns when the peer acknowledged every fragment. */
    suspend fun send(message: ByteArray)

    /** Next whole message. Throws [LinkClosedException] once the link is gone. */
    suspend fun receive(): ByteArray

    fun close()
}

class LinkClosedException(msg: String, cause: Throwable? = null) : java.io.IOException(msg, cause)

/** The Mac's `hello`. */
class Hello(val macId: ByteArray, val nonceM: ByteArray) {
    val macIdHex: String get() = Codec.hex(macId)
}

/** Phone side of the handshake (SPEC §4). */
class PhoneHandshake(
    private val phoneId: ByteArray,
    private val phoneName: String,
    private val log: AtaLog,
) {
    init {
        require(phoneId.size == Handshake.ID_LEN)
    }

    /** Waits for `hello` (the Mac sends it once we subscribe to TX). */
    suspend fun readHello(link: MessageLink, timeoutMs: Long = 8_000): Hello {
        val m = receivePlain(link, timeoutMs, "hello")
        if (m.type != "hello") throw AtaException(ErrorCode.PROTOCOL, "expected hello, got '${m.type}'")
        val v = m.int("v")
        if (v != Handshake.VERSION) throw AtaException(ErrorCode.BAD_VERSION, "Mac speaks v=$v")
        val id = m.str("id")?.let { runCatching { Codec.unhex(it) }.getOrNull() }
        val n = m.str("n")?.let { runCatching { Codec.unb64(it) }.getOrNull() }
        if (id == null || id.size != Handshake.ID_LEN) throw AtaException(ErrorCode.PROTOCOL, "hello has bad id")
        if (n == null || n.size != Handshake.NONCE_LEN) throw AtaException(ErrorCode.PROTOCOL, "hello has bad nonce")
        log.i("hello from Mac ${Codec.hex(id)}")
        return Hello(id, n)
    }

    /**
     * Sends `auth`, verifies `auth_ok`, derives keys. On any failure the caller must close [link].
     * [key] is the pairing key K (from the QR code when [pairing] is true, else from storage).
     */
    suspend fun authenticate(link: MessageLink, hello: Hello, key: ByteArray, pairing: Boolean, timeoutMs: Long = 10_000): SecureSession {
        val nonceP = AtaCrypto.random(Handshake.NONCE_LEN)
        val mac = Handshake.phoneMac(key, hello.macId, phoneId, hello.nonceM, nonceP)
        val auth = Msg.auth(phoneId, phoneName, nonceP, pairing, mac)
        log.i("BLE -> auth pairing=$pairing")
        sendPlain(link, auth)
        val r = receivePlain(link, timeoutMs, "auth_ok")
        when (r.type) {
            "auth_ok" -> {}
            "auth_fail" -> {
                val reason = r.str("reason") ?: ""
                log.i("BLE <- auth_fail reason=$reason")
                throw AtaException(
                    when (reason) {
                        "busy" -> ErrorCode.MAC_BUSY
                        "pairing_expired" -> ErrorCode.PAIRING_EXPIRED
                        "bad_version" -> ErrorCode.BAD_VERSION
                        // unknown_device, bad_mac, anything else: our key is not (or no longer) accepted.
                        else -> ErrorCode.PAIRING_REMOVED
                    },
                    "auth_fail $reason",
                )
            }
            else -> throw AtaException(ErrorCode.PROTOCOL, "expected auth_ok, got '${r.type}'")
        }
        val theirs = r.str("mac")?.let { runCatching { Codec.unb64(it) }.getOrNull() }
            ?: throw AtaException(ErrorCode.MAC_AUTH_FAILED, "auth_ok without mac")
        val expected = Handshake.macMac(key, hello.macId, phoneId, hello.nonceM, nonceP)
        if (!AtaCrypto.constantTimeEquals(theirs, expected)) {
            log.i("BLE <- auth_ok with WRONG mac; dropping")
            throw AtaException(ErrorCode.MAC_AUTH_FAILED, "auth_ok mac mismatch")
        }
        val macName = r.str("name") ?: ""
        log.i("BLE <- auth_ok name=$macName (verified)")
        return SecureSession(link, hello.macId, macName, Handshake.deriveKeys(key, hello.nonceM, nonceP), log)
    }

    private suspend fun sendPlain(link: MessageLink, o: JsonObject) {
        try {
            link.send(Msg.encode(o))
        } catch (e: AtaException) {
            throw e
        } catch (e: Exception) {
            throw AtaException(ErrorCode.CONNECTION_LOST, "send ${o.type}: ${e.message}", e)
        }
    }

    private suspend fun receivePlain(link: MessageLink, timeoutMs: Long, what: String): JsonObject {
        val bytes = try {
            withTimeout(timeoutMs) { link.receive() }
        } catch (e: TimeoutCancellationException) {
            throw AtaException(ErrorCode.CONNECTION_LOST, "no $what within $timeoutMs ms")
        } catch (e: LinkClosedException) {
            throw AtaException(ErrorCode.CONNECTION_LOST, "link closed waiting for $what", e)
        }
        return Msg.decode(bytes)
    }
}

/** Encrypted BLE messaging after `auth_ok` (SPEC §5). */
class SecureSession(
    val link: MessageLink,
    val macId: ByteArray,
    val macName: String,
    val keys: SessionKeys,
    private val log: AtaLog,
) {
    private val tx = CounterCipher(keys.kP2M, CounterCipher.PREFIX_BLE)
    private val rx = CounterCipher(keys.kM2P, CounterCipher.PREFIX_BLE)
    private val sendLock = kotlinx.coroutines.sync.Mutex()

    suspend fun send(o: JsonObject) = sendLock.lockAndRun {
        log.i("BLE -> ${Msg.summary(o)}")
        val sealed = tx.seal(Msg.encode(o))
        try {
            link.send(sealed)
        } catch (e: Exception) {
            throw AtaException(ErrorCode.CONNECTION_LOST, "send ${o.type}: ${e.message}", e)
        }
    }

    /** Next decrypted message. Decrypt failure closes the link (SPEC §5). */
    suspend fun receive(timeoutMs: Long): JsonObject {
        val bytes = try {
            withTimeout(timeoutMs) { link.receive() }
        } catch (e: TimeoutCancellationException) {
            throw AtaException(ErrorCode.CONNECTION_LOST, "no message from Mac within $timeoutMs ms")
        } catch (e: LinkClosedException) {
            throw AtaException(ErrorCode.CONNECTION_LOST, "BLE link closed", e)
        }
        val pt = try {
            rx.open(bytes)
        } catch (e: GeneralSecurityException) {
            log.i("BLE <- message failed to decrypt; closing")
            link.close()
            throw AtaException(ErrorCode.PROTOCOL, "BLE message failed authentication", e)
        }
        val o = Msg.decode(pt)
        log.i("BLE <- ${Msg.summary(o)}")
        return o
    }

    fun close() = link.close()

    private suspend inline fun <T> kotlinx.coroutines.sync.Mutex.lockAndRun(block: () -> T): T {
        lock()
        try {
            return block()
        } finally {
            unlock()
        }
    }
}
