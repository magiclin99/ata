package io.github.magiclin99.ata

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class NoticesTest {
    private fun words(s: String) = s.split(Regex("\\s+")).filter { it.isNotEmpty() }

    @Test fun joinsHardWrappedLinesAndKeepsListItems() {
        val raw = """
            |Intro line one
            |continues here.
            |
            |  - First item
            |    wraps here
            |  - Second item
            |-------------------------
            |                     Centred Title
            |                   Version 2
        """.trimMargin()
        val b = reflowNotices(raw)
        assertEquals(NoticeBlock.Text(listOf("Intro line one continues here."), 0, false), b[0])
        assertEquals(NoticeBlock.Text(listOf("- First item wraps here", "- Second item"), 0, false), b[1])
        assertEquals(NoticeBlock.Rule, b[2])
        assertEquals(NoticeBlock.Text(listOf("Centred Title", "Version 2"), 0, true), b[3])
    }

    /** Reflowing must never change, drop or reorder a word of the legally required texts. */
    @Test fun keepsEveryWordOfTheRealNotices() {
        val raw = File("src/main/res/raw/third_party_notices.txt").readText()
        val shown = reflowNotices(raw).joinToString(" ") { b ->
            when (b) {
                NoticeBlock.Rule -> ""
                is NoticeBlock.Text -> b.lines.joinToString(" ")
            }
        }
        val expected = words(raw).filterNot { w -> w.length >= 10 && w.all { it == '-' } }
        assertEquals(expected, words(shown))
        assertTrue(shown.contains("Apache License"))
    }

    @Test fun justNowIsUnderOneMinute() {
        val now = 1_000_000_000L
        assertTrue(isJustNow(now - 59_000, now))
        assertTrue(isJustNow(now, now))
        assertTrue(isJustNow(now + 5_000, now)) // a slightly fast clock still reads "just now"
        assertTrue(!isJustNow(now - 60_000, now))
    }
}
