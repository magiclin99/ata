package io.github.magiclin99.ata

import android.content.Context
import com.ata.core.AtaException
import com.ata.core.AtaLog
import com.ata.core.ErrorCode
import com.ata.core.Hello
import com.ata.core.PhoneHandshake

/** An open link to a Mac that has sent its `hello`. */
class Probed(val found: Found, val link: BleLink, val hello: Hello)

/**
 * The BLE advertisement carries only the service UUID, so the Mac's identity is learned from `hello`
 * after subscribing. Connects to each device in turn (strongest first) and keeps open the links whose
 * hello satisfies [want]; the rest are closed. Stops early after the first match when [firstOnly].
 */
class ProbeResult(val matches: List<Probed>, val helloCount: Int, val badVersion: Boolean)

suspend fun probeMacs(
    ctx: Context,
    log: AtaLog,
    hs: PhoneHandshake,
    devices: List<Found>,
    firstOnly: Boolean,
    want: (Hello) -> Boolean,
): ProbeResult {
    val matches = ArrayList<Probed>()
    var hellos = 0
    var badVersion = false
    try {
        for (d in devices) {
            val link = try {
                BleLink.connect(ctx, d.device, log)
            } catch (e: AtaException) {
                log.i("probe ${d.device.address}: ${e.detail}")
                continue
            }
            try {
                val hello = hs.readHello(link)
                hellos++
                if (want(hello)) {
                    matches += Probed(d, link, hello)
                    if (firstOnly) break
                } else {
                    log.i("probe ${d.device.address}: Mac ${hello.macIdHex} not wanted")
                    link.close()
                }
            } catch (e: AtaException) {
                if (e.code == ErrorCode.BAD_VERSION) badVersion = true
                log.i("probe ${d.device.address}: ${e.code} ${e.detail}")
                link.close()
            }
        }
    } catch (e: Throwable) {
        matches.forEach { it.link.close() }
        throw e
    }
    return ProbeResult(matches, hellos, badVersion)
}

/** Reconnects to one device and checks it is still the expected Mac. */
suspend fun reconnect(ctx: Context, log: AtaLog, hs: PhoneHandshake, found: Found, macIdHex: String): Probed {
    val link = BleLink.connect(ctx, found.device, log)
    try {
        val hello = hs.readHello(link)
        if (hello.macIdHex != macIdHex) throw AtaException(ErrorCode.MAC_NOT_FOUND, "device now reports a different Mac")
        return Probed(found, link, hello)
    } catch (e: Throwable) {
        link.close()
        throw e
    }
}
