package io.github.magiclin99.ata

import android.Manifest
import android.bluetooth.BluetoothManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.os.Looper
import android.os.SystemClock
import android.view.View
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.core.content.edit
import io.github.magiclin99.ata.ui.MainScreen
import io.github.magiclin99.ata.ui.SendSheet
import io.github.magiclin99.ata.ui.rememberBleGate
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.io.RandomAccessFile

/**
 * Phone screenshots for the website: the real main screen and send sheet, filled with demo data (a Mac called "My Mac",
 * neutral file names), drawn at 384 x 768 dp and 450 dpi, which is 1080 x 2160 px. Opt-in, and run against the
 * release variant so debug-only buttons stay out of the pictures:
 *
 *     ./gradlew :app:testReleaseUnitTest -Pata.screenshots --tests '*StoreScreenshotTest*'
 *
 * Output: app/build/screenshots/store/<lang>/<n>-<name>.png. The colours are the dynamic palette the test phone
 * (Samsung, default wallpaper) gave the app, since the app follows the system palette and Robolectric has none.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class StoreScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test @Config(qualifiers = "zh-rTW-w384dp-h768dp-450dpi") fun zh1Main() = shot("zh", "1-main", Scene.MAIN)
    @Test @Config(qualifiers = "zh-rTW-w384dp-h768dp-450dpi") fun zh2Picker() = shot("zh", "2-picker", Scene.PICKER)
    @Test @Config(qualifiers = "zh-rTW-w384dp-h768dp-450dpi") fun zh3Sent() = shot("zh", "3-sent", Scene.SENT)
    @Test @Config(qualifiers = "zh-rTW-w384dp-h768dp-450dpi") fun zh4Start() = shot("zh", "4-first-run", Scene.FIRST_RUN)

    @Test @Config(qualifiers = "en-w384dp-h768dp-450dpi") fun en1Main() = shot("en", "1-main", Scene.MAIN)
    @Test @Config(qualifiers = "en-w384dp-h768dp-450dpi") fun en2Picker() = shot("en", "2-picker", Scene.PICKER)
    @Test @Config(qualifiers = "en-w384dp-h768dp-450dpi") fun en3Sent() = shot("en", "3-sent", Scene.SENT)
    @Test @Config(qualifiers = "en-w384dp-h768dp-450dpi") fun en4Start() = shot("en", "4-first-run", Scene.FIRST_RUN)

    private enum class Scene { MAIN, PICKER, SENT, FIRST_RUN }

    private val deviceColors = lightColorScheme(
        primary = Color(0xFF387AFF),
        onPrimary = Color.White,
        primaryContainer = Color(0xFFDAE2FF),
        onPrimaryContainer = Color(0xFF304578),
        background = Color(0xFFF1F1F3),
        onBackground = Color(0xFF010102),
        surface = Color(0xFFFCFCFF),
        onSurface = Color(0xFF010102),
        onSurfaceVariant = Color(0xFF010102),
        surfaceContainerLowest = Color.White,
        surfaceContainerLow = Color(0xFFF1F1F3),
        surfaceContainer = Color(0xFFE4E4E7),
        surfaceContainerHigh = Color(0xFFE4E4E7),
        outline = Color(0xFF8F909A),
        outlineVariant = Color(0xFFC5C6D0),
    )

    private fun shot(lang: String, name: String, scene: Scene) {
        assumeTrue(System.getProperty("ata.screenshots") == "true")
        val zh = lang == "zh"
        val app = compose.activity.app
        val mac = if (zh) "我的 Mac" else "My Mac"
        val macId = "0123456789abcdef0123456789abcdef"
        val now = System.currentTimeMillis()
        val min = 60_000L
        // The shared file is a document, not a photo: the listing says ATA sends any kind of file.
        val photos = listOf((if (zh) "旅遊行程.pdf" else "Trip plan.pdf") to 2_140_000L)
        // The framework's clock starts at an arbitrary time; dates without a year need it to be this year.
        SystemClock.setCurrentTimeMillis(now)

        if (scene != Scene.FIRST_RUN) {
            app.getSharedPreferences("pairings", 0).edit(commit = true) {
                putString("mac.$macId", JSONObject().put("name", mac).put("pairedAt", now - 26 * 60 * min).put("wrapped", "").toString())
            }
            val history = mutableListOf(
                Triple(now - 12 * min, "IMG_20261115_101500.jpg", 1) to 3_210_000L,
                Triple(now - 35 * min, if (zh) "收據.zip" else "Receipts.zip", 1) to 4_820_000L,
                Triple(now - 3 * 60 * min, "VID_20261115_183012.mp4", 1) to 38_400_000L,
                Triple(now - 4 * 60 * min, "IMG_20261115_120233.jpg", 4) to 12_600_000L,
                Triple(now - 5 * 60 * min, if (zh) "會議記錄.docx" else "Meeting notes.docx", 1) to 245_000L,
            )
            if (scene == Scene.SENT) history.add(0, Triple(now - 5_000L, photos[0].first, photos.size) to photos.sumOf { it.second })
            val a = JSONArray()
            for ((t, bytes) in history) a.put(
                JSONObject().put("time", t.first).put("mac", mac).put("count", t.third).put("first", t.second)
                    .put("bytes", bytes).put("ok", true).put("via", "lan").put("error", "").put("cell", 0L)
            )
            app.getSharedPreferences("history", 0).edit(commit = true) { putString("items", a.toString()) }
        }
        // The stores read their preferences once, when the app starts, so start them again on the demo data.
        setField(app, "pairings", PairingStore(app))
        setField(app, "history", HistoryStore(app))

        val uris = photos.map { (n, size) ->
            val f = File(app.cacheDir, "demo/$n").apply { parentFile!!.mkdirs() }
            RandomAccessFile(f, "rw").use { it.setLength(size) }
            Uri.fromFile(f)
        }
        val scanner = NearbyScanner(app, Logcat)
        if (scene == Scene.PICKER) {
            shadowOf(app).grantPermissions(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            app.getSystemService(BluetoothManager::class.java)?.adapter?.let { shadowOf(it).setState(android.bluetooth.BluetoothAdapter.STATE_ON) }
        }
        if (scene == Scene.SENT) {
            TransferHub.set(
                TransferState(
                    phase = Phase.DONE, macName = mac, totalSent = photos.sumOf { it.second },
                    files = photos.map { (n, size) -> FileItem(n, size, size, FileStatus.OK) },
                )
            )
        } else TransferHub.set(null)

        compose.mainClock.autoAdvance = false
        compose.activity.setContent {
            MaterialTheme(colorScheme = deviceColors) {
                Box {
                    MainScreen(rememberBleGate())
                    if (scene == Scene.PICKER || scene == Scene.SENT) {
                        SendSheet(uris, picking = scene == Scene.PICKER, scanner = scanner, onPick = { _, _ -> }, onRetry = {}, onClose = {})
                    }
                }
            }
        }
        settle()
        if (scene == Scene.PICKER) {
            // Pretend the scan has just seen the Mac.
            @Suppress("UNCHECKED_CAST")
            (getField(scanner, "_status") as MutableStateFlow<ScanStatus>).value = ScanStatus.SCANNING
            @Suppress("UNCHECKED_CAST")
            (getField(scanner, "_nearby") as MutableStateFlow<Map<String, NearbyMac>>).value =
                mapOf(macId to NearbyMac(macId, "00:00:00:00:00:00", -48, SystemClock.elapsedRealtime()))
            settle()
        }

        val dir = File(System.getProperty("ata.screenshotDir") ?: "build/screenshots", "store/$lang").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { drawAllWindows().compress(Bitmap.CompressFormat.PNG, 100, it) }
        scanner.stop()
    }

    /** Lets the sheet finish sliding in; the clock is stepped by hand because the progress spinner never idles. */
    private fun settle() {
        repeat(60) {
            compose.mainClock.advanceTimeBy(50)
            shadowOf(Looper.getMainLooper()).idle()
        }
    }

    /** Software-draws every window (the activity, then the bottom sheet's own window) into one picture. */
    private fun drawAllWindows(): Bitmap {
        val root = compose.activity.window.decorView
        val out = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        @Suppress("UNCHECKED_CAST")
        val views = getField(Class.forName("android.view.WindowManagerGlobal").getMethod("getInstance").invoke(null)!!, "mViews") as List<View>
        for (v in views) {
            if (v.width == 0 || v.height == 0) continue
            val loc = IntArray(2).also { v.getLocationOnScreen(it) }
            canvas.save()
            canvas.translate(loc[0].toFloat(), loc[1].toFloat())
            v.draw(canvas)
            canvas.restore()
        }
        return out
    }

    private fun field(o: Any, name: String) =
        generateSequence<Class<*>>(o.javaClass) { it.superclass }.firstNotNullOf { c -> runCatching { c.getDeclaredField(name) }.getOrNull() }
            .apply { isAccessible = true }

    private fun getField(o: Any, name: String): Any? = field(o, name).get(o)
    private fun setField(o: Any, name: String, value: Any) = field(o, name).set(o, value)
}
