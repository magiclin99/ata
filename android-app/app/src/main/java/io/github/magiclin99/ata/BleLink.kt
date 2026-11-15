package io.github.magiclin99.ata

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.SystemClock
import com.ata.core.AtaException
import com.ata.core.AtaLog
import com.ata.core.Ble
import com.ata.core.ErrorCode
import com.ata.core.LinkClosedException
import com.ata.core.MessageLink
import com.ata.core.Reassembler
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/** A device advertising the ATA v2 service. */
data class Found(val device: BluetoothDevice, val rssi: Int, val name: String? = null)

/**
 * Scans for the ATA service. No hardware filter: the UUID is matched in software (as in the device-verified
 * v1 lab, which saw macOS advertisements that hardware filters missed). Returns as soon as the scan has
 * settled: [settleMs] after the first match, or empty after [timeoutMs].
 */
@SuppressLint("MissingPermission")
suspend fun scanForMacs(
    ctx: Context,
    log: AtaLog,
    timeoutMs: Long = 10_000,
    settleMs: Long = 1_500,
    /** Ends the scan immediately when a result satisfies this (e.g. the wanted Mac's name hint). */
    stopWhen: (Found) -> Boolean = { false },
): List<Found> {
    val adapter = ctx.getSystemService(BluetoothManager::class.java)?.adapter
    if (adapter == null || !adapter.isEnabled) throw AtaException(ErrorCode.BLUETOOTH_OFF, "Bluetooth is off")
    val scanner = adapter.bluetoothLeScanner ?: throw AtaException(ErrorCode.BLUETOOTH_OFF, "no LE scanner")
    val found = LinkedHashMap<String, Found>()
    val first = CompletableDeferred<Unit>()
    val wanted = CompletableDeferred<Unit>()
    val failed = CompletableDeferred<Int>()
    val cb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, r: ScanResult) {
            if (r.scanRecord?.serviceUuids?.any { it.uuid == Ble.SERVICE } != true) return
            val f = Found(r.device, r.rssi, r.scanRecord?.deviceName)
            synchronized(found) {
                if (!found.containsKey(r.device.address)) log.i("scan: ATA service at ${r.device.address} name=${f.name} rssi=${r.rssi} ${describeScanRecord(r)}")
                found[r.device.address] = f
            }
            first.complete(Unit)
            if (stopWhen(f)) wanted.complete(Unit)
        }

        override fun onScanFailed(errorCode: Int) {
            failed.complete(errorCode)
        }
    }
    val settings = ataScanSettings(adapter, log)
    val t0 = SystemClock.elapsedRealtime()
    log.i("scan: start")
    scanner.startScan(null, settings, cb)
    try {
        val got = withTimeoutOrNull(timeoutMs) {
            kotlinx.coroutines.selects.select {
                first.onAwait { true }
                failed.onAwait { code -> throw AtaException(ErrorCode.MAC_NOT_FOUND, "scan failed ($code)") }
            }
        }
        if (got == true && !wanted.isCompleted) withTimeoutOrNull(settleMs) { wanted.await() }
    } finally {
        runCatching { scanner.stopScan(cb) }
    }
    val list = synchronized(found) { found.values.sortedByDescending { it.rssi } }
    log.i("scan: ${list.size} ATA device(s) in ${SystemClock.elapsedRealtime() - t0} ms")
    return list
}

/**
 * One GATT connection to a Mac as a [MessageLink]. All GATT operations are serialized and each waits for its
 * callback (Android allows one outstanding operation). Received fragments are reassembled into [inbox].
 */
@SuppressLint("MissingPermission")
class BleLink private constructor(private val ctx: Context, private val log: AtaLog) : MessageLink {

    private enum class OpKind { MTU, DISCOVER, WRITE_DESC, WRITE_CHAR }
    private class PendingOp(val kind: OpKind, val result: CompletableDeferred<Any?>)

    private val opMutex = Mutex()
    private val sendMutex = Mutex()
    private val reassembler = Reassembler()
    private val inbox = Channel<ByteArray>(Channel.UNLIMITED)
    private val connected = CompletableDeferred<Unit>()

    @Volatile private var gatt: BluetoothGatt? = null
    @Volatile private var rx: BluetoothGattCharacteristic? = null
    @Volatile private var pending: PendingOp? = null
    @Volatile private var closed = false
    @Volatile var mtu = 23
        private set

    companion object {
        /** connectGatt → MTU 517 → discover → subscribe TX. After this the Mac sends `hello`. */
        suspend fun connect(ctx: Context, device: BluetoothDevice, log: AtaLog): BleLink {
            val link = BleLink(ctx, log)
            try {
                link.open(device)
            } catch (e: Exception) {
                link.close()
                if (e is AtaException || e is kotlinx.coroutines.CancellationException) throw e
                throw AtaException(ErrorCode.CONNECTION_LOST, "BLE connect: ${e.message}", e)
            }
            return link
        }
    }

    private suspend fun open(device: BluetoothDevice) {
        val t0 = SystemClock.elapsedRealtime()
        log.i("gatt: connect ${device.address}")
        val g = device.connectGatt(ctx, false, callback, BluetoothDevice.TRANSPORT_LE)
            ?: throw IllegalStateException("connectGatt returned null")
        gatt = g
        try {
            withTimeout(12_000) { connected.await() }
        } catch (e: TimeoutCancellationException) {
            throw IllegalStateException("connect timeout")
        }
        try {
            // Short timeout: some Android 14+ stacks never call back for an MTU they already negotiated.
            mtu = op(OpKind.MTU, "requestMtu", 2_000) { it.requestMtu(Ble.REQUESTED_MTU).ok("requestMtu") }
        } catch (e: TimeoutCancellationException) {
            // Android 14+ may already have negotiated 517 and not call back again.
            log.i("gatt: no MTU callback; using $mtu")
        }
        op<Unit>(OpKind.DISCOVER, "discoverServices") { it.discoverServices().ok("discoverServices") }
        var svc = g.getService(Ble.SERVICE)
        if (svc == null) {
            // Android caches GATT tables per address. If this Mac previously exposed another layout (e.g. the v1 lab
            // service), discovery returns the stale table. Clear the cache once and rediscover.
            log.i("gatt: ATA service missing after discovery (cached services: ${g.services.map { it.uuid }}); refreshing GATT cache")
            val refreshed = refreshGattCache(g)
            log.i("gatt: refresh() ${if (refreshed) "ok" else "unavailable or failed"}; rediscovering in 600 ms")
            delay(600)
            op<Unit>(OpKind.DISCOVER, "discoverServices (after refresh)") { it.discoverServices().ok("discoverServices") }
            svc = g.getService(Ble.SERVICE)
            log.i("gatt: after refresh: ${if (svc != null) "ATA service found" else "still missing; services=${g.services.map { it.uuid }}"}")
        }
        if (svc == null) throw IllegalStateException("ATA service not found on device (after GATT cache refresh)")
        val rxc = svc.getCharacteristic(Ble.RX) ?: throw IllegalStateException("RX characteristic missing")
        val txc = svc.getCharacteristic(Ble.TX) ?: throw IllegalStateException("TX characteristic missing")
        rx = rxc
        if (!g.setCharacteristicNotification(txc, true)) throw IllegalStateException("setCharacteristicNotification failed")
        val cccd = txc.getDescriptor(Ble.CCCD) ?: throw IllegalStateException("TX has no CCCD")
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        op<Unit>(OpKind.WRITE_DESC, "write CCCD") { gg ->
            if (Build.VERSION.SDK_INT >= 33) {
                val rc = gg.writeDescriptor(cccd, enable)
                if (rc != BluetoothStatusCodes.SUCCESS) throw IllegalStateException("writeDescriptor rc=$rc")
            } else {
                @Suppress("DEPRECATION")
                cccd.value = enable
                @Suppress("DEPRECATION")
                gg.writeDescriptor(cccd).ok("writeDescriptor")
            }
        }
        log.i("gatt: ready in ${SystemClock.elapsedRealtime() - t0} ms, mtu=$mtu")
    }

    override suspend fun send(message: ByteArray) = sendMutex.withLock {
        if (closed || rx == null) throw LinkClosedException("BLE not connected")
        for (f in Ble.fragment(message, Ble.maxFragmentLen(mtu))) writeRx(f)
    }

    override suspend fun receive(): ByteArray = try {
        inbox.receive()
    } catch (e: kotlinx.coroutines.channels.ClosedReceiveChannelException) {
        throw LinkClosedException("BLE link closed", e)
    }

    override fun close() {
        if (closed) return
        closed = true
        val g = gatt
        gatt = null
        rx = null
        if (g != null) {
            log.i("gatt: disconnect")
            runCatching { g.disconnect() }
            runCatching { g.close() }
        }
        val ex = LinkClosedException("closed")
        pending?.result?.completeExceptionally(ex)
        connected.completeExceptionally(ex)
        inbox.close()
    }

    private suspend fun writeRx(value: ByteArray) {
        val c = rx ?: throw LinkClosedException("RX not available")
        var attempt = 0
        while (true) {
            try {
                op<Unit>(OpKind.WRITE_CHAR, "write RX") { g ->
                    if (Build.VERSION.SDK_INT >= 33) {
                        val rc = g.writeCharacteristic(c, value, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                        if (rc != BluetoothStatusCodes.SUCCESS) throw BusyException("writeCharacteristic rc=$rc")
                    } else {
                        @Suppress("DEPRECATION")
                        c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                        @Suppress("DEPRECATION")
                        c.value = value
                        @Suppress("DEPRECATION")
                        if (!g.writeCharacteristic(c)) throw BusyException("writeCharacteristic returned false")
                    }
                }
                return
            } catch (e: BusyException) {
                if (++attempt >= 3) throw LinkClosedException("${e.message} after $attempt attempts")
                delay(50L * attempt)
            } catch (e: TimeoutCancellationException) {
                throw LinkClosedException("write timeout")
            }
        }
    }

    private class BusyException(msg: String) : Exception(msg)

    private fun Boolean.ok(what: String) {
        if (!this) throw IllegalStateException("$what returned false")
    }

    private suspend fun <T> op(kind: OpKind, name: String, timeoutMs: Long = 10_000, start: (BluetoothGatt) -> Unit): T =
        opMutex.withLock {
            val g = gatt ?: throw LinkClosedException("$name: not connected")
            val d = CompletableDeferred<Any?>()
            pending = PendingOp(kind, d)
            try {
                start(g)
                @Suppress("UNCHECKED_CAST")
                withTimeout(timeoutMs) { d.await() } as T
            } finally {
                pending = null
            }
        }

    private fun complete(kind: OpKind, status: Int, value: Any?, what: String) {
        val p = pending
        if (p == null || p.kind != kind) return
        if (status == BluetoothGatt.GATT_SUCCESS) p.result.complete(value)
        else p.result.completeExceptionally(LinkClosedException("$what failed, GATT status=$status"))
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connected.complete(Unit)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                log.i("gatt: disconnected (status=$status)")
                val ex = LinkClosedException("disconnected (status=$status)")
                connected.completeExceptionally(ex)
                pending?.result?.completeExceptionally(ex)
                closed = true
                runCatching { g.close() }
                if (gatt === g) {
                    gatt = null; rx = null
                }
                inbox.close()
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) this@BleLink.mtu = mtu
            complete(OpKind.MTU, status, this@BleLink.mtu, "MTU")
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = complete(OpKind.DISCOVER, status, Unit, "discoverServices")

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) =
            complete(OpKind.WRITE_DESC, status, Unit, "descriptor write")

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) =
            complete(OpKind.WRITE_CHAR, status, Unit, "characteristic write")

        // API 33+ delivers the value directly; the deprecated overload is not called when this one exists.
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            if (c.uuid == Ble.TX) onFragment(value.copyOf())
        }

        @Suppress("OVERRIDE_DEPRECATION") // API < 33 path
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= 33) return
            @Suppress("DEPRECATION")
            val v = c.value ?: return
            if (c.uuid == Ble.TX) onFragment(v.copyOf())
        }
    }

    private fun onFragment(f: ByteArray) {
        val msg = try {
            reassembler.accept(f)
        } catch (e: IllegalArgumentException) {
            log.i("BLE <- bad fragment (${e.message}); closing")
            close()
            return
        } ?: return
        inbox.trySend(msg)
    }
}


/** Hidden `BluetoothGatt.refresh()`: drops Android's cached GATT table for this device. */
private fun refreshGattCache(g: BluetoothGatt): Boolean = try {
    val m = g.javaClass.getMethod("refresh")
    m.invoke(g) as? Boolean ?: false
} catch (e: Throwable) {
    false
}

/**
 * Low-latency scan. LOW_LATENCY scans are active on Android, so scan responses (where macOS may put the local name)
 * are requested. Where the controller supports extended advertising, `setLegacy(false)` reports both legacy and
 * extended advertisements, on all supported PHYs.
 */
@SuppressLint("MissingPermission")
fun ataScanSettings(adapter: android.bluetooth.BluetoothAdapter, log: AtaLog): ScanSettings {
    val b = ScanSettings.Builder()
        .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
        .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
        .setReportDelay(0)
    val extended = runCatching { adapter.isLeExtendedAdvertisingSupported }.getOrDefault(false)
    if (extended) {
        b.setLegacy(false)
        b.setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
    }
    if (!loggedSettings) {
        loggedSettings = true
        log.i("scan settings: low-latency (active), extendedAdv=$extended legacyOnly=${!extended}")
    }
    return b.build()
}

@Volatile private var loggedSettings = false

/**
 * Raw scan-record facts for the log: total raw length, bytes actually used by AD structures, AD types present
 * (0x08/0x09 = local name), and whether the record is legacy. A legacy record whose used length exceeds 31 B
 * includes a scan response.
 */
fun describeScanRecord(r: ScanResult): String {
    val raw = r.scanRecord?.bytes ?: return "record=none"
    var i = 0
    val types = ArrayList<String>()
    while (i < raw.size) {
        val len = raw[i].toInt() and 0xff
        if (len == 0 || i + len >= raw.size) break
        types += "%02x".format(raw[i + 1].toInt() and 0xff)
        i += len + 1
    }
    return "record=${raw.size}B used=${i}B adTypes=$types legacy=${r.isLegacy}"
}
