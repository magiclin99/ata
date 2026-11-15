package io.github.magiclin99.ata

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.github.magiclin99.ata.ui.AtaTheme
import io.github.magiclin99.ata.ui.SendSheet
import java.io.File

/**
 * Share target for ACTION_SEND / ACTION_SEND_MULTIPLE (any MIME type). Shows the send sheet over the
 * sharing app; the transfer itself runs in [TransferService], so leaving this screen does not stop it.
 * Opened without extras (from the notification) it shows the current transfer.
 */
class ShareActivity : ComponentActivity() {

    /** URIs of the share that opened this sheet; kept for "retry" (and in the saved state). */
    private var uris by mutableStateOf<List<Uri>>(emptyList())

    /** A share waiting for the user to pick a Mac (SPEC §3a); false once handed to the service. */
    private var picking by mutableStateOf(false)

    private val scanner by lazy { NearbyScanner(applicationContext, Logcat) }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) take(intent) else restore(savedInstanceState)
        setContent {
            AtaTheme {
                SendSheet(
                    uris = uris,
                    picking = picking,
                    scanner = scanner,
                    onPick = ::start,
                    onRetry = { TransferHub.clearFinished(); picking = true },
                    onClose = { finish() },
                )
            }
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putParcelableArrayList(STATE_URIS, ArrayList(uris))
        outState.putBoolean(STATE_PICKING, picking)
    }

    private fun restore(b: Bundle) {
        uris = if (Build.VERSION.SDK_INT >= 33) b.getParcelableArrayList(STATE_URIS, Uri::class.java).orEmpty()
        else @Suppress("DEPRECATION") b.getParcelableArrayList<Uri>(STATE_URIS).orEmpty()
        picking = b.getBoolean(STATE_PICKING)
    }

    override fun onDestroy() {
        scanner.stop()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        take(intent)
    }

    /** The user tapped a nearby Mac (permissions already granted by the picker). Transfers are unlimited. */
    private fun start(macIdHex: String, address: String?) {
        if (uris.isEmpty() || TransferHub.busy) return
        scanner.stop()
        TransferHub.clearFinished()
        TransferService.start(this, uris, macIdHex, address)
        picking = false
    }

    private fun take(i: Intent) {
        val shared = sharedUris(i)
        if (shared.isNotEmpty()) {
            uris = shared
            picking = true
        }
    }

    private fun sharedUris(i: Intent): List<Uri> {
        val out = LinkedHashSet<Uri>()
        when (i.action) {
            Intent.ACTION_SEND -> {
                val u: Uri? = if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableExtra(Intent.EXTRA_STREAM)
                if (u != null) out += u
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val list: List<Uri>? = if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                list?.let { out += it }
            }
            else -> return emptyList()
        }
        if (out.isEmpty()) {
            i.clipData?.let { c -> for (n in 0 until c.itemCount) c.getItemAt(n).uri?.let { out += it } }
        }
        if (out.isEmpty()) {
            // Plain text shares (links, notes) become a .txt file.
            val text = i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (!text.isNullOrEmpty()) {
                val dir = File(cacheDir, "shared-text").apply { mkdirs() }
                dir.listFiles()?.filter { System.currentTimeMillis() - it.lastModified() > 86_400_000L }?.forEach { it.delete() }
                val subject = i.getStringExtra(Intent.EXTRA_SUBJECT)?.let { safeName(it, 0) }?.take(60)
                val f = File(dir, "${subject ?: "ATA"}-${System.currentTimeMillis()}.txt")
                f.writeText(text)
                out += Uri.fromFile(f)
            }
        }
        return out.toList()
    }

    private companion object {
        const val STATE_URIS = "uris"
        const val STATE_PICKING = "picking"
    }
}
