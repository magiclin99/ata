package com.ata.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/**
 * JSON message builders and accessors (SPEC §4, §6, §7). Output is compact, keys in the order shown in
 * the spec tables, strings UTF-8 with only the JSON-mandatory escapes.
 */
object Msg {
    fun encode(o: JsonObject): ByteArray = o.toString().toByteArray(Charsets.UTF_8)

    fun decode(bytes: ByteArray): JsonObject {
        val e = try {
            Json.parseToJsonElement(String(bytes, Charsets.UTF_8))
        } catch (e: Exception) {
            throw AtaException(ErrorCode.PROTOCOL, "message is not JSON", e)
        }
        return e as? JsonObject ?: throw AtaException(ErrorCode.PROTOCOL, "message is not a JSON object")
    }

    // ---- handshake (plaintext)

    fun hello(macId: ByteArray, nonceM: ByteArray) = buildJsonObject {
        put("t", "hello"); put("v", Handshake.VERSION); put("id", Codec.hex(macId)); put("n", Codec.b64(nonceM))
    }

    fun auth(phoneId: ByteArray, phoneName: String, nonceP: ByteArray, pairing: Boolean, mac: ByteArray) = buildJsonObject {
        put("t", "auth"); put("id", Codec.hex(phoneId)); put("name", phoneName); put("n", Codec.b64(nonceP))
        put("pairing", pairing); put("mac", Codec.b64(mac))
    }

    fun authOk(macName: String, mac: ByteArray) = buildJsonObject {
        put("t", "auth_ok"); put("name", macName); put("mac", Codec.b64(mac))
    }

    fun authFail(reason: String) = buildJsonObject { put("t", "auth_fail"); put("reason", reason) }

    // ---- encrypted BLE messages

    data class FileEntry(val name: String, val size: Long)

    fun send(files: List<FileEntry>, caps: List<String> = emptyList()) = buildJsonObject {
        put("t", "send")
        put("files", buildJsonArray {
            for (f in files) add(buildJsonObject { put("name", f.name); put("size", f.size) })
        })
        put("total", files.sumOf { it.size })
        if (caps.isNotEmpty()) put("caps", JsonArray(caps.map { JsonPrimitive(it) }))
    }

    /** Capability in `send.caps`: this phone can open a temporary hotspot (SPEC §7c). */
    const val CAP_HOTSPOT = "hotspot"

    /** SPEC §7c. Only ever sent over the encrypted session; [summary] redacts the password. */
    fun hotspot(ssid: String, psk: String) = buildJsonObject { put("t", "hotspot"); put("ssid", ssid); put("psk", psk) }
    fun hotspotReady(lan: List<String>, tcpPort: Int) = buildJsonObject {
        put("t", "hotspot_ready"); put("lan", JsonArray(lan.map { JsonPrimitive(it) })); put("tcpPort", tcpPort)
    }
    fun hotspotError(error: String) = buildJsonObject { put("t", "hotspot_error"); put("error", error) }

    fun accept(tcpPort: Int, lan: List<String>, hotspot: Boolean = false) = buildJsonObject {
        put("t", "accept"); put("tcpPort", tcpPort); put("lan", JsonArray(lan.map { JsonPrimitive(it) }))
        if (hotspot) put("hotspot", true)
    }

    fun reject(reason: String) = buildJsonObject { put("t", "reject"); put("reason", reason) }
    fun rtcOffer(sdp: String) = buildJsonObject { put("t", "rtc_offer"); put("sdp", sdp) }
    fun rtcAnswer(sdp: String) = buildJsonObject { put("t", "rtc_answer"); put("sdp", sdp) }
    fun rtcError(error: String) = buildJsonObject { put("t", "rtc_error"); put("error", error) }

    fun bye(ok: Boolean, via: String?, error: String?) = buildJsonObject {
        put("t", "bye"); put("ok", ok)
        put("via", via?.let { JsonPrimitive(it) } ?: JsonNull)
        put("error", error?.let { JsonPrimitive(it) } ?: JsonNull)
    }

    // ---- accessors

    fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
    fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
    fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
    fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
    fun JsonObject.strList(key: String): List<String> =
        (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }.orEmpty()

    val JsonObject.type: String get() = str("t") ?: ""

    /** Short description safe to log: the type plus non-secret scalar fields; SDP bodies are summarized. */
    fun summary(o: JsonObject): String = buildString {
        append(o.type)
        for ((k, v) in o) {
            if (k == "t") continue
            append(' ').append(k).append('=')
            when {
                k == "psk" -> append("<redacted>")
                k == "mac" || k == "n" -> append("<").append((v as? JsonPrimitive)?.content?.length ?: 0).append(" chars>")
                k == "sdp" -> append("<").append((v as? JsonPrimitive)?.content?.length ?: 0).append(" B sdp>")
                else -> append(v.short())
            }
        }
    }

    private fun JsonElement.short(): String = toString().let { if (it.length > 200) it.take(200) + "…" else it }
}
