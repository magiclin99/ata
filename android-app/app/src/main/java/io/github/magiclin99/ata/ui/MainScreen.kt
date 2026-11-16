package io.github.magiclin99.ata.ui

import android.content.Context
import android.text.format.DateUtils
import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.foundation.background
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.HorizontalDivider
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.github.magiclin99.ata.NoticeBlock
import io.github.magiclin99.ata.isJustNow
import io.github.magiclin99.ata.reflowNotices
import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.net.toUri
import kotlinx.coroutines.launch
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import io.github.magiclin99.ata.BuildConfig
import io.github.magiclin99.ata.HistoryEntry
import io.github.magiclin99.ata.PairState
import io.github.magiclin99.ata.PairedMac
import io.github.magiclin99.ata.R
import io.github.magiclin99.ata.app
import io.github.magiclin99.ata.errorText
import io.github.magiclin99.ata.ShareActivity
import io.github.magiclin99.ata.TransferHub
import io.github.magiclin99.ata.TransferService
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.saveable.rememberSaveable
import io.github.magiclin99.ata.mobileDataText
import io.github.magiclin99.ata.shortErrorText
import com.ata.core.ErrorCode

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainScreen(gate: BleGate) {
    val ctx = LocalContext.current
    val app = ctx.app
    val macs by app.pairings.macs.collectAsState()
    val history by app.history.items.collectAsState()
    val pairState by app.pairing.state.collectAsState()
    var removing by remember { mutableStateOf<PairedMac?>(null) }
    val scroll = TopAppBarDefaults.pinnedScrollBehavior()

    val pairing = rememberPairingActions(gate)
    var showLicenses by remember { mutableStateOf(false) }

    // "Send a photo to try" right after pairing: the system photo picker needs no storage permission and grants
    // read access to the chosen photo, which TransferService passes on to itself.
    var tryPhotoMac by rememberSaveable { mutableStateOf<String?>(null) }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val mac = tryPhotoMac
        tryPhotoMac = null
        if (uri != null && mac != null && !TransferHub.busy) {
            gate.run(withNotifications = true) {
                TransferService.start(ctx, listOf(uri), mac, address = null)
                ctx.startActivity(Intent(ctx, ShareActivity::class.java))
            }
        }
    }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            TopAppBar(title = { Text(stringResource(R.string.app_name)) }, scrollBehavior = scroll)
        },
    ) { inner ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = inner.calculateTopPadding() + 8.dp,
                bottom = inner.calculateBottomPadding() + 24.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (macs.isEmpty()) {
                item {
                    val text = stringResource(R.string.install_share_text, stringResource(R.string.install_url))
                    EmptyState(
                        onPair = pairing.scanQr,
                        onSendLink = {
                            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text)
                            runCatching { ctx.startActivity(Intent.createChooser(send, null)) }
                        },
                    )
                }
                // The Mac cannot show a pairing link, so pasting one is a debug-build tool only.
                if (BuildConfig.DEBUG) item { TextButton(onClick = pairing.pasteLink) { Text(stringResource(R.string.paste_link)) } }
            } else {
                item { SectionTitle(stringResource(R.string.paired_macs)) }
                items(macs, key = { it.idHex }) { mac -> MacRow(mac) { removing = mac } }
                item {
                    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = pairing.scanQr) { Text(stringResource(R.string.pair_another)) }
                        if (BuildConfig.DEBUG) {
                            Spacer(Modifier.width(8.dp))
                            TextButton(onClick = pairing.pasteLink) { Text(stringResource(R.string.paste_link)) }
                        }
                    }
                }
            }
            // History is the person's own record, so it stays even after every Mac is unpaired. With nothing paired and
            // nothing sent, the "how to send" hint would only distract from pairing, so the section is left out.
            if (history.isNotEmpty() || macs.isNotEmpty()) {
                item { Spacer(Modifier.height(16.dp)); SectionTitle(stringResource(R.string.recent_transfers)) }
                if (history.isEmpty()) {
                    item { Hint(stringResource(R.string.no_transfers)) }
                } else {
                    items(history, key = { it.time }) { HistoryRow(it) }
                }
            }
            item { Spacer(Modifier.height(16.dp)); SectionTitle(stringResource(R.string.about_section)) }
            item { AboutLinks(onLicenses = { showLicenses = true }) }
        }
    }

    if (showLicenses) LicensesDialog(onClose = { showLicenses = false })

    removing?.let { mac ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text(stringResource(R.string.remove_title, mac.name)) },
            text = { Text(stringResource(R.string.remove_text)) },
            confirmButton = {
                TextButton(onClick = { app.pairings.remove(mac.idHex); removing = null }) {
                    Text(stringResource(R.string.remove), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }

    PairingDialog(
        pairState, onClose = { app.pairing.reset() }, onCancel = { app.pairing.cancel() },
        onTryPhoto = { id -> app.pairing.reset(); tryPhotoMac = id; photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
    )
}

/**
 * First run, nothing paired. Most people get here from the QR code in the Mac app's welcome window, so pairing is the
 * primary action. "My Mac doesn't have ATA yet" is the secondary one: it sends the Mac download page (in this
 * language) to the person themselves, through whatever app they already use.
 */
@Composable
internal fun EmptyState(onPair: () -> Unit, onSendLink: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(R.string.empty_title), style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(top = 8.dp).semantics { heading() },
        )
        Hint(stringResource(R.string.empty_pair))
        Button(onClick = onPair, modifier = Modifier.fillMaxWidth().padding(top = 8.dp).heightIn(min = 52.dp)) {
            Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.pair_button))
        }
        Spacer(Modifier.height(16.dp))
        Hint(stringResource(R.string.empty_install))
        OutlinedButton(onClick = onSendLink, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
            Text(stringResource(R.string.send_install_link), textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp).semantics { heading() },
    )
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun MacRow(mac: PairedMac, onRemove: () -> Unit) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        ListItem(
            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
            leadingContent = { Icon(painterResource(R.drawable.ic_mac), contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
            headlineContent = { Text(mac.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            supportingContent = {
                Text(stringResource(R.string.paired_on, DateUtils.formatDateTime(LocalContext.current, mac.pairedAt, DateUtils.FORMAT_SHOW_DATE)))
            },
            trailingContent = {
                IconButton(onClick = onRemove) { Icon(Icons.Filled.Delete, contentDescription = stringResource(R.string.remove_pairing, mac.name)) }
            },
        )
    }
}

@Composable
private fun HistoryRow(e: HistoryEntry) {
    val ctx = LocalContext.current
    val what = if (e.fileCount == 1) e.firstName else pluralStringResource(R.plurals.files_count, e.fileCount, e.fileCount)
    // Names the Mac by its name, not "your Mac": it may have been unpaired since.
    val status = when {
        !e.ok -> stringResource(R.string.history_failed, e.macName, shortErrorText(ctx, e.error?.let { runCatching { ErrorCode.valueOf(it) }.getOrNull() }))
        e.cellularBytes > 0 -> stringResource(R.string.history_ok_cellular, e.macName, mobileDataText(ctx, e.cellularBytes))
        else -> stringResource(R.string.history_ok, e.macName)
    }
    val now = System.currentTimeMillis()
    val ago = if (isJustNow(e.time, now)) stringResource(R.string.just_now)
    else DateUtils.getRelativeTimeSpanString(e.time, now, DateUtils.MINUTE_IN_MILLIS).toString()
    ListItem(
        // One announcement per transfer for screen readers; the icon only repeats what the status line says.
        modifier = Modifier.semantics(mergeDescendants = true) {},
        leadingContent = {
            Icon(
                if (e.ok) Icons.Filled.CheckCircle else Icons.Filled.Warning, contentDescription = null,
                tint = if (e.ok) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error,
            )
        },
        headlineContent = { Text(what, maxLines = 1, overflow = TextOverflow.MiddleEllipsis) },
        supportingContent = {
            Column {
                Text(status, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text("${Formatter.formatShortFileSize(ctx, e.bytes)} · $ago", maxLines = 1)
            }
        },
    )
}

@Composable
internal fun PairingDialog(s: PairState, onClose: () -> Unit, onCancel: () -> Unit, onTryPhoto: (macIdHex: String) -> Unit) {
    val ctx = LocalContext.current
    if (s == PairState.Idle) return
    val busy = s is PairState.Searching || s is PairState.Connecting
    AlertDialog(
        onDismissRequest = { if (!busy) onClose() },
        title = {
            Text(
                stringResource(
                    when (s) {
                        is PairState.Failed -> R.string.pairing_failed
                        is PairState.Done -> R.string.pairing_done_title
                        else -> R.string.pairing_busy_title
                    }
                )
            )
        },
        text = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (busy) {
                    // Decorative: the title and the sentence already say it is working.
                    CircularProgressIndicator(Modifier.size(24.dp).clearAndSetSemantics {}, strokeWidth = 3.dp)
                    Spacer(Modifier.width(16.dp))
                }
                Box(Modifier.weight(1f)) {
                    Text(
                        when (s) {
                            is PairState.Searching -> stringResource(R.string.pairing_searching, s.macName)
                            is PairState.Connecting -> stringResource(R.string.pairing_connecting, s.macName)
                            is PairState.Done -> stringResource(R.string.pairing_done, s.macName) + "\n\n" + stringResource(R.string.try_photo_text)
                            is PairState.Failed -> errorText(ctx, s.code, s.detail)
                            PairState.Idle -> ""
                        }
                    )
                }
            }
        },
        confirmButton = {
            when {
                busy -> TextButton(onClick = onCancel) { Text(stringResource(R.string.cancel)) }
                // First transfer inside the setup flow: one tap to try, one tap to skip.
                s is PairState.Done -> Button(onClick = { onTryPhoto(s.macIdHex) }) { Text(stringResource(R.string.try_photo)) }
                else -> TextButton(onClick = onClose) { Text(stringResource(R.string.close)) }
            }
        },
        dismissButton = if (s is PairState.Done) {
            { TextButton(onClick = onClose) { Text(stringResource(R.string.not_now)) } }
        } else null,
    )
}

/** Public pages on the project site. The help page URL is a per-language string resource (help_url). */
private const val PRIVACY_URL = "https://magiclin99.github.io/ata/privacy/" // one bilingual page

/**
 * Reserved voluntary-donation entry: shown only when BuildConfig.SUPPORT_URL is non-empty AND
 * BuildConfig.SHOW_SUPPORT_LINK is true. Both default to off; turning it on is an owner decision (if ATA is ever offered
 * on Google Play, re-check Play's Payments policy on links to outside payment pages first). A donation never
 * unlocks anything.
 */
private val donationUrl: String? =
    BuildConfig.SUPPORT_URL.takeIf { BuildConfig.SHOW_SUPPORT_LINK && it.isNotBlank() }

@Composable
private fun AboutLinks(onLicenses: () -> Unit) {
    val ctx = LocalContext.current
    val open = { url: String ->
        try {
            ctx.startActivity(Intent(Intent.ACTION_VIEW, url.toUri()))
        } catch (_: ActivityNotFoundException) {
        }
    }
    Column {
        ListItem(
            headlineContent = { Text(stringResource(R.string.version_label)) },
            supportingContent = { Text(BuildConfig.VERSION_NAME) },
        )
        TextButton(onClick = onLicenses) { Text(stringResource(R.string.licenses)) }
        TextButton(onClick = { open(PRIVACY_URL) }) { Text(stringResource(R.string.privacy_policy)) }
        val helpUrl = stringResource(R.string.help_url) // per language: /zh-tw/support/ or /support/
        TextButton(onClick = { open(helpUrl) }) { Text(stringResource(R.string.support)) }
        donationUrl?.let { url -> TextButton(onClick = { open(url) }) { Text(stringResource(R.string.support_ata)) } }
    }
}

/**
 * Third-party notices as a full-screen page: a one-line introduction in the UI language, then the notices verbatim
 * (they stay in English), reflowed so they wrap to the screen instead of keeping the file's fixed line width. A fade
 * at the bottom edge shows there is more below until the end is reached.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LicensesDialog(onClose: () -> Unit) {
    val res = LocalResources.current
    val blocks = remember { reflowNotices(res.openRawResource(R.raw.third_party_notices).bufferedReader().use { it.readText() }) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text(stringResource(R.string.licenses)) },
                    navigationIcon = {
                        IconButton(onClick = onClose) { Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.close)) }
                    },
                )
            },
        ) { inner ->
            val list = rememberLazyListState()
            Box(Modifier.fillMaxSize().padding(inner)) {
                LazyColumn(
                    state = list,
                    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 4.dp, bottom = 32.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    item {
                        Text(stringResource(R.string.licenses_intro), style = MaterialTheme.typography.bodyLarge)
                        HorizontalDivider(Modifier.padding(top = 14.dp))
                    }
                    items(blocks) { b ->
                        when (b) {
                            NoticeBlock.Rule -> HorizontalDivider(Modifier.padding(vertical = 6.dp))
                            is NoticeBlock.Text -> Text(
                                b.lines.joinToString("\n"),
                                style = MaterialTheme.typography.bodySmall,
                                textAlign = if (b.centered) TextAlign.Center else TextAlign.Start,
                                modifier = Modifier.fillMaxWidth().padding(start = (b.indent * 12).dp),
                            )
                        }
                    }
                }
                // Fades the last visible lines while there is more to read below.
                if (list.canScrollForward) {
                    val bg = MaterialTheme.colorScheme.surface
                    Box(
                        Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(56.dp)
                            .background(Brush.verticalGradient(listOf(bg.copy(alpha = 0f), bg)))
                    )
                }
            }
        }
    }
}
