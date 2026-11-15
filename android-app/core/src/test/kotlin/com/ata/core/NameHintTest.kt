package com.ata.core

import org.junit.Assert.assertEquals
import org.junit.Test

class NameHintTest {
    private val a = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    private val b = "a0a1ffffa4a5a6a7a8a9aaabacadaeaf"
    private val c = "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf"

    @Test fun specExample() {
        assertEquals("ATA-a0a1a2a3", NameHint.nameFor(a))
        assertEquals("a0a1a2a3", NameHint.prefix("ATA-a0a1a2a3"))
        assertEquals(NameHint.Match.Paired(a), NameHint.match("ATA-a0a1a2a3", listOf(a, b, c)))
        assertEquals(NameHint.Match.Paired(a), NameHint.match("ATA-A0A1A2A3", listOf(a.uppercase(), c)).let {
            if (it is NameHint.Match.Paired) NameHint.Match.Paired(it.idHex) else it
        })
    }

    @Test fun unpairedAmbiguousAndMissing() {
        assertEquals(NameHint.Match.Unpaired, NameHint.match("ATA-deadbeef", listOf(a, c)))
        // Shortened by the advertiser to 4 hex chars: a and b share "a0a1".
        assertEquals(NameHint.Match.Ambiguous, NameHint.match("ATA-a0a1", listOf(a, b)))
        assertEquals(NameHint.Match.Paired(c), NameHint.match("ATA-b0b1", listOf(a, b, c)))
        for (n in listOf(null, "", "MacBook Pro", "ATA-", "ATA-a0a", "ATA-xyz12345", "ATA Lab")) {
            assertEquals(n, NameHint.Match.NoHint, NameHint.match(n, listOf(a)))
        }
        assertEquals("a0a1a2a3", NameHint.prefix(" ATA-a0a1a2a3 "))
    }
}
