package io.github.magiclin99.ata

import android.content.Context
import com.ata.core.ErrorCode
import com.ata.core.Path

fun pathLabel(ctx: Context, path: Path?): String = when (path) {
    Path.LAN -> ctx.getString(R.string.via_lan)
    Path.RTC -> ctx.getString(R.string.via_rtc)
    null -> ""
}

fun pathLabel(ctx: Context, wire: String?): String = pathLabel(ctx, Path.entries.firstOrNull { it.wire == wire })

/** Human-readable, specific failure text. [detail] is only shown for `reject` (the Mac's reason). */
fun errorText(ctx: Context, code: ErrorCode?, detail: String? = null, macName: String? = null): String = when (code) {
    ErrorCode.MAC_NOT_FOUND -> if (macName.isNullOrBlank()) ctx.getString(R.string.err_mac_not_found) else ctx.getString(R.string.err_mac_not_found_named, macName)
    ErrorCode.NOT_PAIRED -> ctx.getString(R.string.err_not_paired)
    ErrorCode.PAIRING_REMOVED -> ctx.getString(R.string.err_pairing_removed)
    ErrorCode.PAIRING_EXPIRED -> ctx.getString(R.string.err_pairing_expired)
    ErrorCode.MAC_BUSY -> ctx.getString(R.string.err_mac_busy)
    ErrorCode.BAD_VERSION -> ctx.getString(R.string.err_bad_version)
    ErrorCode.MAC_AUTH_FAILED -> ctx.getString(R.string.err_mac_auth_failed)
    ErrorCode.REJECTED -> ctx.getString(R.string.err_rejected, detail.orEmpty())
    ErrorCode.NO_PATH -> ctx.getString(R.string.err_no_path)
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

fun phaseText(ctx: Context, s: TransferState): String {
    val mac = s.macName.orEmpty()
    return when (s.phase) {
        Phase.PREPARING -> ctx.getString(R.string.phase_preparing)
        Phase.SEARCHING -> ctx.getString(R.string.phase_searching, mac)
        Phase.CONNECTING -> ctx.getString(R.string.phase_connecting, mac)
        Phase.WAITING -> ctx.getString(R.string.phase_waiting, mac)
        Phase.LAN -> ctx.getString(R.string.phase_lan)
        Phase.RTC -> ctx.getString(R.string.phase_rtc)
        Phase.SENDING -> ctx.getString(R.string.phase_sending, mac, pathLabel(ctx, s.path))
        Phase.DONE -> ctx.getString(R.string.phase_done, mac, pathLabel(ctx, s.path))
        Phase.FAILED -> ctx.getString(R.string.phase_failed)
        Phase.CANCELLED -> ctx.getString(R.string.phase_cancelled)
    }
}
