package io.github.magiclin99.ata

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.activity.ComponentActivity
import com.ata.core.AtaException
import com.ata.core.ErrorCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.security.SecureRandom

/**
 * SPEC §9 automation hooks. Debug builds only: this file is in src/debug, the release
 * build compiles the no-op in src/release instead.
 *
 *   am start -n io.github.magiclin99.ata/.MainActivity --es debugPairUri "'ata://pair?…'"
 *   am start -n io.github.magiclin99.ata/.MainActivity --ei debugSendMiB 50 [--ei debugCount 3] [--ez debugForceRtc true]
 */
object DebugHooks {
    private val EXTRAS = listOf("debugPairUri", "debugSendMiB")

    fun wants(i: Intent): Boolean = EXTRAS.any { i.hasExtra(it) }

    fun run(activity: ComponentActivity, i: Intent, withBle: (() -> Unit) -> Unit) {
        val app = activity.app
        i.getStringExtra("debugPairUri")?.let {
            withBle {
                Logcat.i("debug: pairing from intent")
                app.pairing.pair(it)
            }
            return
        }
        val mib = i.getIntExtra("debugSendMiB", -1)
        if (mib < 0) return
        val count = i.getIntExtra("debugCount", 1).coerceAtLeast(1)
        val forceRtc = i.getBooleanExtra("debugForceRtc", false)
        withBle {
            app.scope.launch {
                val macs = app.pairings.macs.value
                if (macs.size != 1) {
                    Logcat.i("debug: need exactly one paired Mac, have ${macs.size}")
                    Logcat.i("RESULT ok=false via=none files=0 bytes=0 ms=0")
                    return@launch
                }
                if (TransferHub.busy) {
                    Logcat.i("debug: a transfer is already running"); return@launch
                }
                val uris = try {
                    withContext(Dispatchers.IO) { makeDebugFiles(activity, mib, count) }
                } catch (e: Exception) {
                    Logcat.i("debug: cannot create test files: ${e.message}")
                    Logcat.i("RESULT ok=false via=none files=0 bytes=0 ms=0")
                    return@launch
                }
                Logcat.i("debug: sending $count x $mib MiB forceRtc=$forceRtc (picker bypassed)")
                TransferService.start(activity, uris, macs[0].idHex, address = null, forceRtc = forceRtc)
                activity.startActivity(Intent(activity, ShareActivity::class.java))
            }
        }
    }

    /** [count] files of [mib] MiB random bytes in cache/debug (previous ones are deleted). */
    private fun makeDebugFiles(ctx: Context, mib: Int, count: Int): List<Uri> {
        val dir = File(ctx.cacheDir, "debug").apply { deleteRecursively(); mkdirs() }
        val rnd = SecureRandom()
        val buf = ByteArray(64 * 1024)
        val stamp = System.currentTimeMillis()
        return (1..count).map { n ->
            val f = File(dir, "ata-test-$stamp-$n-${mib}MiB.bin")
            f.outputStream().use { out -> repeat(16 * mib) { rnd.nextBytes(buf); out.write(buf) } }
            if (f.length() != mib * 1024L * 1024L) throw AtaException(ErrorCode.FILE_UNREADABLE, "short write")
            Uri.fromFile(f)
        }
    }
}
