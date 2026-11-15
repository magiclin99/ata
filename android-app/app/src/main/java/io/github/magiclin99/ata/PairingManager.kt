package io.github.magiclin99.ata

import com.ata.core.AtaException
import com.ata.core.ErrorCode
import com.ata.core.Msg
import com.ata.core.NameHint
import com.ata.core.PairingInfo
import com.ata.core.PhoneHandshake
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

sealed interface PairState {
    data object Idle : PairState
    data class Searching(val macName: String) : PairState
    data class Connecting(val macName: String) : PairState
    data class Done(val macName: String) : PairState
    data class Failed(val code: ErrorCode, val detail: String) : PairState
}

/**
 * QR → BLE → handshake with `pairing:true` (SPEC §2, §4). K is stored only after auth_ok verifies.
 * Runs in the application scope so rotating or leaving the screen does not abort it.
 */
class PairingManager(private val app: AtaApp) {
    private val log = Logcat
    private val _state = MutableStateFlow<PairState>(PairState.Idle)
    val state: StateFlow<PairState> = _state
    private var job: Job? = null

    fun reset() {
        if (job?.isActive != true) _state.value = PairState.Idle
    }

    fun cancel() {
        job?.cancel()
        _state.value = PairState.Idle
    }

    /** [uri] is secret (it contains K): it is never logged. */
    fun pair(uri: String) {
        if (job?.isActive == true) return
        val info = try {
            PairingInfo.parse(uri)
        } catch (e: AtaException) {
            log.i("PAIR ok=false error=${e.code}")
            _state.value = PairState.Failed(e.code, e.detail)
            return
        }
        job = app.scope.launch {
            val t0 = System.currentTimeMillis()
            try {
                _state.value = PairState.Searching(info.macName)
                log.i("pair: looking for Mac ${info.macIdHex}")
                val hs = PhoneHandshake(app.identity.phoneId, app.identity.phoneName, log)
                // The local-name hint (SPEC §3) lets us stop scanning and connect to the right device first.
                val hit = { f: Found -> NameHint.match(f.name, listOf(info.macIdHex)) is NameHint.Match.Paired }
                val devices = scanForMacs(app, log, stopWhen = hit)
                    .filter { NameHint.match(it.name, listOf(info.macIdHex)) != NameHint.Match.Unpaired }
                    .sortedByDescending { hit(it) }
                if (devices.isEmpty()) throw AtaException(ErrorCode.MAC_NOT_FOUND, "no matching ATA device advertising")
                val probe = probeMacs(app, log, hs, devices, firstOnly = true) { it.macIdHex == info.macIdHex }
                val match = probe.matches.firstOrNull()
                    ?: if (probe.badVersion) throw AtaException(ErrorCode.BAD_VERSION, "Mac speaks another version")
                    else throw AtaException(ErrorCode.MAC_NOT_FOUND, "Mac ${info.macIdHex} not among ${devices.size} device(s)")
                _state.value = PairState.Connecting(info.macName)
                try {
                    val session = hs.authenticate(match.link, match.hello, info.key, pairing = true)
                    val name = session.macName.ifBlank { info.macName }
                    app.pairings.save(info.macIdHex, name, info.key)
                    runCatching { session.send(Msg.bye(true, null, null)) }
                    log.i("PAIR ok=true mac=${info.macIdHex} ms=${System.currentTimeMillis() - t0}")
                    _state.value = PairState.Done(name)
                } finally {
                    match.link.close()
                }
            } catch (e: CancellationException) {
                log.i("PAIR ok=false error=CANCELLED")
                throw e
            } catch (e: AtaException) {
                log.i("PAIR ok=false error=${e.code} ${e.detail}")
                _state.value = PairState.Failed(e.code, e.detail)
            } catch (e: Exception) {
                log.i("PAIR ok=false error=${e.javaClass.simpleName}")
                _state.value = PairState.Failed(ErrorCode.CONNECTION_LOST, e.message ?: "")
            }
        }
    }
}
