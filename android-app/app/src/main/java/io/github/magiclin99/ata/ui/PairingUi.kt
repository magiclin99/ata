package io.github.magiclin99.ata.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import io.github.magiclin99.ata.BuildConfig
import io.github.magiclin99.ata.R
import io.github.magiclin99.ata.ScanActivity
import io.github.magiclin99.ata.app

/** Entry points into pairing, shared by the main screen and the send sheet. */
class PairingActions(val scanQr: () -> Unit, val pasteLink: () -> Unit)

private enum class CamDialog { NONE, RATIONALE, DENIED }

/**
 * QR scanning with the camera ([ScanActivity], decoded on the phone). CAMERA is asked for only when the user taps
 * "Scan QR code", after a one-line explanation; if it is refused, one button opens the app's permission settings.
 * (Pasting an `ata://pair` link exists only in debug builds.) Pairing itself runs in [io.github.magiclin99.ata.PairingManager]; BLE permissions are asked first.
 */
@Composable
fun rememberPairingActions(gate: BleGate): PairingActions {
    val ctx = LocalContext.current
    val app = ctx.app
    var pasteDialog by remember { mutableStateOf(false) }
    var scannerMissing by remember { mutableStateOf(false) }
    var camDialog by remember { mutableStateOf(CamDialog.NONE) }

    val scanLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        val uri = r.data?.getStringExtra(ScanActivity.EXTRA_URI)
        when {
            uri != null -> gate.run { app.pairing.pair(uri) }
            r.data?.getBooleanExtra(ScanActivity.EXTRA_CAMERA_FAILED, false) == true -> scannerMissing = true
        }
    }
    val launchScan = { scanLauncher.launch(Intent(ctx, ScanActivity::class.java)) }
    val camPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) launchScan() else camDialog = CamDialog.DENIED
    }

    // Pasting a pairing link is a debug-build tool: the Mac has no way to show one, so in release builds it would
    // be a dead end for real users.
    if (pasteDialog && BuildConfig.DEBUG) {
        PasteLinkDialog(
            onDismiss = { pasteDialog = false },
            onPair = { uri -> pasteDialog = false; gate.run { app.pairing.pair(uri) } },
        )
    }
    if (scannerMissing) {
        AlertDialog(
            onDismissRequest = { scannerMissing = false },
            title = { Text(stringResource(R.string.scanner_unavailable_title)) },
            text = { Text(stringResource(R.string.scanner_unavailable_text)) },
            confirmButton = { TextButton(onClick = { scannerMissing = false }) { Text(stringResource(R.string.close)) } },
        )
    }

    if (camDialog != CamDialog.NONE) {
        val denied = camDialog == CamDialog.DENIED
        AlertDialog(
            onDismissRequest = { camDialog = CamDialog.NONE },
            title = { Text(stringResource(R.string.cam_title)) },
            text = { Text(stringResource(if (denied) R.string.cam_denied_text else R.string.cam_text)) },
            confirmButton = {
                TextButton(onClick = {
                    camDialog = CamDialog.NONE
                    if (denied) {
                        ctx.startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                    } else camPermission.launch(Manifest.permission.CAMERA)
                }) { Text(stringResource(if (denied) R.string.open_settings else R.string.continue_)) }
            },
            dismissButton = { TextButton(onClick = { camDialog = CamDialog.NONE }) { Text(stringResource(R.string.cancel)) } },
        )
    }

    return PairingActions(
        scanQr = {
            when {
                !ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY) -> scannerMissing = true
                ctx.granted(Manifest.permission.CAMERA) -> launchScan()
                else -> camDialog = CamDialog.RATIONALE
            }
        },
        pasteLink = { pasteDialog = true },
    )
}

@Composable
private fun PasteLinkDialog(onDismiss: () -> Unit, onPair: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.paste_link)) },
        text = {
            Column {
                OutlinedTextField(value = text, onValueChange = { text = it.trim() }, label = { Text(stringResource(R.string.pair_link_label)) }, singleLine = true)
            }
        },
        confirmButton = { TextButton(enabled = text.startsWith("ata://"), onClick = { onPair(text) }) { Text(stringResource(R.string.pair)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
