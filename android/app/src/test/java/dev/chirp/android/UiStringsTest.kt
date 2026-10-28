package dev.chirp.android

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * UI text comes from string and plural resources (#332, #339). Compose has no lint check for literal Text(...),
 * so this guards the patterns that bypassed resources before: literal Text and content descriptions,
 * SetTextI18n suppressions, English-only pluralisation, and English sentences built in model and state classes.
 */
class UiStringsTest {
    private val sources = File("src/main/java").walkTopDown().filter { it.extension == "kt" }.toList()
    private val patterns = listOf(
        Regex("""\bText\("[A-Z]"""),
        Regex("""contentDescription = "[A-Z]"""),
        Regex("""SetTextI18n"""),
        Regex("""== ?1L?\) ?"[^"]*" else "[^"]*s""""),
    )
    /** A capitalised word and at least one more: a sentence for a person, not an id, key or wire value. */
    private val sentence = Regex(""""[A-Z][a-z’']+( [A-Za-z’'…—·]+)+""")
    /** Lines that only build messages for developers: logs, failed checks, exceptions. */
    private val developer = Regex("""Log\.|\berror\(|\brequire\(|\bcheck\(|\bthrow |Exception\(|@Deprecated""")
    /** English kept on purpose, by file and a piece of the line, with the reason. */
    private val exempt = listOf(
        // Saved into the note and its Markdown export, and the Diagnostics text; NotesStatusTest keeps them equal to the resources.
        "NotesStatus.kt" to "",
        // Support reports copied as English.
        "SessionTimings.kt" to "", "NotesTimings.kt" to "", "SetupActivity.kt" to "No crashes recorded",
        // Clipboard labels are metadata for other apps, not shown text.
        "" to "ClipData.newPlainText(", "HistoryScreen.kt" to "actions.copy(\"Chirp dictation",
        // History stores the app label with each entry.
        "QuickDictateActivity.kt" to "\"Quick dictate\"", "QuickDictateActivity.kt" to "\"Requesting app\"", "QuickDictateModel.kt" to "\"Quick dictate\"",
        // Rejected pairing links: exception messages, never shown.
        "Pairing.kt" to "",
        // Stand-in for the server's own style names, which are not translated either.
        "CleanupStyles.kt" to "CorrectionProfile(\"custom\"",
        // The note's own text: the Markdown title and the library's name for an empty typed note.
        "NotesDocument.kt" to "\"Notes — \"", "NotesDocument.kt" to "\"Untitled note\"",
    )

    private fun found(matches: (String) -> Boolean, skip: (File, String) -> Boolean = { _, _ -> false }) = sources.flatMap { file ->
        file.readLines().mapIndexedNotNull { index, line ->
            val code = line.trim()
            if (code.startsWith("//") || code.startsWith("*") || code.startsWith("/*") || !matches(line) || skip(file, code)) null
            else "${file.name}:${index + 1}: $code"
        }
    }

    @Test fun `user-facing text comes from resources`() {
        assert(sources.size > 50) { "Unit tests must run from the app module: ${File(".").absolutePath}" }
        assertEquals("Move these to res/values/strings*.xml or plurals", emptyList<String>(), found({ line -> patterns.any { it.containsMatchIn(line) } }))
    }

    @Test fun `model and state classes hold resources or types, not English`() {
        val left = found({ sentence.containsMatchIn(it) && !developer.containsMatchIn(it) }) { file, code ->
            exempt.any { (name, piece) -> (name.isEmpty() || file.name == name) && piece in code }
        }
        assertEquals("Hold a string resource, UiText or a typed status instead (#339)", emptyList<String>(), left)
    }

    @Test fun `the check sees English that model code would build`() {
        assert(sentence.containsMatchIn("""        notice -> "Inserted, ${'$'}words words""""))
        assert(sentence.containsMatchIn("""    var status by mutableStateOf("Connecting to your computer…")"""))
        assert(!sentence.containsMatchIn("""    putString("failure_class", "OTHER")"""))
    }
}
