package io.github.magiclin99.ata

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.view.LifecycleCameraController
import androidx.camera.view.PreviewView
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import io.github.magiclin99.ata.ui.AtaTheme
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Full-screen QR scanner for the pairing code. CameraX delivers frames, ZXing decodes the luminance plane on this
 * phone; no frame is stored or sent anywhere. Returns the `ata://pair…` text as [EXTRA_URI]; the caller has already
 * obtained the CAMERA permission. The URI is never logged.
 */
class ScanActivity : ComponentActivity() {

    companion object {
        const val EXTRA_URI = "uri"
        /** Set on RESULT_CANCELED when the camera could not be opened at all. */
        const val EXTRA_CAMERA_FAILED = "cameraFailed"
    }

    private lateinit var analysis: ExecutorService
    private var controller: LifecycleCameraController? = null
    private val done = AtomicBoolean(false)
    private var wrongCode by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        analysis = Executors.newSingleThreadExecutor()
        val reader = QRCodeReader()
        val hints = mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)

        val c = LifecycleCameraController(this).apply {
            cameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
            imageAnalysisBackpressureStrategy = ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST
            setImageAnalysisAnalyzer(analysis) { img -> img.use { decode(it, reader, hints) } }
        }
        try {
            c.bindToLifecycle(this)
            controller = c
        } catch (e: Exception) {
            Logcat.i("scan: camera unavailable: ${e.javaClass.simpleName}")
            setResult(RESULT_CANCELED, Intent().putExtra(EXTRA_CAMERA_FAILED, true))
            finish()
            return
        }

        setContent {
            AtaTheme {
                Box(Modifier.fillMaxSize()) {
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { ctx ->
                            PreviewView(ctx).apply {
                                scaleType = PreviewView.ScaleType.FILL_CENTER
                                controller = c
                            }
                        },
                    )
                    Box(
                        Modifier.align(Alignment.Center).size(240.dp)
                            .border(3.dp, Color.White.copy(alpha = 0.9f), RoundedCornerShape(24.dp))
                    )
                    Column(Modifier.fillMaxWidth().safeDrawingPadding().padding(16.dp)) {
                        IconButton(onClick = { setResult(RESULT_CANCELED); finish() }) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.close), tint = Color.White)
                        }
                    }
                    ScanHint(
                        stringResource(if (wrongCode) R.string.err_bad_pairing_code else R.string.scan_hint),
                        Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(24.dp),
                    )
                }
            }
        }
    }

    private fun decode(img: ImageProxy, reader: QRCodeReader, hints: Map<DecodeHintType, Any>) {
        if (done.get()) return
        val plane = img.planes[0]
        val buf = plane.buffer
        val rowStride = plane.rowStride
        // The last row of the Y plane may be shorter than rowStride; pad so ZXing sees a full rowStride × height grid.
        val data = ByteArray(maxOf(buf.remaining(), rowStride * img.height)).also { buf.get(it, 0, buf.remaining()) }
        val src = PlanarYUVLuminanceSource(data, rowStride, img.height, 0, 0, img.width, img.height, false)
        val text = try {
            reader.decode(BinaryBitmap(HybridBinarizer(src)), hints).text
        } catch (_: ReaderException) {
            null
        } finally {
            reader.reset()
        } ?: return
        if (!text.startsWith("ata://pair")) {
            runOnUiThread { wrongCode = true }
            return
        }
        if (done.compareAndSet(false, true)) {
            runOnUiThread {
                setResult(RESULT_OK, Intent().putExtra(EXTRA_URI, text))
                finish()
            }
        }
    }

    override fun onDestroy() {
        controller?.clearImageAnalysisAnalyzer()
        if (::analysis.isInitialized) analysis.shutdown()
        super.onDestroy()
    }
}

/** The hint at the bottom of the scanner, over the camera picture. */
@Composable
internal fun ScanHint(text: String, modifier: Modifier = Modifier) {
    Surface(color = Color.Black.copy(alpha = 0.6f), shape = MaterialTheme.shapes.medium, modifier = modifier) {
        Text(
            text, color = Color.White, textAlign = TextAlign.Center,
            // Balanced lines: no single word left alone on the last line.
            style = LocalTextStyle.current.copy(lineBreak = LineBreak.Heading),
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
        )
    }
}
