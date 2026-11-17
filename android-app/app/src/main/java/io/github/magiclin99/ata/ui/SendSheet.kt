package io.github.magiclin99.ata.ui

import android.content.Context
import android.os.SystemClock
import android.provider.OpenableColumns
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.runtime.produceState
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.compose.LifecycleStartEffect
import io.github.magiclin99.ata.NearbyScanner
import io.github.magiclin99.ata.PairState
import io.github.magiclin99.ata.PairedMac
import io.github.magiclin99.ata.ScanStatus
import io.github.magiclin99.ata.safeName
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import android.net.Uri
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import io.github.magiclin99.ata.AndroidHotspot
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.magiclin99.ata.FileItem
import io.github.magiclin99.ata.FileStatus
import io.github.magiclin99.ata.Phase
import io.github.magiclin99.ata.BuildConfig
import io.github.magiclin99.ata.R
import io.github.magiclin99.ata.SITE_SHORT
import io.github.magiclin99.ata.TransferHub
import io.github.magiclin99.ata.TransferService
import io.github.magiclin99.ata.TransferState
import io.github.magiclin99.ata.app
import io.github.magiclin99.ata.errorText
import io.github.magiclin99.ata.phaseText

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SendSheet(
    uris: List<Uri>,
    picking: Boolean,
    scanner: NearbyScanner,
    onPick: (macIdHex: String, address: String?) -> Unit,
    onRetry: () -> Unit,
    onClose: () -> Unit,
    onHotspot: (macIdHex: String, address: String?) -> Unit = { _, _ -> },
) {
    val state by TransferHub.state.collectAsState()
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val busyElsewhere = picking && state?.active == true

    LaunchedEffect(picking, state) {
        if (!picking && state == null) onClose()
    }

    ModalBottomSheet(onDismissRequest = onClose, sheetState = sheet) {
        Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, bottom = 16.dp)) {
            val s = state
            when {
                busyElsewhere -> {
                    SheetTitle(stringResource(R.string.send_title))
                    Notice(stringResource(R.string.busy_title), stringResource(R.string.busy_text)) {
                        TextButton(onClick = onClose) { Text(stringResource(R.string.close)) }
                    }
                }
                picking -> DevicePicker(uris, scanner, onPick, onClose)
                s == null -> {
                    SheetTitle(stringResource(R.string.send_title))
                    StatusLine(stringResource(R.string.phase_preparing), working = true)
                }
                else -> {
                    SheetTitle(stringResource(R.string.send_title))
                    TransferBody(s, canRetry = uris.isNotEmpty(), onRetry = onRetry, onClose = onClose, onHotspot = onHotspot)
                }
            }
        }
    }
}

@Composable
private fun SheetTitle(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(R.drawable.ic_stat_ata), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(12.dp))
        Text(text, style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
    }
    Spacer(Modifier.size(12.dp))
}

/** Display name and size of the shared items, read from ContentResolver metadata only (no content reads). */
private data class ShareSummary(val first: String, val count: Int, val bytes: Long?)

private fun summarize(ctx: Context, uris: List<Uri>): ShareSummary {
    var first: String? = null
    var total = 0L
    var known = true
    uris.forEachIndexed { i, u ->
        var name: String? = null
        var size: Long? = null
        if (u.scheme == "file") {
            val f = java.io.File(u.path ?: "")
            name = f.name; size = f.length()
        } else runCatching {
            ctx.contentResolver.query(u, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        }
        if (i == 0) first = safeName(name ?: u.lastPathSegment, 0)
        if (size == null || size!! < 0) known = false else total += size!!
    }
    return ShareSummary(first ?: "", uris.size, if (known) total else null)
}

@Composable
private fun DevicePicker(uris: List<Uri>, scanner: NearbyScanner, onPick: (String, String?) -> Unit, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val app = ctx.app
    val gate = rememberBleGate()
    val pairing = rememberPairingActions(gate)
    val paired by app.pairings.macs.collectAsState()
    val pairState by app.pairing.state.collectAsState()
    val nearby by scanner.nearby.collectAsState()
    val status by scanner.status.collectAsState()
    val summary by produceState<ShareSummary?>(null, uris) { value = withContext(Dispatchers.IO) { summarize(ctx, uris) } }
    val pairingBusy = pairState is PairState.Searching || pairState is PairState.Connecting
    val pairedIds = paired.map { it.idHex }

    // Scan only while this picker is on screen and no pairing is using the radio.
    val scanning = paired.isNotEmpty() && !pairingBusy
    LifecycleStartEffect(scanning) {
        if (scanning) scanner.start(pairedIds)
        onStopOrDispose { scanner.stop() }
    }
    LaunchedEffect(pairedIds) { scanner.updatePaired(pairedIds) }
    // Ask for Bluetooth access as soon as the picker needs it.
    LaunchedEffect(scanning) {
        if (scanning && !ctx.hasBlePermissions()) gate.run { scanner.start(pairedIds) }
    }
    // A successful pairing returns straight to the list (the shared files are still here).
    LaunchedEffect(pairState) {
        if (pairState is PairState.Done) app.pairing.reset()
    }
    val now by produceState(SystemClock.elapsedRealtime()) {
        while (true) { delay(1_000); value = SystemClock.elapsedRealtime() }
    }
    val elapsed = if (status == ScanStatus.SCANNING) now - scanner.startedAt else 0L

    SheetTitle(stringResource(if (paired.isEmpty()) R.string.send_title else R.string.pick_title))
    summary?.let { sm ->
        val size = sm.bytes?.let { Formatter.formatShortFileSize(ctx, it) }
        Text(
            if (sm.count == 1) (if (size != null) stringResource(R.string.share_one, sm.first, size) else sm.first)
            else pluralStringResource(R.plurals.share_many, sm.count, sm.first, sm.count) + (size?.let { " · $it" } ?: ""),
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.MiddleEllipsis,
        )
        Spacer(Modifier.size(16.dp))
    }

    when {
        pairState !is PairState.Idle && pairState !is PairState.Done -> PairingInline(pairState, onDismiss = { app.pairing.reset() }, onCancel = { app.pairing.cancel() })
        paired.isEmpty() -> {
            Text(stringResource(R.string.pick_pair_title), style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.size(8.dp))
            Text(stringResource(R.string.pick_pair_text, SITE_SHORT), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.size(20.dp))
            Button(onClick = pairing.scanQr, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.scan_qr))
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                // The Mac cannot show a pairing link, so pasting one is a debug-build tool only.
                if (BuildConfig.DEBUG) TextButton(onClick = pairing.pasteLink) { Text(stringResource(R.string.paste_link)) }
                else Spacer(Modifier.width(1.dp))
                TextButton(onClick = onClose) { Text(stringResource(R.string.cancel)) }
            }
        }
        else -> {
            ScanBanner(status, anyNearby = nearby.isNotEmpty(), elapsed = elapsed, onFix = { gate.run { scanner.start(pairedIds) } })
            Spacer(Modifier.size(8.dp))
            LazyColumn(Modifier.heightIn(max = 360.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                // Stable order (pairing order): rows never jump under the user's finger as Macs come and go.
                items(paired, key = { it.idHex }) { mac ->
                    val n = nearby[mac.idHex]
                    MacPickRow(
                        mac = mac,
                        nearby = n != null,
                        searching = n == null && status == ScanStatus.SCANNING && elapsed < SEARCHING_MS,
                        onClick = {
                            val target = n ?: return@MacPickRow
                            gate.run(withNotifications = true) { onPick(mac.idHex, target.address) }
                        },
                    )
                }
            }
            Spacer(Modifier.size(8.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                TextButton(onClick = pairing.scanQr) { Text(stringResource(R.string.pair_another)) }
                TextButton(onClick = onClose) { Text(stringResource(R.string.cancel)) }
            }
        }
    }
}

private const val SEARCHING_MS = 6_000L

@Composable
private fun ScanBanner(status: ScanStatus, anyNearby: Boolean, elapsed: Long, onFix: () -> Unit) {
    when (status) {
        ScanStatus.SCANNING, ScanStatus.IDLE -> {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.heightIn(min = 24.dp)) {
                CircularProgressIndicator(Modifier.size(14.dp).clearAndSetSemantics {}, strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.scan_searching), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (!anyNearby && elapsed >= SEARCHING_MS * 2) {
                Spacer(Modifier.size(6.dp))
                Text(stringResource(R.string.scan_none_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        else -> Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
            Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(
                        when (status) {
                            ScanStatus.NO_PERMISSION -> R.string.scan_no_permission
                            ScanStatus.BLUETOOTH_OFF -> R.string.scan_bt_off
                            else -> R.string.scan_failed
                        }
                    ),
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.weight(1f),
                )
                TextButton(onClick = onFix) {
                    Text(stringResource(when (status) {
                        ScanStatus.NO_PERMISSION -> R.string.allow
                        ScanStatus.BLUETOOTH_OFF -> R.string.turn_on_bt
                        else -> R.string.retry
                    }))
                }
            }
        }
    }
}

@Composable
private fun MacPickRow(mac: PairedMac, nearby: Boolean, searching: Boolean, onClick: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val label = stringResource(if (nearby) R.string.status_nearby else if (searching) R.string.status_searching else R.string.status_away)
    // One natural sentence for screen readers ("Send to "Mac", Nearby"); the visible texts and icons below are hidden
    // from them so nothing is announced twice.
    val description = stringResource(R.string.send_to, mac.name, label)
    Surface(
        onClick = onClick,
        enabled = nearby,
        shape = MaterialTheme.shapes.large,
        color = if (nearby) colors.primaryContainer else colors.surfaceContainerHigh,
        modifier = Modifier.fillMaxWidth().semantics { contentDescription = description },
    ) {
        Row(Modifier.clearAndSetSemantics {}.heightIn(min = 72.dp).padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            Surface(shape = CircleShape, color = if (nearby) colors.primary else colors.surfaceVariant, modifier = Modifier.size(40.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(
                        painterResource(R.drawable.ic_mac), contentDescription = null, modifier = Modifier.size(22.dp),
                        tint = if (nearby) colors.onPrimary else colors.onSurfaceVariant,
                    )
                }
            }
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    mac.name, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (nearby) colors.onPrimaryContainer else colors.onSurface.copy(alpha = 0.6f),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    when {
                        nearby -> Box(Modifier.size(8.dp).background(colors.primary, CircleShape))
                        searching -> CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp)
                        else -> Box(Modifier.size(8.dp).background(colors.outline, CircleShape))
                    }
                    Spacer(Modifier.width(6.dp))
                    Text(label, style = MaterialTheme.typography.bodySmall, color = if (nearby) colors.onPrimaryContainer else colors.onSurfaceVariant)
                }
            }
            if (nearby) Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null, tint = colors.primary)
        }
    }
}

@Composable
private fun PairingInline(s: PairState, onDismiss: () -> Unit, onCancel: () -> Unit) {
    val ctx = LocalContext.current
    when (s) {
        is PairState.Searching -> StatusLine(stringResource(R.string.pairing_searching, s.macName), working = true)
        is PairState.Connecting -> StatusLine(stringResource(R.string.pairing_connecting, s.macName), working = true)
        is PairState.Failed -> {
            StatusLine(stringResource(R.string.pairing_failed), working = false, ok = false)
            Spacer(Modifier.size(8.dp))
            Text(errorText(ctx, s.code, s.detail), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        else -> {}
    }
    Spacer(Modifier.size(16.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        if (s is PairState.Failed) TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) }
        else TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
    }
}

@Composable
private fun Notice(title: String, text: String, buttons: @Composable () -> Unit) {
    Text(title, style = MaterialTheme.typography.titleMedium)
    Spacer(Modifier.size(8.dp))
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Spacer(Modifier.size(16.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { buttons() }
}

@Composable
private fun StatusLine(text: String, working: Boolean, ok: Boolean? = null) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        when {
            working -> CircularProgressIndicator(Modifier.size(20.dp).clearAndSetSemantics {}, strokeWidth = 2.5.dp)
            ok == true -> Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary)
            ok == false -> Icon(Icons.Filled.Warning, null, tint = MaterialTheme.colorScheme.error)
        }
        Spacer(Modifier.width(12.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun TransferBody(s: TransferState, canRetry: Boolean, onRetry: () -> Unit, onClose: () -> Unit, onHotspot: (String, String?) -> Unit) {
    val ctx = LocalContext.current
    val terminal = s.phase.terminal
    StatusLine(
        phaseText(ctx, s), working = !terminal,
        ok = when (s.phase) { Phase.DONE -> true; Phase.FAILED -> false; else -> null },
    )

    if (s.phase == Phase.FAILED) {
        Spacer(Modifier.size(12.dp))
        Surface(color = MaterialTheme.colorScheme.errorContainer, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
            Text(errorText(ctx, s.error, s.errorDetail, s.macName), color = MaterialTheme.colorScheme.onErrorContainer, modifier = Modifier.padding(16.dp))
        }
        val mac = s.macIdHex
        if (s.hotspotOffer && canRetry && mac != null) {
            Spacer(Modifier.size(12.dp))
            HotspotOffer(onGo = { onHotspot(mac, s.address) })
        }
    }

    // SPEC §7c: different networks, so only the internet path is left and it may fail after ~20 s. After a few
    // seconds of it, offer the phone's Wi-Fi right away instead of making the user wait for the failure.
    if (s.phase == Phase.RTC && s.hotspotOffer && canRetry && s.macIdHex != null) {
        var show by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) { delay(4_000); show = true }
        if (show) {
            Spacer(Modifier.size(12.dp))
            HotspotOffer(onGo = { onHotspot(s.macIdHex, s.address) })
        }
    }

    if (s.files.isNotEmpty()) {
        Spacer(Modifier.size(16.dp))
        val total = s.totalSize
        val sentNow = if (s.phase == Phase.DONE) total else s.totalSent
        if (!terminal) {
            if (s.phase == Phase.SENDING && total > 0) LinearProgressIndicator(progress = { sentNow.toFloat() / total }, modifier = Modifier.fillMaxWidth())
            else LinearProgressIndicator(Modifier.fillMaxWidth())
            Spacer(Modifier.size(6.dp))
        }
        Text(
            pluralStringResource(R.plurals.files_summary, s.files.size, s.files.size,
                stringResource(R.string.progress_bytes, Formatter.formatShortFileSize(ctx, sentNow), Formatter.formatShortFileSize(ctx, total))),
            style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.size(8.dp))
        LazyColumn(Modifier.heightIn(max = 260.dp)) {
            itemsIndexed(s.files) { _, f -> FileRow(f) }
        }
    }

    Spacer(Modifier.size(16.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
        if (!terminal) {
            TextButton(onClick = { TransferService.cancel(ctx) }) { Text(stringResource(R.string.cancel)) }
        } else {
            if (s.phase != Phase.DONE && canRetry) {
                TextButton(onClick = onRetry) { Text(stringResource(R.string.retry)) }
                Spacer(Modifier.width(8.dp))
            }
            Button(onClick = { TransferHub.clearFinished(); onClose() }) {
                Text(stringResource(if (s.phase == Phase.DONE) R.string.done else R.string.close))
            }
        }
    }
}

/**
 * SPEC §7c: after "couldn't reach your Mac", offer the phone's temporary Wi-Fi. Says plainly that the Mac leaves its
 * Wi-Fi for a moment, and (when Android will ask) why the permission is needed, before the system dialog appears.
 */
@Composable
private fun HotspotOffer(onGo: () -> Unit) {
    val ctx = LocalContext.current
    var denied by remember { mutableStateOf(false) }
    val needsPermission = !AndroidHotspot.hasPermission(ctx)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (AndroidHotspot.hasPermission(ctx)) onGo() else denied = true
    }
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.medium, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(R.string.hotspot_offer_title), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSecondaryContainer)
            Spacer(Modifier.size(6.dp))
            Text(stringResource(R.string.hotspot_offer_text), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSecondaryContainer)
            if (needsPermission) {
                Spacer(Modifier.size(6.dp))
                Text(stringResource(if (denied) R.string.hotspot_permission_denied else R.string.hotspot_permission_note),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSecondaryContainer)
            }
            Spacer(Modifier.size(10.dp))
            Button(
                onClick = { if (AndroidHotspot.hasPermission(ctx)) onGo() else launcher.launch(AndroidHotspot.permissions()) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) { Text(stringResource(R.string.hotspot_offer_button)) }
        }
    }
}

@Composable
private fun FileRow(f: FileItem) {
    val ctx = LocalContext.current
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp).semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(f.name, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            val sub = when (f.status) {
                FileStatus.OK -> stringResource(R.string.file_ok) + " · " + Formatter.formatShortFileSize(ctx, f.size)
                FileStatus.FAILED -> stringResource(R.string.file_failed)
                FileStatus.SENDING -> stringResource(R.string.progress_bytes, Formatter.formatShortFileSize(ctx, f.sent), Formatter.formatShortFileSize(ctx, f.size))
                FileStatus.PENDING -> Formatter.formatShortFileSize(ctx, f.size)
            }
            Text(
                sub, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (f.status == FileStatus.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.width(12.dp))
        when (f.status) {
            FileStatus.OK -> Icon(Icons.Filled.CheckCircle, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            FileStatus.FAILED -> Icon(Icons.Filled.Warning, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
            FileStatus.SENDING -> CircularProgressIndicator(
                progress = { if (f.size > 0) f.sent.toFloat() / f.size else 0f }, modifier = Modifier.size(20.dp).clearAndSetSemantics {}, strokeWidth = 2.5.dp,
            )
            FileStatus.PENDING -> Spacer(Modifier.size(20.dp))
        }
    }
}
