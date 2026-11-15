package io.github.magiclin99.ata

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import io.github.magiclin99.ata.ui.AtaTheme
import io.github.magiclin99.ata.ui.MainScreen
import io.github.magiclin99.ata.ui.rememberBleGate

class MainActivity : ComponentActivity() {

    /** A debug-hook intent waiting to run once the UI is up (debug builds only; see DebugHooks). */
    private val debugIntent = mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) takeDebugIntent(intent)
        setContent {
            AtaTheme {
                val gate = rememberBleGate()
                MainScreen(gate)
                val pending = debugIntent.value
                LaunchedEffect(pending) {
                    if (pending != null) {
                        debugIntent.value = null
                        DebugHooks.run(this@MainActivity, pending) { action -> gate.run(withNotifications = false, action = action) }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeDebugIntent(intent)
    }

    private fun takeDebugIntent(i: Intent?) {
        if (i != null && DebugHooks.wants(i)) debugIntent.value = Intent(i)
    }
}
