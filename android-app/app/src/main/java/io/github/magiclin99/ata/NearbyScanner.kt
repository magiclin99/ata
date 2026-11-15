package io.github.magiclin99.ata

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.SystemClock
import androidx.core.content.ContextCompat
import com.ata.core.AtaException
import com.ata.core.AtaLog
import com.ata.core.NameHint
import com.ata.core.PhoneHandshake
import io.github.magiclin99.ata.ui.hasBlePermissions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** A paired Mac currently seen over BLE. [address] lets the transfer connect without scanning again. */
data class NearbyMac(val idHex: String, val address: String, val rssi: Int, val lastSeen: Long)

enum class ScanStatus { IDLE, SCANNING, NO_PERMISSION, BLUETOOTH_OFF, FAILED }

/**
 * Continuous BLE scan for the device picker (SPEC §3a). A paired Mac is "nearby" while its advertisement keeps
 * arriving. Identity comes from the local-name hint `ATA-<8 hex>`; when a scan record has no usable name, the
 * device is probed once (connect → `hello.id` → disconnect, no `auth`) and the address → Mac mapping cached.
 */
@SuppressLint("MissingPermission")
class NearbyScanner(private val ctx: Context, private val log: AtaLog) {

    private val _nearby = MutableStateFlow<Map<String, NearbyMac>>(emptyMap())
    val nearby: StateFlow<Map<String, NearbyMac>> = _nearby
    private val _status = MutableStateFlow(ScanStatus.IDLE)
    val status: StateFlow<ScanStatus> = _status

    /** Elapsed-realtime when the current scan started; the UI says "searching" for a few seconds after. */
    @Volatile var startedAt = 0L
        private set

    private val adapter: BluetoothAdapter? get() = ctx.getSystemService(BluetoothManager::class.java)?.adapter
    private var scope: CoroutineScope? = null
    private var callback: ScanCallback? = null
    @Volatile private var pairedIds: Set<String> = emptySet()

    /** address → macId (lowercase hex) learned from a name or `hello`; "" = not one of ours. */
    private val addressMap = HashMap<String, String>()
    /** address → elapsed time of the last failed probe. */
    private val probeFailedAt = HashMap<String, Long>()
    private val probing = HashSet<String>()
    /** Addresses whose raw scan record has been logged once. */
    private val loggedRecords = HashSet<String>()
    private val probeQueue = Channel<Pair<String, android.bluetooth.BluetoothDevice>>(Channel.UNLIMITED)

    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> if (scope != null) startScan()
                BluetoothAdapter.STATE_OFF, BluetoothAdapter.STATE_TURNING_OFF -> {
                    stopScan(); _nearby.value = emptyMap(); _status.value = ScanStatus.BLUETOOTH_OFF
                }
            }
        }
    }

    /** Starts scanning (idempotent). Status reports why it could not. */
    fun start(paired: Collection<String>) {
        pairedIds = paired.map { it.lowercase() }.toSet()
        if (scope != null) {
            if (_status.value != ScanStatus.SCANNING) startScan()
            return
        }
        val s = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        scope = s
        ContextCompat.registerReceiver(ctx, btReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        s.launch { probeWorker() }
        s.launch {
            // Expire Macs whose advertisements stopped arriving.
            while (isActive) {
                delay(1_000)
                val now = SystemClock.elapsedRealtime()
                val cutoff = now - STALE_MS
                var expired = false
                _nearby.update { m ->
                    if (m.values.any { it.lastSeen < cutoff }) { expired = true; m.filterValues { it.lastSeen >= cutoff } } else m
                }
                // Some controllers report each advertiser only once per scan; a fresh scan re-reports it. Rate-limited
                // well below Android's 5-starts-per-30-s cap so the scan is never throttled.
                if (expired && _status.value == ScanStatus.SCANNING && now - lastRestart > RESTART_MIN_MS) {
                    lastRestart = now
                    log.i("nearby: entry expired; restarting scan")
                    startScan(resetClock = false)
                }
            }
        }
        startScan()
    }

    /** Updates the paired set (e.g. after pairing from the picker) without restarting the scan. */
    fun updatePaired(paired: Collection<String>) {
        pairedIds = paired.map { it.lowercase() }.toSet()
        _nearby.update { m -> m.filterKeys { it in pairedIds } }
    }

    fun stop() {
        stopScan()
        scope?.cancel()
        if (scope != null) runCatching { ctx.unregisterReceiver(btReceiver) }
        scope = null
        synchronized(this) { probing.clear() }
        _status.value = ScanStatus.IDLE
    }

    @Volatile private var lastRestart = 0L

    private fun startScan(resetClock: Boolean = true) {
        if (!ctx.hasBlePermissions()) {
            _status.value = ScanStatus.NO_PERMISSION; return
        }
        val a = adapter
        if (a == null || !a.isEnabled) {
            _status.value = ScanStatus.BLUETOOTH_OFF; return
        }
        val scanner = a.bluetoothLeScanner ?: run { _status.value = ScanStatus.BLUETOOTH_OFF; return }
        stopScan()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) = onResult(r)
            override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { onResult(it) }
            override fun onScanFailed(errorCode: Int) {
                log.i("nearby: scan failed ($errorCode)")
                _status.value = ScanStatus.FAILED
            }
        }
        try {
            scanner.startScan(null, ataScanSettings(a, log), cb)
        } catch (e: SecurityException) {
            _status.value = ScanStatus.NO_PERMISSION; return
        }
        callback = cb
        if (resetClock || startedAt == 0L) startedAt = SystemClock.elapsedRealtime()
        _status.value = ScanStatus.SCANNING
        log.i("nearby: scanning")
    }

    private fun stopScan() {
        val cb = callback ?: return
        callback = null
        runCatching { adapter?.bluetoothLeScanner?.stopScan(cb) }
    }

    private fun onResult(r: ScanResult) {
        if (r.scanRecord?.serviceUuids?.any { it.uuid == com.ata.core.Ble.SERVICE } != true) return
        val address = r.device.address
        val now = SystemClock.elapsedRealtime()
        if (synchronized(this) { loggedRecords.add(address) }) {
            log.i("nearby: $address name=${r.scanRecord?.deviceName} rssi=${r.rssi} ${describeScanRecord(r)}")
        }
        val id: String? = when (val m = NameHint.match(r.scanRecord?.deviceName, pairedIds)) {
            is NameHint.Match.Paired -> m.idHex.also { synchronized(this) { addressMap[address] = it } }
            NameHint.Match.Unpaired -> null
            NameHint.Match.Ambiguous, NameHint.Match.NoHint -> {
                val known = synchronized(this) { addressMap[address] }
                if (known == null) maybeProbe(address, r.device, now)
                known?.takeIf { it.isNotEmpty() && it in pairedIds }
            }
        }
        if (id != null) {
            _nearby.update { it + (id to NearbyMac(id, address, r.rssi, now)) }
        }
    }

    private fun maybeProbe(address: String, device: android.bluetooth.BluetoothDevice, now: Long) {
        synchronized(this) {
            if (address in probing) return
            val failed = probeFailedAt[address]
            if (failed != null && now - failed < PROBE_RETRY_MS) return
            probing += address
        }
        probeQueue.trySend(address to device)
    }

    /** One probe at a time; each holds the GATT connection only long enough to read `hello`. */
    private suspend fun probeWorker() {
        val app = ctx.applicationContext as AtaApp
        val hs = PhoneHandshake(app.identity.phoneId, app.identity.phoneName, log)
        for ((address, device) in probeQueue) {
            var link: BleLink? = null
            try {
                link = BleLink.connect(ctx, device, log)
                val hello = hs.readHello(link, timeoutMs = 5_000)
                log.i("nearby: $address is Mac ${hello.macIdHex} (probed)")
                synchronized(this) { addressMap[address] = hello.macIdHex }
                if (hello.macIdHex in pairedIds) {
                    _nearby.update { it + (hello.macIdHex to NearbyMac(hello.macIdHex, address, 0, SystemClock.elapsedRealtime())) }
                }
            } catch (e: AtaException) {
                log.i("nearby: probe $address failed: ${e.code}")
                synchronized(this) { probeFailedAt[address] = SystemClock.elapsedRealtime() }
            } finally {
                link?.close()
                synchronized(this) { probing -= address }
            }
        }
    }

    private companion object {
        const val STALE_MS = 10_000L
        const val PROBE_RETRY_MS = 15_000L
        const val RESTART_MIN_MS = 10_000L
    }
}
