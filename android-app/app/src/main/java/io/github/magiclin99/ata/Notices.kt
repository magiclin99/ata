package io.github.magiclin99.ata

/** One block of the third-party notices as shown on screen. */
sealed interface NoticeBlock {
    /** A separator line between notices. */
    data object Rule : NoticeBlock

    /** A paragraph: [lines] are kept as separate lines (list items, centred titles); each wraps to the screen. */
    data class Text(val lines: List<String>, val indent: Int, val centered: Boolean) : NoticeBlock
}

private val ITEM_START = Regex("""^([-*•]|\(?[0-9a-zA-Z]{1,3}[.)])\s""")

/**
 * Reflows the plain-text notices (hard-wrapped at about 80 columns) so they wrap to the screen. Only whitespace
 * changes: the words of every notice stay exactly as written. A paragraph's lines are joined with spaces, except that
 * a list item ("- …", "1. …", "(a) …") starts a new line, and deeply indented lines (the centred title of the
 * Apache License) stay as they are. A line of dashes becomes a [NoticeBlock.Rule].
 */
fun reflowNotices(raw: String): List<NoticeBlock> {
    val out = mutableListOf<NoticeBlock>()
    val para = mutableListOf<String>()
    fun flush() {
        if (para.isEmpty()) return
        val lead = para.first().indexOfFirst { it != ' ' }
        val centered = lead >= 10
        val lines = mutableListOf<String>()
        for (l in para) {
            val t = l.trim()
            if (lines.isEmpty() || centered || ITEM_START.containsMatchIn(t)) lines += t
            else lines[lines.lastIndex] = lines.last() + " " + t
        }
        out += NoticeBlock.Text(lines, indent = if (centered) 0 else (lead / 3).coerceAtMost(2), centered = centered)
        para.clear()
    }
    for (line in raw.lines()) {
        val t = line.trim()
        when {
            t.isEmpty() -> flush()
            t.length >= 10 && t.all { it == '-' } -> { flush(); out += NoticeBlock.Rule }
            else -> para += line.trimEnd()
        }
    }
    flush()
    return out
}
