package io.github.magiclin99.ata

import android.app.Application
import android.util.Log
import com.ata.core.AtaLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

class AtaApp : Application() {
    /** App-lifetime scope for work that must survive an Activity (pairing). */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    lateinit var identity: Identity
        private set
    lateinit var pairings: PairingStore
        private set
    lateinit var history: HistoryStore
        private set
    lateinit var pairing: PairingManager
        private set

    override fun onCreate() {
        super.onCreate()
        identity = Identity(this)
        pairings = PairingStore(this)
        history = HistoryStore(this)
        pairing = PairingManager(this)
    }
}

/** Protocol events go to logcat under tag ATA (SPEC §9). Callers never pass keys or the pairing URI. */
object Logcat : AtaLog {
    const val TAG = "ATA"
    override fun i(msg: String) {
        Log.i(TAG, msg)
    }
}

val android.content.Context.app: AtaApp get() = applicationContext as AtaApp
