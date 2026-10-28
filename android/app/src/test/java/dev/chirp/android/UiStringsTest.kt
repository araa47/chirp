package dev.chirp.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * UI text comes from string and plural resources (#332). Compose has no lint check for literal Text(...),
 * so this guards the patterns that bypassed resources before: literal Text and content descriptions,
 * SetTextI18n suppressions and English-only pluralisation.
 */
class UiStringsTest {
    private val sources = File("src/main/java").walkTopDown().filter { it.extension == "kt" }.toList()
    private val patterns = listOf(
        Regex("""\bText\("[A-Z]"""),
        Regex("""contentDescription = "[A-Z]"""),
        Regex("""SetTextI18n"""),
        Regex("""== ?1L?\) ?"[^"]*" else "[^"]*s""""),
    )
    // Dictation status lines are still English values the strip and panel match on; they move with typed status (#332 follow-up).
    private val allowed = setOf("""notice -> "Inserted, ${'$'}words ${'$'}{if (words == 1) "word" else "words"}"""")

    @Test fun `user-facing text comes from resources`() {
        assert(sources.size > 50) { "Unit tests must run from the app module: ${File(".").absolutePath}" }
        val found = sources.flatMap { file ->
            file.readLines().mapIndexedNotNull { index, line ->
                val code = line.trim()
                if (code.startsWith("//") || code.startsWith("*") || code in allowed || patterns.none { it.containsMatchIn(line) }) null
                else "${file.name}:${index + 1}: $code"
            }
        }
        assertEquals("Move these to res/values/strings*.xml or plurals", emptyList<String>(), found)
    }
}
