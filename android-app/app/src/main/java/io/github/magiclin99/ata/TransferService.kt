package io.github.magiclin99.ata

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.IBinder
import android.os.Process
import android.os.SystemClock
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.ata.core.AtaException
import com.ata.core.ErrorCode
import com.ata.core.NameHint
import com.ata.core.Path
import com.ata.core.PhoneHandshake
import com.ata.core.SourceFile
import com.ata.core.Stage
import com.ata.core.TransferEngine
import com.ata.core.TransferListener
import com.ata.core.TransferOutcome
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class Phase { PREPARING, SEARCHING, CONNECTING, WAITING, LAN, RTC, SENDING, DONE, FAILED, CANCELLED;
    val terminal get() = this == DONE || this == FAILED || this == CANCELLED
}

enum class FileStatus { PENDING, SENDING, OK, FAILED }

data class FileItem(val name: String, val size: Long, val sent: Long = 0, val status: FileStatus = FileStatus.PENDING, val error: String? = null)

data class TransferState(
    val phase: Phase,
    val files: List<FileItem> = emptyList(),
    val macName: String? = null,
    val path: Path? = null,
    val totalSent: Long = 0,
    val error: ErrorCode? = null,
    val errorDetail: String? = null,
) {
    val totalSize: Long get() = files.sumOf { it.size }
    val active: Boolean get() = !phase.terminal
}

/** Shared between the service, the send sheet and the notification. One transfer at a time. */
object TransferHub {
    private val _state = MutableStateFlow<TransferState?>(null)
    val state: StateFlow<TransferState?> = _state
    internal fun set(s: TransferState?) { _state.value = s }
    internal fun update(f: (TransferState) -> TransferState) = _state.update { it?.let(f) }

    val busy: Boolean get() = _state.value?.active == true

    /** Clears a finished transfer so the next share starts fresh. */
    fun clearFinished() { if (_state.value?.active == false) _state.value = null }
}

/**
 * Runs one transfer in the foreground with a progress notification and a cancel action. Service type
 * connectedDevice: the whole job is a session with one external device (the paired Mac) over Bluetooth LE plus a
 * LAN/peer-to-peer data channel to that same device. Its runtime prerequisite (BLUETOOTH_CONNECT on API 31+) is
 * always granted before [start] is called, because the picker and the debug hooks go through the BLE gate first.
 */
class TransferService : Service() {

    companion object {
        private const val ACTION_START = "io.github.magiclin99.ata.START"
        private const val ACTION_CANCEL = "io.github.magiclin99.ata.CANCEL"
        private const val EXTRA_URIS = "uris"
        private const val EXTRA_MAC = "mac"
        private const val EXTRA_ADDRESS = "address"
        private const val EXTRA_FORCE_RTC = "forceRtc"
        private const val CHANNEL_PROGRESS = "transfer"
        private const val CHANNEL_RESULT = "result"
        private const val NOTIF_PROGRESS = 1
        private const val NOTIF_RESULT = 2

        /**
         * Sends [uris] to the paired Mac [macIdHex]. [address] is where the picker last saw it; when it is null or
         * stale the service scans for that Mac (name hint first, then `hello` probes).
         */
        fun start(ctx: Context, uris: List<Uri>, macIdHex: String, address: String? = null, forceRtc: Boolean = false) {
            val macName = (ctx.applicationContext as AtaApp).pairings.macs.value.firstOrNull { it.idHex == macIdHex }?.name
            val i = Intent(ctx, TransferService::class.java).setAction(ACTION_START)
                .putParcelableArrayListExtra(EXTRA_URIS, ArrayList(uris))
                .putExtra(EXTRA_MAC, macIdHex)
                .putExtra(EXTRA_ADDRESS, address)
                .putExtra(EXTRA_FORCE_RTC, forceRtc)
            // Re-grant read access to the service for content:// URIs we were given by the sharing app. Only URIs
            // this app actually holds a grant for can be passed on: granting one we do not hold throws a
            // SecurityException and would crash the share sheet. URIs left out here are still opened by the
            // service (same UID); if they are unreadable the transfer fails with "file unreadable", not a crash.
            val content = uris.filter {
                it.scheme == "content" &&
                    ctx.checkUriPermission(it, Process.myPid(), Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) ==
                    PackageManager.PERMISSION_GRANTED
            }
            if (content.isNotEmpty()) {
                val clip = ClipData.newRawUri("", content[0])
                content.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                i.clipData = clip
                i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            TransferHub.set(TransferState(Phase.PREPARING, macName = macName))
            try {
                ContextCompat.startForegroundService(ctx, i)
            } catch (e: SecurityException) {
                Logcat.i("service: URI grant refused (${e.javaClass.simpleName}); starting without re-grant")
                i.clipData = null
                i.removeFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                ContextCompat.startForegroundService(ctx, i)
            }
        }

        fun cancel(ctx: Context) {
            ctx.startService(Intent(ctx, TransferService::class.java).setAction(ACTION_CANCEL))
        }
    }

    // Off the main thread: the engine touches every 16–64 KiB chunk.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    private val log = Logcat
    private lateinit var nm: NotificationManager
    private var lastNotify = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL_PROGRESS, getString(R.string.notif_channel), NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(CHANNEL_RESULT, getString(R.string.notif_channel_result), NotificationManager.IMPORTANCE_DEFAULT))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (!goForeground()) {
                    TransferHub.update { it.copy(phase = Phase.FAILED, error = ErrorCode.PERMISSION_DENIED) }
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (job?.isActive == true) {
                    log.i("service: transfer already running; ignoring start")
                    return START_NOT_STICKY
                }
                @Suppress("DEPRECATION")
                val uris: List<Uri> = intent.getParcelableArrayListExtra(EXTRA_URIS) ?: emptyList()
                val mac = intent.getStringExtra(EXTRA_MAC)
                val address = intent.getStringExtra(EXTRA_ADDRESS)
                val forceRtc = intent.getBooleanExtra(EXTRA_FORCE_RTC, false)
                job = scope.launch { runTransfer(uris, mac, address, forceRtc) }
            }
            ACTION_CANCEL -> {
                log.i("service: cancel requested")
                if (job?.isActive == true) job?.cancel() else stopSelf()
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    /** False when the system refuses (Nearby devices permission revoked between the picker and here). */
    @android.annotation.SuppressLint("InlinedApi") // ServiceCompat ignores the type below API 29.
    private fun goForeground(): Boolean = try {
        ServiceCompat.startForeground(this, NOTIF_PROGRESS, progressNotification(TransferHub.state.value), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        true
    } catch (e: SecurityException) {
        log.i("service: cannot start in the foreground: ${e.javaClass.simpleName}")
        false
    }

    private suspend fun runTransfer(uris: List<Uri>, macIdHex: String?, address: String?, forceRtc: Boolean) {
        val t0 = SystemClock.elapsedRealtime()
        var sendStart = 0L
        var outcome: TransferOutcome? = null
        var failure: AtaException? = null
        var link: BleLink? = null
        val app = application as AtaApp
        val target = app.pairings.macs.value.firstOrNull { it.idHex == macIdHex }
        var macName: String? = target?.name
        try {
            TransferHub.set(TransferState(Phase.PREPARING, macName = macName))
            val sources: List<SourceFile> = withContext(Dispatchers.IO) { resolveSources(this@TransferService, uris, log) }
            if (sources.isEmpty()) throw AtaException(ErrorCode.FILE_UNREADABLE, "nothing to send")
            log.i("transfer: ${sources.size} file(s), ${sources.sumOf { it.size }} B to Mac $macIdHex")
            TransferHub.update { it.copy(phase = Phase.CONNECTING, files = sources.map { s -> FileItem(s.name, s.size) }) }
            notifyProgress(force = true)
            if (target == null) throw AtaException(ErrorCode.NOT_PAIRED, "Mac $macIdHex is not paired")
            val macId = target.idHex
            val hs = PhoneHandshake(app.identity.phoneId, app.identity.phoneName, log)

            // Fast path: the device the picker saw. Fallback: scan for this Mac.
            var chosen: Probed? = null
            if (address != null) {
                val dev = getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter
                    ?.takeIf { it.isEnabled }?.getRemoteDevice(address)
                    ?: throw AtaException(ErrorCode.BLUETOOTH_OFF, "Bluetooth is off")
                chosen = try {
                    reconnect(this, log, hs, Found(dev, 0), macId)
                } catch (e: AtaException) {
                    log.i("transfer: picker address failed (${e.code}); scanning")
                    null
                }
            }
            if (chosen == null) {
                TransferHub.update { it.copy(phase = Phase.SEARCHING) }
                notifyProgress(force = true)
                val nameHit = { f: Found -> NameHint.match(f.name, listOf(macId)) == NameHint.Match.Paired(macId) }
                val devices = scanForMacs(this, log, stopWhen = nameHit)
                    .sortedByDescending { nameHit(it) } // try the name match first
                    .filter { NameHint.match(it.name, listOf(macId)) != NameHint.Match.Unpaired }
                val probe = probeMacs(this, log, hs, devices, firstOnly = true) { it.macIdHex == macId }
                chosen = probe.matches.firstOrNull() ?: throw when {
                    probe.badVersion -> AtaException(ErrorCode.BAD_VERSION, "Mac speaks another version")
                    else -> AtaException(ErrorCode.MAC_NOT_FOUND, "Mac $macId not among ${devices.size} device(s)")
                }
                TransferHub.update { it.copy(phase = Phase.CONNECTING) }
                notifyProgress(force = true)
            }
            link = chosen.link
            val key = app.pairings.key(macId) ?: throw AtaException(ErrorCode.NOT_PAIRED, "stored key unreadable")
            val session = hs.authenticate(chosen.link, chosen.hello, key, pairing = false)
            key.fill(0)
            if (session.macName.isNotBlank() && session.macName != macName) {
                app.pairings.rename(macId, session.macName)
                macName = session.macName
                TransferHub.update { it.copy(macName = macName) }
            }

            val engine = TransferEngine(log, androidLanDialer(this, log), { AndroidRtcPeer(this, log) }, forceRtc)
            sendStart = SystemClock.elapsedRealtime()
            outcome = engine.run(session, sources, listener)
            failure = outcome.error
        } catch (e: CancellationException) {
            failure = AtaException(ErrorCode.CANCELLED, "cancelled by user")
        } catch (e: AtaException) {
            failure = e
        } catch (e: SecurityException) {
            failure = AtaException(ErrorCode.PERMISSION_DENIED, e.message ?: "")
        } catch (e: Exception) {
            failure = AtaException(ErrorCode.CONNECTION_LOST, "${e.javaClass.simpleName}: ${e.message}", e)
        } finally {
            link?.close()
        }
        finish(outcome, failure, macName, t0, sendStart)
    }

    private val listener = object : TransferListener {
        override fun onStage(stage: Stage) {
            TransferHub.update {
                when (stage) {
                    Stage.WaitingAccept -> it.copy(phase = Phase.WAITING)
                    Stage.ConnectingLan -> it.copy(phase = Phase.LAN)
                    Stage.ConnectingRtc -> it.copy(phase = Phase.RTC)
                    is Stage.Sending -> it.copy(phase = Phase.SENDING, path = stage.path)
                }
            }
            notifyProgress(force = true)
        }

        override fun onProgress(fileIndex: Int, fileSent: Long, totalSent: Long) {
            TransferHub.update { s ->
                s.copy(totalSent = totalSent, files = s.files.mapIndexed { i, f ->
                    if (i == fileIndex) f.copy(sent = fileSent, status = FileStatus.SENDING) else f
                })
            }
            notifyProgress()
        }

        override fun onFileDone(fileIndex: Int, ok: Boolean, error: String?) {
            TransferHub.update { s ->
                s.copy(files = s.files.mapIndexed { i, f ->
                    if (i == fileIndex) f.copy(sent = if (ok) f.size else f.sent, status = if (ok) FileStatus.OK else FileStatus.FAILED, error = error) else f
                })
            }
        }
    }

    private fun finish(outcome: TransferOutcome?, failure: AtaException?, macName: String?, t0: Long, sendStart: Long) {
        val ok = outcome?.ok == true && failure == null
        val now = SystemClock.elapsedRealtime()
        val via = outcome?.path
        val filesOk = outcome?.filesOk ?: 0
        val bytesOk = outcome?.bytesOk ?: 0L
        // Machine-readable result line for adb-driven tests (SPEC §9). ms covers the whole job, scan included.
        log.i("RESULT ok=$ok via=${via?.wire ?: "none"} files=$filesOk bytes=$bytesOk ms=${now - t0}")
        if (sendStart > 0) log.i("transfer: ${now - sendStart} ms after authentication${failure?.let { "; error=${it.code} ${it.detail}" } ?: ""}")
        else if (failure != null) log.i("transfer: failed before sending: ${failure.code} ${failure.detail}")

        TransferHub.update { s ->
            s.copy(
                phase = when {
                    ok -> Phase.DONE
                    failure?.code == ErrorCode.CANCELLED -> Phase.CANCELLED
                    else -> Phase.FAILED
                },
                path = via ?: s.path,
                error = if (ok) null else failure?.code,
                errorDetail = failure?.detail,
                files = s.files.mapIndexed { i, f ->
                    val o = outcome?.files?.getOrNull(i)
                    when {
                        o == null -> f
                        o.ok -> f.copy(status = FileStatus.OK, sent = f.size)
                        o.error != null -> f.copy(status = FileStatus.FAILED, error = o.error)
                        else -> f.copy(status = if (f.status == FileStatus.SENDING) FileStatus.FAILED else f.status)
                    }
                },
            )
        }
        val s = TransferHub.state.value
        if (s != null && s.files.isNotEmpty() && failure?.code != ErrorCode.CANCELLED) {
            (application as AtaApp).history.add(
                HistoryEntry(
                    System.currentTimeMillis(), macName ?: "", s.files.size, s.files.first().name,
                    if (ok) s.totalSize else bytesOk, ok, via?.wire, failure?.code?.name,
                )
            )
        }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (s != null && s.phase != Phase.CANCELLED) runCatching { nm.notify(NOTIF_RESULT, resultNotification(s)) }
        stopSelf()
    }

    // ------------------------------------------------------------ notifications

    private fun openSheet(): PendingIntent = PendingIntent.getActivity(
        this, 0, Intent(this, ShareActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun notifyProgress(force: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastNotify < 500) return
        lastNotify = now
        runCatching { nm.notify(NOTIF_PROGRESS, progressNotification(TransferHub.state.value)) }
    }

    private fun progressNotification(s: TransferState?): Notification {
        val cancel = PendingIntent.getService(
            this, 1, Intent(this, TransferService::class.java).setAction(ACTION_CANCEL), PendingIntent.FLAG_IMMUTABLE,
        )
        val b = NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_stat_ata)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentIntent(openSheet())
            .addAction(0, getString(R.string.cancel), cancel)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        val name = s?.macName
        b.setContentTitle(if (name != null) getString(R.string.notif_sending, name) else getString(R.string.notif_preparing))
        if (s != null) {
            b.setContentText(phaseText(this, s))
            if (s.phase == Phase.SENDING && s.totalSize > 0) {
                b.setProgress(1000, (s.totalSent * 1000 / s.totalSize).toInt(), false)
                b.setSubText(getString(R.string.progress_bytes, Formatter.formatShortFileSize(this, s.totalSent), Formatter.formatShortFileSize(this, s.totalSize)))
            } else if (!s.phase.terminal) {
                b.setProgress(0, 0, true)
            }
        }
        return b.build()
    }

    private fun resultNotification(s: TransferState): Notification {
        val text = if (s.phase == Phase.DONE) pathLabel(this, s.path) else errorText(this, s.error, s.errorDetail, s.macName)
        return NotificationCompat.Builder(this, CHANNEL_RESULT)
            .setSmallIcon(R.drawable.ic_stat_ata)
            .setAutoCancel(true)
            .setContentIntent(openSheet())
            .setContentTitle(
                if (s.phase == Phase.DONE) resources.getQuantityString(R.plurals.notif_done, s.files.size, s.files.size, s.macName ?: "")
                else getString(R.string.notif_failed)
            )
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .build()
    }
}
