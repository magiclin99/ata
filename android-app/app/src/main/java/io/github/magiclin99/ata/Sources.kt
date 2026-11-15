package io.github.magiclin99.ata

import android.content.ContentResolver
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.Uri
import android.provider.OpenableColumns
import com.ata.core.AtaException
import com.ata.core.AtaLog
import com.ata.core.ErrorCode
import com.ata.core.SourceFile
import com.ata.core.TcpLanDialer
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.Inet4Address
import java.net.InetAddress

/**
 * Resolves shared URIs to [SourceFile]s: display name and size via ContentResolver, content read lazily by
 * streaming. Runs on a background thread. When the provider does not report a size, the stream is read
 * once to count bytes (never buffered in memory).
 */
fun resolveSources(ctx: Context, uris: List<Uri>, log: AtaLog): List<SourceFile> {
    val cr = ctx.contentResolver
    return uris.mapIndexed { i, uri ->
        var name: String? = null
        var size: Long? = null
        if (uri.scheme == ContentResolver.SCHEME_FILE) {
            val f = File(uri.path ?: "")
            name = f.name
            size = f.length().takeIf { f.isFile }
        } else {
            try {
                cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        val si = c.getColumnIndex(OpenableColumns.SIZE)
                        if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                        if (si >= 0 && !c.isNull(si)) size = c.getLong(si).takeIf { it >= 0 }
                    }
                }
            } catch (e: Exception) {
                log.i("source ${i + 1}: metadata query failed: ${e.javaClass.simpleName}")
            }
        }
        val open = {
            cr.openInputStream(uri) ?: throw IOException("provider returned no stream")
        }
        val n = size ?: try {
            open().use { countBytes(it) }.also { log.i("source ${i + 1}: provider gave no size; counted $it B") }
        } catch (e: Exception) {
            throw AtaException(ErrorCode.FILE_UNREADABLE, "cannot read shared item ${i + 1}: ${e.javaClass.simpleName}", e)
        }
        SourceFile(safeName(name ?: uri.lastPathSegment, i), n, open)
    }
}

/** The Mac keeps only the last path component; strip separators here too so the UI shows what the Mac will save. */
fun safeName(raw: String?, index: Int): String {
    val base = raw.orEmpty().substringAfterLast('/').substringAfterLast('\\').trim().filter { it >= ' ' }
    return when {
        base.isEmpty() || base == "." || base == ".." -> "file-${index + 1}"
        else -> base.take(200)
    }
}

private fun countBytes(ins: InputStream): Long {
    val buf = ByteArray(64 * 1024)
    var n = 0L
    while (true) {
        val r = ins.read(buf)
        if (r < 0) return n
        n += r
    }
}

/**
 * LAN dialer for SPEC §7a: each `accept.lan` address is dialled on the Wi-Fi (or Ethernet) [Network] whose
 * IPv4 subnet contains it, with the socket bound to that network so traffic never leaks onto cellular or a VPN.
 */
fun androidLanDialer(ctx: Context, log: AtaLog): TcpLanDialer {
    val cm = ctx.getSystemService(ConnectivityManager::class.java)
    return TcpLanDialer(log, timeoutMs = 1_500) { sock, addr ->
        val net = localNetworkFor(cm, addr)
        if (net == null) false else {
            net.bindSocket(sock)
            true
        }
    }
}

private fun localNetworkFor(cm: ConnectivityManager, ip: InetAddress): Network? {
    @Suppress("DEPRECATION")
    for (n in cm.allNetworks) {
        val caps = cm.getNetworkCapabilities(n) ?: continue
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
        val lp = cm.getLinkProperties(n) ?: continue
        if (lp.linkAddresses.any { it.address is Inet4Address && TcpLanDialer.sameSubnet(it.address, ip, it.prefixLength) }) return n
    }
    return null
}
