package io.github.magiclin99.ata

import android.content.Context
import android.provider.Settings
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.edit
import com.ata.core.AtaCrypto
import com.ata.core.Codec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** This phone's `deviceId` (SPEC §2) and display name. */
class Identity(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("identity", Context.MODE_PRIVATE)
    private val cr = ctx.contentResolver

    val phoneId: ByteArray = synchronized(this) {
        prefs.getString("phoneId", null)?.let { Codec.unhex(it) } ?: AtaCrypto.random(16).also {
            prefs.edit { putString("phoneId", Codec.hex(it)) }
        }
    }

    /** User-visible device name ("Ann's phone"), falling back to the model. */
    val phoneName: String
        get() = runCatching { Settings.Global.getString(cr, Settings.Global.DEVICE_NAME) }.getOrNull()?.takeIf { it.isNotBlank() }
            ?: Build.MODEL
}

data class PairedMac(val idHex: String, val name: String, val pairedAt: Long)

/**
 * Pairing keys K, indexed by macId (SPEC §2). Each K is encrypted with a non-exportable AES-256-GCM
 * Android Keystore key before it touches SharedPreferences.
 */
class PairingStore(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("pairings", Context.MODE_PRIVATE)
    private val _macs = MutableStateFlow(load())
    val macs: StateFlow<List<PairedMac>> = _macs

    private fun load(): List<PairedMac> = prefs.all.keys.filter { it.startsWith(PREFIX) }.mapNotNull { k ->
        runCatching {
            val o = JSONObject(prefs.getString(k, null)!!)
            PairedMac(k.removePrefix(PREFIX), o.getString("name"), o.getLong("pairedAt"))
        }.getOrNull()
    }.sortedByDescending { it.pairedAt }

    @Synchronized
    fun save(idHex: String, name: String, key: ByteArray) {
        val o = JSONObject()
            .put("name", name)
            .put("pairedAt", System.currentTimeMillis())
            .put("wrapped", Codec.b64(wrap(key)))
        prefs.edit(commit = true) { putString(PREFIX + idHex, o.toString()) } // durable before we report success
        _macs.value = load()
    }

    /** Updates the stored display name when the Mac reports a new one in auth_ok. */
    @Synchronized
    fun rename(idHex: String, name: String) {
        val raw = prefs.getString(PREFIX + idHex, null) ?: return
        val o = JSONObject(raw)
        if (o.optString("name") == name || name.isBlank()) return
        prefs.edit { putString(PREFIX + idHex, o.put("name", name).toString()) }
        _macs.value = load()
    }

    @Synchronized
    fun key(idHex: String): ByteArray? {
        val raw = prefs.getString(PREFIX + idHex, null) ?: return null
        return runCatching { unwrap(Codec.unb64(JSONObject(raw).getString("wrapped"))) }.getOrNull()
    }

    fun isPaired(idHex: String) = prefs.contains(PREFIX + idHex)

    @Synchronized
    fun remove(idHex: String) {
        prefs.edit(commit = true) { remove(PREFIX + idHex) }
        _macs.value = load()
    }

    private fun wrappingKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    /** iv(12) ‖ ciphertext+tag. */
    private fun wrap(plain: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wrappingKey())
        return c.iv + c.doFinal(plain)
    }

    private fun unwrap(blob: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, blob, 0, 12))
        return c.doFinal(blob, 12, blob.size - 12)
    }

    private companion object {
        const val PREFIX = "mac."
        const val ALIAS = "ata.pairing.wrap"
    }
}

data class HistoryEntry(
    val time: Long,
    val macName: String,
    val fileCount: Int,
    val firstName: String,
    val bytes: Long,
    val ok: Boolean,
    /** "lan", "rtc" or null when no path was established. */
    val via: String?,
    /** ErrorCode name, or null on success. */
    val error: String?,
    /** Bytes that went over mobile data (0 on Wi-Fi). */
    val cellularBytes: Long = 0,
)

/** The last [MAX] transfers, newest first. */
class HistoryStore(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("history", Context.MODE_PRIVATE)
    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<HistoryEntry>> = _items

    private fun load(): List<HistoryEntry> = runCatching {
        val a = JSONArray(prefs.getString("items", "[]"))
        (0 until a.length()).map { i ->
            val o = a.getJSONObject(i)
            HistoryEntry(
                o.getLong("time"), o.getString("mac"), o.getInt("count"), o.getString("first"), o.getLong("bytes"),
                o.getBoolean("ok"), o.optString("via").ifEmpty { null }, o.optString("error").ifEmpty { null },
                o.optLong("cell", 0L),
            )
        }
    }.getOrDefault(emptyList())

    @Synchronized
    fun add(e: HistoryEntry) {
        val list = (listOf(e) + _items.value).take(MAX)
        val a = JSONArray()
        for (x in list) a.put(
            JSONObject().put("time", x.time).put("mac", x.macName).put("count", x.fileCount).put("first", x.firstName)
                .put("bytes", x.bytes).put("ok", x.ok).put("via", x.via ?: "").put("error", x.error ?: "").put("cell", x.cellularBytes)
        )
        prefs.edit { putString("items", a.toString()) }
        _items.value = list
    }

    private companion object {
        const val MAX = 30
    }
}
