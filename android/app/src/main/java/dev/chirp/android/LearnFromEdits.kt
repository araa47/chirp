package dev.chirp.android

import androidx.annotation.StringRes
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** Fixed server style ids; user edits are data, never free-form instructions. */
enum class LearnedStyle(val wire: String, @StringRes val title: Int) {
    LOWERCASE("lowercase_start", R.string.learned_style_lowercase), NO_PERIOD("no_final_period", R.string.learned_style_no_period)
}

internal class LearnedCorrection(val heard: String = "", val term: String = "", val style: LearnedStyle? = null) {
    val title: UiText get() = style?.let { UiText.Res(it.title) } ?: UiText.Raw(term)
    fun same(other: LearnedCorrection) = heard == other.heard && term == other.term && style == other.style
    override fun toString() = "LearnedCorrection(<redacted>)"
}

/** All offsets are UTF-16, as Android's editor APIs report them. */
internal object EditRegion {
    fun edited(before: String, after: String, start: Int, length: Int): String? {
        if (start < 0 || length < 0 || start > before.length - length) return null
        if (before == after) return before.substring(start, start + length)
        val prefix = before.commonPrefixWith(after).length
        val suffix = before.substring(prefix).commonSuffixWith(after.substring(prefix)).length
        val end = before.length - suffix
        if (prefix < start || end > start + length) return null
        if (prefix == end && (prefix == start || prefix == start + length)) return null
        val newEnd = after.length - (before.length - start - length)
        return if (newEnd >= start) after.substring(start, newEnd) else null
    }
}

internal object EditCorrections {
    private fun words(text: String) = text.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    private fun key(text: String) = text.lowercase(Locale.ROOT).filter { it.isLetterOrDigit() }
    fun strip(text: String) = text.trim { !it.isLetterOrDigit() }
    fun pronoun(text: String) = strip(text).let { it == "I" || it.startsWith("I'") || it.startsWith("I’") }
    fun acronym(text: String) = text.length > 1 && text == text.uppercase(Locale.ROOT) && text.any { it.isLetter() }
    private fun sentence(text: String) = text.lastOrNull() in listOf('.', '!', '?')
    private fun term(heard: String, typed: String, atStart: Boolean): LearnedCorrection? {
        if (heard.isBlank() || typed.isBlank() || heard == typed || typed.codePointCount(0, typed.length) > 48 ||
            heard.codePointCount(0, heard.length) > 64 || !typed.any { it.isLetter() } || key(heard).isEmpty() ||
            (heard + typed).any { it.code < 32 || it.code == 127 }) return null
        val w = words(typed)
        val technical = w.any { it.drop(1).any(Char::isUpperCase) } || typed.any(Char::isDigit) ||
            w.withIndex().any { (i, word) -> word.first().isUpperCase() && (i > 0 || !atStart) }
        return if (technical && !(w.size == 1 && pronoun(typed))) LearnedCorrection(heard.lowercase(Locale.ROOT), typed) else null
    }
    fun extract(inserted: String, edited: String): List<LearnedCorrection> {
        if (inserted == edited || inserted.length > 20000 || edited.length > 20000) return emptyList()
        val a = words(inserted); val b = words(edited)
        if (a.isEmpty() || b.isEmpty() || maxOf(a.size, b.size) > 300) return emptyList()
        val x = a.map(::key); val y = b.map(::key)
        val table = Array(a.size + 1) { IntArray(b.size + 1) }
        for (i in a.indices.reversed()) for (j in b.indices.reversed())
            table[i][j] = if (x[i] == y[j] && x[i].isNotEmpty()) 1 + table[i + 1][j + 1] else maxOf(table[i + 1][j], table[i][j + 1])
        val pairs = mutableListOf<Pair<Int, Int>>()
        var i = 0; var j = 0
        while (i < a.size && j < b.size) {
            if (x[i] == y[j] && x[i].isNotEmpty()) { pairs += i to j; i++; j++ }
            else if (table[i + 1][j] >= table[i][j + 1]) i++ else j++
        }
        if (pairs.size * 2 < maxOf(a.size, b.size) && maxOf(a.size, b.size) - pairs.size > 4) return emptyList()
        val out = mutableListOf<LearnedCorrection>()
        fun add(c: LearnedCorrection?) { if (c != null && out.none { it.same(c) }) out += c }
        var previous = -1 to -1
        for (p in pairs + (a.size to b.size)) {
            val heard = a.subList(previous.first + 1, p.first)
            val typed = b.subList(previous.second + 1, p.second)
            if (heard.size in 1..4 && typed.size in 1..3)
                add(term(strip(heard.joinToString(" ")), strip(typed.joinToString(" ")), previous.first < 0 || sentence(a[previous.first])))
            previous = p
        }
        for ((ai, bi) in pairs) {
            val h = strip(a[ai]); val t = strip(b[bi])
            if (h != t && h.equals(t, true) && h.zip(t).any { it.first.isLowerCase() && it.second.isUpperCase() } &&
                h.zip(t).none { it.first.isUpperCase() && it.second.isLowerCase() })
                add(term(h, t, ai == 0 || sentence(a[ai - 1])))
        }
        if (pairs.firstOrNull() == (0 to 0) && a.first().first().isUpperCase() &&
            b.first() == a.first().replaceFirstChar { it.lowercaseChar() } && !pronoun(a.first()) && !acronym(strip(a.first())))
            add(LearnedCorrection(style = LearnedStyle.LOWERCASE))
        // Require the final word to be retained: a deleted sentence isn't a punctuation habit.
        if (pairs.lastOrNull() == (a.lastIndex to b.lastIndex) && a.last().endsWith('.') && !a.last().endsWith("..") &&
            b.last().last().isLetterOrDigit()) add(LearnedCorrection(style = LearnedStyle.NO_PERIOD))
        return out
    }
}

/** Version 1 start.learned. Deliberately redacted, including nested terms/examples. */
class LearnedPayload(val terms: List<Term> = emptyList(), val style: List<LearnedStyle> = emptyList(), val examples: List<Example> = emptyList()) {
    class Term(val term: String, val heard: List<String>) { override fun toString() = "Term(<redacted>)" }
    class Example(val said: String, val wanted: String) { override fun toString() = "Example(<redacted>)" }
    val isEmpty get() = terms.isEmpty() && style.isEmpty() && examples.isEmpty()
    fun wire(): JSONObject = JSONObject().put("v", 1).apply {
        if (terms.isNotEmpty()) put("terms", JSONArray().apply { terms.forEach { put(JSONObject().put("term", it.term).put("heard", JSONArray(it.heard))) } })
        if (style.isNotEmpty()) put("style", JSONArray(style.map { it.wire }))
        if (examples.isNotEmpty()) put("examples", JSONArray().apply { examples.forEach { put(JSONObject().put("said", it.said).put("wanted", it.wanted)) } })
    }
    /** Same conservative fallback as Mac: single ordinary mishearings require the server's context. */
    fun apply(text: String): String {
        var out = text
        for (t in terms) for (h in t.heard) if (h.contains(' ') || h.equals(t.term, true)) {
            val pattern = "(?<![\\p{L}\\p{N}_'’-])" + h.split(Regex("\\s+")).joinToString("\\s+") { Regex.escape(it) } + "(?![\\p{L}\\p{N}_'’-])"
            out = Regex(pattern, RegexOption.IGNORE_CASE).replace(out) { t.term }
        }
        val first = out.substringBefore(' ')
        if (LearnedStyle.LOWERCASE in style && !EditCorrections.pronoun(first) && !EditCorrections.acronym(EditCorrections.strip(first)) &&
            terms.none { first.startsWith(it.term) }) out = out.replaceFirstChar { it.lowercaseChar() }
        if (LearnedStyle.NO_PERIOD in style && out.endsWith('.') && !out.endsWith("..")) out = out.dropLast(1)
        return out
    }
    override fun toString() = "LearnedPayload(<redacted>)"
}
