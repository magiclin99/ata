package io.github.magiclin99.ata

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.ata.core.AtaException
import com.ata.core.AtaLog
import com.ata.core.ErrorCode
import com.ata.core.HotspotCredentials
import com.ata.core.HotspotProvider
import com.ata.core.TcpLanDialer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.net.Socket
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * SPEC §7c: this phone's temporary hotspot, via [WifiManager.startLocalOnlyHotspot]. Android picks the name and
 * password (an app cannot choose them before API 36, and even then only system apps), it has no internet access,
 * and it closes when the reservation is closed. The password is handed to the engine and never logged.
 */
class AndroidHotspot(ctx: Context, private val log: AtaLog) : HotspotProvider {
    private val wifi = ctx.applicationContext.getSystemService(WifiManager::class.java)
    @Volatile private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    @Volatile private var stopped = false

    companion object {
        fun supported(ctx: Context): Boolean = ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI)

        /**
         * What startLocalOnlyHotspot needs at run time besides CHANGE_WIFI_STATE: NEARBY_WIFI_DEVICES on API 33+,
         * ACCESS_FINE_LOCATION up to API 32 (API 28–30 already hold it for Bluetooth scanning).
         */
        fun permissions(): Array<String> = when {
            Build.VERSION.SDK_INT >= 33 -> arrayOf(Manifest.permission.NEARBY_WIFI_DEVICES)
            // Android 12 asks for fine location only together with coarse.
            Build.VERSION.SDK_INT >= 31 -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
            else -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

        fun hasPermission(ctx: Context): Boolean {
            val needed = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES else Manifest.permission.ACCESS_FINE_LOCATION
            return ContextCompat.checkSelfPermission(ctx, needed) == PackageManager.PERMISSION_GRANTED
        }

        private fun reasonName(r: Int) = when (r) {
            WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL -> "no_channel"
            WifiManager.LocalOnlyHotspotCallback.ERROR_GENERIC -> "generic"
            WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "incompatible_mode"
            WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "tethering_disallowed"
            else -> "reason $r"
        }

        private fun unquote(s: String?): String? = s?.removeSurrounding("\"")
    }

    @SuppressLint("MissingPermission") // checked by the caller (TransferService) before the engine runs
    override suspend fun start(timeoutMs: Long): HotspotCredentials {
        val w = wifi ?: throw AtaException(ErrorCode.HOTSPOT_FAILED, "no WifiManager")
        val r = withContext(Dispatchers.Main) {
            withTimeout(timeoutMs) {
                suspendCancellableCoroutine { c ->
                    val cb = object : WifiManager.LocalOnlyHotspotCallback() {
                        override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                            // Started after we gave up (timeout, cancel, stop): give it straight back.
                            if (!c.isActive || stopped) { res.close(); return }
                            reservation = res
                            c.resume(res)
                        }
                        override fun onStopped() { log.i("hotspot: stopped by the system") }
                        override fun onFailed(reason: Int) {
                            if (c.isActive) c.resumeWithException(IOException("LocalOnlyHotspot failed: ${reasonName(reason)}"))
                        }
                    }
                    try {
                        w.startLocalOnlyHotspot(cb, Handler(Looper.getMainLooper()))
                    } catch (e: Exception) { // SecurityException (permission), IllegalStateException (already requested)
                        if (c.isActive) c.resumeWithException(e)
                    }
                }
            }
        }
        val creds = if (Build.VERSION.SDK_INT >= 30) {
            val cfg: SoftApConfiguration = r.softApConfiguration
            val ssid = if (Build.VERSION.SDK_INT >= 33) cfg.wifiSsid?.toString() else @Suppress("DEPRECATION") cfg.ssid
            log.i("hotspot: security type ${cfg.securityType}")
            Pair(unquote(ssid), cfg.passphrase)
        } else {
            @Suppress("DEPRECATION") val cfg = r.wifiConfiguration
            @Suppress("DEPRECATION") Pair(unquote(cfg?.SSID), unquote(cfg?.preSharedKey))
        }
        val (ssid, psk) = creds
        // An open hotspot (no password) is not used: the Mac would join it without any check of who runs it.
        if (ssid.isNullOrEmpty() || psk.isNullOrEmpty()) throw AtaException(ErrorCode.HOTSPOT_FAILED, "hotspot has no name or no password")
        return HotspotCredentials(ssid, psk)
    }

    /** Not bound to any Network: the hotspot's subnet is a local route on the phone itself. */
    override suspend fun dial(ips: List<String>, port: Int): Socket? = TcpLanDialer(log, timeoutMs = 3_000).dial(ips, port)

    override fun stop() {
        stopped = true
        reservation?.let { runCatching { it.close() }; log.i("hotspot: closed") }
        reservation = null
    }
}
