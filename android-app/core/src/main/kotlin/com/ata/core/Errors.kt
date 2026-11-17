package com.ata.core

/** Every failure the user can see maps to one of these codes; the Android layer turns them into text. */
enum class ErrorCode {
    /** No device advertising the ATA service was found over BLE. */
    MAC_NOT_FOUND,
    /** A Mac was found but this phone has no pairing for it. */
    NOT_PAIRED,
    /** The Mac answered auth_fail unknown_device / bad_mac: the pairing was removed on the Mac. */
    PAIRING_REMOVED,
    /** auth_fail pairing_expired (QR code older than 5 minutes or already used). */
    PAIRING_EXPIRED,
    /** auth_fail busy. */
    MAC_BUSY,
    /** Protocol version mismatch (hello.v != 2, auth_fail bad_version, or QR v != 2). */
    BAD_VERSION,
    /** The Mac's auth_ok HMAC did not verify: possible impostor. */
    MAC_AUTH_FAILED,
    /** The Mac sent `reject`. */
    REJECTED,
    /** Neither LAN TCP nor WebRTC could be established. */
    NO_PATH,
    /** SPEC §7c: the phone's temporary hotspot could not be started, or the Mac could not join it. */
    HOTSPOT_FAILED,
    /** A path was established but the transfer broke (disconnect, timeout, bad record, decrypt failure). */
    INTERRUPTED,
    /** One or more files were reported `ok:false` by the Mac. */
    FILE_FAILED,
    /** A shared file could not be read, or changed size while sending. */
    FILE_UNREADABLE,
    CANCELLED,
    BLUETOOTH_OFF,
    PERMISSION_DENIED,
    BAD_PAIRING_CODE,
    /** BLE dropped or the Mac sent something unexpected during the handshake / signalling. */
    CONNECTION_LOST,
    PROTOCOL,
}

class AtaException(val code: ErrorCode, val detail: String, cause: Throwable? = null) :
    Exception("$code: $detail", cause)

/** Protocol-level logger. Implementations must never receive keys or the pairing URI. */
fun interface AtaLog {
    fun i(msg: String)
}
