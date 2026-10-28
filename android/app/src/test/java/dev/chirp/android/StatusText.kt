package dev.chirp.android

import org.robolectric.RuntimeEnvironment

/** The default-locale words of typed text (#339): tests keep asserting the exact English users and e2e scripts read. */
internal val english get() = RuntimeEnvironment.getApplication().resources
internal fun UiText.english(): String = resolve(english)
/** The one fixed status with these words; fails when the wording drifts. */
internal fun statusOf(words: String): DictationStatus =
    (StatusLine.entries + ConnectionFailure.Kind.entries).singleOrNull { it.english() == words } ?: error("No status reads \"$words\"")
