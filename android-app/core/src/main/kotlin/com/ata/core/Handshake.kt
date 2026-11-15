package com.ata.core

import java.net.URI

/** Session keys derived after a successful handshake (SPEC §5). Never log these. */
class SessionKeys(
    val kP2M: ByteArray,
    val kM2P: ByteArray,
    val kFile: ByteArray,
    val sid: ByteArray,
) {
    override fun toString() = "SessionKeys(<redacted>)"
}

/** SPEC §4 and §5 primitives. */
object Handshake {
    const val VERSION = 2
    const val ID_LEN = 16
    const val NONCE_LEN = 16
    const val KEY_LEN = 32

    private val LABEL_PHONE = "ata2-auth-phone".toByteArray(Charsets.US_ASCII)
    private val LABEL_MAC = "ata2-auth-mac".toByteArray(Charsets.US_ASCII)

    /** `auth.mac` = HMAC-SHA256(K, "ata2-auth-phone" ‖ macId ‖ phoneId ‖ nonceM ‖ nonceP). */
    fun phoneMac(k: ByteArray, macId: ByteArray, phoneId: ByteArray, nonceM: ByteArray, nonceP: ByteArray): ByteArray =
        AtaCrypto.hmacSha256(k, LABEL_PHONE, macId, phoneId, nonceM, nonceP)

    /** `auth_ok.mac` = HMAC-SHA256(K, "ata2-auth-mac" ‖ macId ‖ phoneId ‖ nonceM ‖ nonceP). */
    fun macMac(k: ByteArray, macId: ByteArray, phoneId: ByteArray, nonceM: ByteArray, nonceP: ByteArray): ByteArray =
        AtaCrypto.hmacSha256(k, LABEL_MAC, macId, phoneId, nonceM, nonceP)

    fun deriveKeys(k: ByteArray, nonceM: ByteArray, nonceP: ByteArray): SessionKeys {
        val salt = nonceM + nonceP
        fun d(info: String, len: Int) = AtaCrypto.hkdfSha256(k, salt, info.toByteArray(Charsets.US_ASCII), len)
        return SessionKeys(
            kP2M = d("ata2 ble p2m", 32),
            kM2P = d("ata2 ble m2p", 32),
            kFile = d("ata2 file", 32),
            sid = d("ata2 sid", 16),
        )
    }
}

/** Contents of a pairing QR code (SPEC §2). [key] is secret: never log this object's key or the raw URI. */
class PairingInfo(val macId: ByteArray, val macName: String, val key: ByteArray) {
    val macIdHex: String get() = Codec.hex(macId)
    override fun toString() = "PairingInfo(macId=$macIdHex, name=$macName, key=<redacted>)"

    companion object {
        /**
         * Parses `ata://pair?v=2&id=<hex>&name=<url-encoded>&k=<base64url>`.
         * Query values are RFC 3986 percent-decoded as UTF-8; '+' is kept literally (not a space).
         * Throws [AtaException] with [ErrorCode.BAD_PAIRING_CODE] or [ErrorCode.BAD_VERSION].
         */
        fun parse(uri: String): PairingInfo {
            fun bad(why: String): Nothing = throw AtaException(ErrorCode.BAD_PAIRING_CODE, why)
            val u = try {
                URI(uri.trim())
            } catch (e: Exception) {
                bad("not a URI")
            }
            if (!u.scheme.equals("ata", ignoreCase = true) || !u.host.equals("pair", ignoreCase = true)) bad("not an ata://pair URI")
            val q = u.rawQuery ?: bad("missing query")
            val params = HashMap<String, String>()
            for (part in q.split('&')) {
                if (part.isEmpty()) continue
                val eq = part.indexOf('=')
                val k = if (eq < 0) part else part.substring(0, eq)
                val v = if (eq < 0) "" else part.substring(eq + 1)
                params.putIfAbsent(percentDecode(k) ?: bad("bad escape"), percentDecode(v) ?: bad("bad escape"))
            }
            val v = params["v"] ?: bad("missing v")
            if (v != Handshake.VERSION.toString()) throw AtaException(ErrorCode.BAD_VERSION, "pairing code version $v")
            val idHex = params["id"] ?: bad("missing id")
            val id = runCatching { Codec.unhex(idHex) }.getOrNull()
            if (id == null || id.size != Handshake.ID_LEN) bad("bad id")
            val name = params["name"]?.takeIf { it.isNotBlank() } ?: bad("missing name")
            val k = runCatching { Codec.unb64url(params["k"] ?: bad("missing k")) }.getOrNull()
            if (k == null || k.size != Handshake.KEY_LEN) bad("bad k")
            return PairingInfo(id, name, k)
        }

        private fun percentDecode(s: String): String? {
            if (s.indexOf('%') < 0) return s
            val out = java.io.ByteArrayOutputStream(s.length)
            var i = 0
            while (i < s.length) {
                val c = s[i]
                if (c == '%') {
                    if (i + 2 >= s.length) return null
                    val hi = Character.digit(s[i + 1], 16)
                    val lo = Character.digit(s[i + 2], 16)
                    if (hi < 0 || lo < 0) return null
                    out.write((hi shl 4) or lo)
                    i += 3
                } else {
                    val b = c.toString().toByteArray(Charsets.UTF_8)
                    out.write(b, 0, b.size)
                    i++
                }
            }
            return out.toString("UTF-8")
        }
    }
}
