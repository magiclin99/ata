package io.github.magiclin99.ata.ui

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import io.github.magiclin99.ata.R

fun blePermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

fun Context.granted(p: String) = ContextCompat.checkSelfPermission(this, p) == PackageManager.PERMISSION_GRANTED
fun Context.hasBlePermissions() = blePermissions().all { granted(it) }

private fun Context.bluetoothOn() = getSystemService(BluetoothManager::class.java)?.adapter?.isEnabled == true
private fun Context.locationOn() = Build.VERSION.SDK_INT >= 31 || getSystemService(LocationManager::class.java)?.isLocationEnabled == true

private enum class GateDialog { NONE, BLE_RATIONALE, BLE_DENIED, BT_OFF, LOCATION_OFF, NOTIF_RATIONALE }

/**
 * Asks for what a BLE action needs, at the moment it is needed, each step with its own rationale:
 * Nearby-devices permission → Bluetooth on → (API ≤ 30) Location on → optionally notifications.
 */
class BleGate internal constructor(private val start: (withNotifications: Boolean, onAbort: () -> Unit, action: () -> Unit) -> Unit) {
    /** Runs [action] once everything is in place; [onAbort] if the user backs out of any step. */
    fun run(withNotifications: Boolean = false, onAbort: () -> Unit = {}, action: () -> Unit) = start(withNotifications, onAbort, action)
}

@Composable
fun rememberBleGate(): BleGate {
    val ctx = LocalContext.current
    var dialog by remember { mutableStateOf(GateDialog.NONE) }
    var pending by remember { mutableStateOf<(() -> Unit)?>(null) }
    var abort by remember { mutableStateOf<(() -> Unit)?>(null) }
    var wantNotif by remember { mutableStateOf(false) }
    val prefs = remember { ctx.getSharedPreferences("ui", Context.MODE_PRIVATE) }

    lateinit var advance: () -> Unit
    val dismiss: () -> Unit = {
        dialog = GateDialog.NONE
        pending = null
        abort?.invoke()
        abort = null
    }

    val permLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { res ->
        if (res.values.all { it }) advance() else dialog = GateDialog.BLE_DENIED
    }
    val btLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        if (r.resultCode == Activity.RESULT_OK || ctx.bluetoothOn()) advance() else dismiss()
    }
    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        wantNotif = false
        advance()
    }

    advance = {
        when {
            !ctx.hasBlePermissions() -> dialog = GateDialog.BLE_RATIONALE
            !ctx.bluetoothOn() -> dialog = GateDialog.BT_OFF
            !ctx.locationOn() -> dialog = GateDialog.LOCATION_OFF
            wantNotif && Build.VERSION.SDK_INT >= 33 && !ctx.granted(Manifest.permission.POST_NOTIFICATIONS) &&
                !prefs.getBoolean("notifAsked", false) -> dialog = GateDialog.NOTIF_RATIONALE
            else -> {
                dialog = GateDialog.NONE
                val a = pending
                pending = null
                abort = null
                a?.invoke()
            }
        }
    }


    when (dialog) {
        GateDialog.NONE -> {}
        GateDialog.BLE_RATIONALE -> AlertDialog(
            onDismissRequest = dismiss,
            title = { Text(stringResource(R.string.perm_ble_title)) },
            text = { Text(stringResource(if (Build.VERSION.SDK_INT >= 31) R.string.perm_ble_text else R.string.perm_ble_text_legacy)) },
            confirmButton = { TextButton(onClick = { dialog = GateDialog.NONE; permLauncher.launch(blePermissions()) }) { Text(stringResource(R.string.continue_)) } },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
        )
        GateDialog.BLE_DENIED -> AlertDialog(
            onDismissRequest = dismiss,
            title = { Text(stringResource(R.string.perm_ble_title)) },
            text = { Text(stringResource(R.string.perm_denied_text)) },
            confirmButton = {
                TextButton(onClick = {
                    dismiss()
                    ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null)))
                }) { Text(stringResource(R.string.open_settings)) }
            },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
        )
        GateDialog.BT_OFF -> AlertDialog(
            onDismissRequest = dismiss,
            title = { Text(stringResource(R.string.bt_off_title)) },
            text = { Text(stringResource(R.string.bt_off_text)) },
            confirmButton = {
                TextButton(onClick = {
                    dialog = GateDialog.NONE
                    @Suppress("DEPRECATION")
                    btLauncher.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                }) { Text(stringResource(R.string.turn_on_bt)) }
            },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
        )
        GateDialog.LOCATION_OFF -> AlertDialog(
            onDismissRequest = dismiss,
            title = { Text(stringResource(R.string.perm_ble_title)) },
            text = { Text(stringResource(R.string.location_off_text)) },
            confirmButton = {
                TextButton(onClick = { dismiss(); ctx.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) }) {
                    Text(stringResource(R.string.open_settings))
                }
            },
            dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
        )
        GateDialog.NOTIF_RATIONALE -> AlertDialog(
            onDismissRequest = { prefs.edit { putBoolean("notifAsked", true) }; wantNotif = false; advance() },
            title = { Text(stringResource(R.string.perm_notif_title)) },
            text = { Text(stringResource(R.string.perm_notif_text)) },
            confirmButton = {
                TextButton(onClick = {
                    prefs.edit { putBoolean("notifAsked", true) }
                    dialog = GateDialog.NONE
                    if (Build.VERSION.SDK_INT >= 33) notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }) { Text(stringResource(R.string.continue_)) }
            },
            dismissButton = {
                TextButton(onClick = { prefs.edit { putBoolean("notifAsked", true) }; wantNotif = false; advance() }) {
                    Text(stringResource(R.string.skip))
                }
            },
        )
    }

    return remember {
        BleGate { withNotifications, onAbort, action ->
            pending = action
            abort = onAbort
            wantNotif = withNotifications
            advance()
        }
    }
}
