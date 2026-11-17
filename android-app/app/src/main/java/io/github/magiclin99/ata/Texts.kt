package io.github.magiclin99.ata

import android.content.Context
import android.text.format.Formatter
import com.ata.core.ErrorCode

/** The project site's short address, shown as text the user can type on the Mac (no scheme, easy to read aloud). */
const val SITE_SHORT = "magiclin99.github.io/ata"

/**
 * Plain-language failure text (internal TERMS.md): what happened, then one thing to try. Never shows codes or raw
 * system text; [detail] is only used to pick the right sentence for a Mac `reject` reason.
 */
fun errorText(ctx: Context, code: ErrorCode?, detail: String? = null, macName: String? = null): String = when (code) {
    ErrorCode.MAC_NOT_FOUND -> if (macName.isNullOrBlank()) ctx.getString(R.string.err_mac_not_found) else ctx.getString(R.string.err_mac_not_found_named, macName)
    ErrorCode.NOT_PAIRED -> ctx.getString(R.string.err_not_paired)
    ErrorCode.PAIRING_REMOVED -> ctx.getString(R.string.err_pairing_removed)
    ErrorCode.PAIRING_EXPIRED -> ctx.getString(R.string.err_pairing_expired)
    ErrorCode.MAC_BUSY -> ctx.getString(R.string.err_mac_busy)
    ErrorCode.BAD_VERSION -> ctx.getString(R.string.err_bad_version, SITE_SHORT)
    ErrorCode.MAC_AUTH_FAILED -> ctx.getString(R.string.err_mac_auth_failed)
    ErrorCode.REJECTED -> ctx.getString(
        when {
            detail?.contains("no_space") == true -> R.string.err_rejected_space
            detail?.contains("save_folder") == true -> R.string.err_rejected_folder
            else -> R.string.err_rejected
        }
    )
    ErrorCode.NO_PATH -> ctx.getString(R.string.err_no_path)
    ErrorCode.HOTSPOT_FAILED -> ctx.getString(R.string.err_hotspot_failed)
    ErrorCode.HOTSPOT_UNREACHABLE -> ctx.getString(R.string.err_hotspot_unreachable)
    ErrorCode.INTERRUPTED -> ctx.getString(R.string.err_interrupted)
    ErrorCode.FILE_FAILED -> ctx.getString(R.string.err_file_failed)
    ErrorCode.FILE_UNREADABLE -> ctx.getString(R.string.err_file_unreadable)
    ErrorCode.CANCELLED -> ctx.getString(R.string.err_cancelled)
    ErrorCode.BLUETOOTH_OFF -> ctx.getString(R.string.err_bluetooth_off)
    ErrorCode.PERMISSION_DENIED -> ctx.getString(R.string.err_permission)
    ErrorCode.BAD_PAIRING_CODE -> ctx.getString(R.string.err_bad_pairing_code)
    ErrorCode.CONNECTION_LOST -> ctx.getString(R.string.err_connection_lost)
    ErrorCode.PROTOCOL, null -> ctx.getString(R.string.err_protocol)
}

/** "What happened" part of [errorText]: its first sentence, for the one-line history row. */
fun shortErrorText(ctx: Context, code: ErrorCode?): String {
    val full = errorText(ctx, code)
    val zh = full.indexOf('。')
    if (zh >= 0) return full.substring(0, zh)
    val en = full.indexOf(". ")
    return if (en >= 0) full.substring(0, en) else full.trimEnd('.')
}

/**
 * True when [time] is less than a minute before [now] (or slightly after it, if the clock moved back): the history
 * then reads "Just now" instead of the system's "0 minutes ago".
 */
fun isJustNow(time: Long, now: Long): Boolean = now - time < 60_000L

/**
 * Mobile data used, rounded for a sentence like "used about 2.4 MB of mobile data". Anything above zero shows at
 * least "1 kB" so a tiny transfer still reads honestly instead of "0 B".
 */
fun mobileDataText(ctx: Context, bytes: Long): String = Formatter.formatShortFileSize(ctx, bytes.coerceAtLeast(1000))

fun phaseText(ctx: Context, s: TransferState): String {
    val mac = s.macName.orEmpty()
    return when (s.phase) {
        Phase.PREPARING -> ctx.getString(R.string.phase_preparing)
        Phase.SEARCHING -> ctx.getString(R.string.phase_searching, mac)
        Phase.CONNECTING -> ctx.getString(R.string.phase_connecting, mac)
        Phase.WAITING -> ctx.getString(R.string.phase_waiting, mac)
        Phase.LAN -> ctx.getString(R.string.phase_lan)
        Phase.RTC -> ctx.getString(R.string.phase_rtc)
        Phase.HOTSPOT -> ctx.getString(if (s.hotspotWaitingMac) R.string.phase_hotspot_firewall else R.string.phase_hotspot, mac)
        Phase.SENDING -> ctx.getString(R.string.phase_sending, mac)
        Phase.DONE -> if (s.cellularBytes > 0) ctx.getString(R.string.phase_done_cellular, mac, mobileDataText(ctx, s.cellularBytes))
        else ctx.getString(R.string.phase_done, mac)
        Phase.FAILED -> ctx.getString(R.string.phase_failed)
        Phase.CANCELLED -> ctx.getString(R.string.phase_cancelled)
    }
}
