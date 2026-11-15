package io.github.magiclin99.ata

import android.graphics.Bitmap
import android.graphics.Canvas
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import io.github.magiclin99.ata.ui.EmptyState
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * Renders the screens whose wording has to wrap well (empty state, pairing and permission dialogs, scanner hint) at
 * 320, 360 and 411 dp wide and at font scale 1.0 and 1.3, in both languages, and saves one PNG per case under
 * app/build/screenshots/ for a person to look at. Opt-in because it downloads a full Android runtime:
 *
 *     ./gradlew :app:testDebugUnitTest -Pata.screenshots --tests '*LayoutScreenshotTest*'
 *
 * Dialog bodies are drawn at the width the system gives an alert dialog's text (screen width minus the dialog's outer
 * margins and its 24 dp padding), which is what decides the line breaks.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w2400dp-h3400dp-xhdpi")
class LayoutScreenshotTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private val widths = listOf(320, 360, 411)
    private val scales = listOf(1.0f, 1.3f)

    @Test @Config(qualifiers = "zh-rTW-w2400dp-h3400dp-xhdpi") fun zh() = render("zh")

    @Test @Config(qualifiers = "en-w2400dp-h3400dp-xhdpi") fun en() = render("en")

    private fun render(lang: String) {
        assumeTrue(System.getProperty("ata.screenshots") == "true")
        compose.setContent {
            MaterialTheme {
                Row(Modifier.background(Color.White), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    for (scale in scales) {
                        for (w in widths) {
                            val d = LocalDensity.current
                            CompositionLocalProvider(LocalDensity provides Density(d.density, scale)) {
                                Column(Modifier.width(w.dp).testTag("$w-$scale")) { Catalog(w) }
                            }
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
        // Software-draw the whole window once (PixelCopy is not available here), then cut out each case.
        val root = compose.activity.window.decorView
        val all = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        root.draw(Canvas(all))
        val dir = File(System.getProperty("ata.screenshotDir") ?: "build/screenshots").apply { mkdirs() }
        for (scale in scales) for (w in widths) {
            val r = compose.onNodeWithTag("$w-$scale").fetchSemanticsNode().boundsInWindow
            val bmp = Bitmap.createBitmap(all, r.left.toInt(), r.top.toInt(), r.width.toInt(), minOf(r.height.toInt(), all.height - r.top.toInt()))
            File(dir, "$lang-${w}dp-x$scale.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
    }

    @Composable
    private fun Catalog(screenWidth: Int) {
        Surface(color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) { EmptyState(onPair = {}, onSendLink = {}) }
        }
        DialogBody(screenWidth, R.string.pairing_busy_title, stringResource(R.string.pairing_searching, "MacBook Air"))
        DialogBody(screenWidth, R.string.pairing_busy_title, stringResource(R.string.pairing_connecting, "MacBook Air"))
        DialogBody(
            screenWidth, R.string.pairing_done_title,
            stringResource(R.string.pairing_done, "MacBook Air") + "\n\n" + stringResource(R.string.try_photo_text),
        )
        DialogBody(screenWidth, R.string.cam_title, stringResource(R.string.cam_text))
        DialogBody(screenWidth, R.string.perm_ble_title, stringResource(R.string.perm_ble_text))
        DialogBody(screenWidth, R.string.perm_ble_title_legacy, stringResource(R.string.perm_ble_text_legacy))
        DialogBody(screenWidth, R.string.perm_notif_title, stringResource(R.string.perm_notif_text))
        Surface(color = Color.DarkGray, modifier = Modifier.padding(top = 8.dp)) {
            ScanHint(stringResource(R.string.scan_hint), Modifier.padding(24.dp))
        }
        Surface(color = Color.DarkGray) {
            ScanHint(stringResource(R.string.err_bad_pairing_code), Modifier.padding(24.dp))
        }
    }

    /** An alert dialog's title and text at the width the dialog would have on a [screenWidth] dp screen. */
    @Composable
    private fun DialogBody(screenWidth: Int, title: Int, text: String) {
        val dialog = minOf(560, maxOf(280, screenWidth - 48))
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh, shape = MaterialTheme.shapes.extraLarge,
            modifier = Modifier.padding(top = 12.dp, start = ((screenWidth - dialog) / 2).dp).widthIn(max = dialog.dp).width(dialog.dp),
        ) {
            Column(Modifier.padding(24.dp)) {
                Text(stringResource(title), style = MaterialTheme.typography.headlineSmall, modifier = Modifier.padding(bottom = 16.dp))
                Text(text, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}
