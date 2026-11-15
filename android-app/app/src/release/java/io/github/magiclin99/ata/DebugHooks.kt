package io.github.magiclin99.ata

import android.content.Intent
import androidx.activity.ComponentActivity

/**
 * Release build: no automation hooks. The debug implementation lives in src/debug and
 * is never compiled into a release build; these no-ops are removed by R8.
 */
object DebugHooks {
    fun wants(@Suppress("UNUSED_PARAMETER") i: Intent): Boolean = false
    fun run(
        @Suppress("UNUSED_PARAMETER") activity: ComponentActivity,
        @Suppress("UNUSED_PARAMETER") i: Intent,
        @Suppress("UNUSED_PARAMETER") withBle: (() -> Unit) -> Unit,
    ) = Unit
}
