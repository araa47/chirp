package dev.chirp.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

internal fun UiText.notesEnglish(): String = resolve(RuntimeEnvironment.getApplication().resources)
internal fun NotesStatus.notesEnglish(): String = text.notesEnglish()

/** Notes status text lives in resources (#339): the English is unchanged, and the logic matches on types. */
@RunWith(RobolectricTestRunner::class)
class NotesStatusTest {
    @Test fun `recording failures keep their English and decide the action by type`() {
        for ((failure, english) in listOf(
            RecordingFailure.Server.of("auth") to "Pairing refused — pair again in Chirp settings",
            RecordingFailure.Server.of("busy") to "Chirp server is busy",
            RecordingFailure.Server.of("too_long") to "Segment too long",
            RecordingFailure.Server.of("bad_audio") to "audio not understood",
            RecordingFailure.Server.of("engine") to "speech engine hiccup",
            RecordingFailure.Server.of("anything else") to "speech engine unavailable",
            RecordingFailure.TimedOut to "timed out",
            RecordingFailure.ConnectionClosed to "connection closed",
            RecordingFailure.ConnectionLost to "connection lost",
            RecordingFailure.Capture(null) to "The microphone stopped",
            RecordingFailure.Capture("Microphone unavailable") to "Microphone unavailable",
            RecordingFailure.Stopped(RecordingFailure.Server.BUSY) to "Notes stopped: Chirp server is busy",
        )) {
            assertEquals(english, failure.ui.notesEnglish())
            assertEquals("the stored and logged English is the same words", english, failure.english)
        }
        assertEquals(DictationAction.PAIR, RecordingFailure.Server.AUTH.action)
        assertNull(RecordingFailure.Server.BUSY.action)
        assertEquals(DictationAction.MICROPHONE, RecordingFailure.Capture("Microphone unavailable").action)
        assertNull(RecordingFailure.Capture(null).action)
        assertNull("a stopped recording offers no fix", RecordingFailure.Stopped(RecordingFailure.Server.AUTH).action)
    }

    @Test fun `connection failures are told apart by kind, and a deadline before Ready reads as the Mac being down`() {
        val other = RecordingFailure.Connection(ConnectionFailure.Kind.OTHER)
        assertEquals(true, other.maybeTailscale)
        assertEquals(DictationAction.NETWORK, other.action)
        assertEquals(ConnectionFailure.Kind.DOWN, RecordingFailure.Connection(null, timedOut = true).shown)
        assertEquals(false, RecordingFailure.Connection(null, timedOut = true).maybeTailscale)
        assertEquals(ConnectionFailure.Kind.DNS.status, RecordingFailure.Connection(ConnectionFailure.Kind.DNS).ui.notesEnglish())
        assertEquals(DictationAction.NETWORK, RecordingFailure.Connection(ConnectionFailure.Kind.DNS).action)
        assertNull("TLS has no Tailscale fix", RecordingFailure.Connection(ConnectionFailure.Kind.TLS).action)
    }

    @Test fun `messages carry the fix they offer`() {
        assertEquals(DictationAction.PAIR, NotesStatus.PAIR.action)
        assertEquals(DictationAction.PAIR, NotesStatus.PAIR_AGAIN.action)
        assertEquals(DictationAction.MICROPHONE, NotesStatus.ALLOW_MICROPHONE.action)
        assertEquals(DictationAction.MICROPHONE, NotesStatus.MICROPHONE_PERMISSION.action)
        assertEquals(DictationAction.TAILSCALE_ON, NotesStatus.TAILSCALE_OFF.action)
        assertEquals(DictationAction.TAILSCALE_SETUP, NotesStatus.TAILSCALE_MISSING.action)
        assertNull(NotesStatus.SAVED.action)
        assertEquals("Tailscale is off", NotesStatus.TAILSCALE_OFF.notesEnglish())
        assertEquals("Tailscale isn't installed", NotesStatus.TAILSCALE_MISSING.notesEnglish())
        assertEquals("Microphone permission is needed to take notes — open mic settings", NotesStatus.MICROPHONE_PERMISSION.notesEnglish())
    }

    @Test fun `saved voices errors keep their words by code`() {
        for ((code, english) in mapOf(
            "gone" to "Record a little more with them, then try again",
            "too_short" to "Name kept in this note. The voice will be remembered after 20 seconds of speech.",
            "disabled" to "Remember voices is off on your computer",
            "full" to "Saved voices is full. Forget a voice, then try again.",
            "no_voice" to "This voice was forgotten on another device. Refresh Saved voices.",
            "unsupported" to "Update Chirp on your computer to save voices",
            "bad_speakers" to "Use a name with letters, without colons or line breaks",
            "auth" to "Pair your computer again to use Saved voices",
            "failed" to "Couldn’t reach Saved voices. Try again.",
            "http" to "Couldn’t reach Saved voices. Try again.",
        )) assertEquals(english, VoiceLibraryError.text(code).notesEnglish())
        assertEquals(NotesStatus.VOICE_GONE.text, VoiceLibraryError.text("gone"))
    }

    @Test fun `re-transcribe notices, failures and progress keep their words, and only a new transcript can be restored`() {
        for ((notice, english, restorable) in listOf(
            Triple(RetranscribeNotice.Updated, "Transcript updated", true),
            Triple(RetranscribeNotice.Cancelled, "Cancelled. Nothing changed.", false),
            Triple(RetranscribeNotice.NoneUpdated, "No segments updated. Nothing changed.", false),
            Triple(RetranscribeNotice.RebuildFailed, "Couldn’t rebuild the notes. Transcript updated.", true),
            Triple(RetranscribeNotice.Partial(3, 5), "3 of 5 updated. 2 kept their old text.", true),
            Triple(RetranscribeNotice.Restored, "Previous transcript restored", false),
            Triple(RetranscribeNotice.Rebuilt, "Notes rebuilt", false),
            Triple(RetranscribeNotice.Interrupted, "Re-transcribe was interrupted. Nothing changed.", false),
        )) { assertEquals(english, notice.ui.notesEnglish()); assertEquals(english, restorable, notice.restorable) }
        assertEquals("Couldn’t finish re-transcribing. Nothing changed.", RetranscribeFailure.FAILED.ui.notesEnglish())
        assertEquals("This transcript changed. Re-transcribe again.", RetranscribeFailure.TRANSCRIPT_CHANGED.ui.notesEnglish())
        assertEquals("This note changed. Re-transcribe again.", RetranscribeFailure.NOTE_CHANGED.ui.notesEnglish())
        assertEquals("Re-transcribing · 12 of 40 · 1:32 of 8:10", RetranscribeProgress("n", 12, 40, 92.0, 490.0).label.notesEnglish())
        assertEquals("Waiting for your computer…", RetranscribeProgress("n", 12, 40, 92.0, 490.0, waiting = true).label.notesEnglish())
    }

    @Test fun `the transcript engine is a name, unknown or mixed`() {
        val none = NotesDocument()
        assertEquals(TranscriptEngine.Unknown, none.transcriptEngine)
        assertEquals("unknown", none.transcriptEngine.ui.notesEnglish())
        val one = NotesDocument().apply { append(NotesSegment(0, 0.0, "a", engine = "Parakeet v2")); append(NotesSegment(1, 1.0, "b", engine = "Parakeet v2")) }
        assertEquals(TranscriptEngine.Named("Parakeet v2"), one.transcriptEngine)
        assertEquals("Parakeet v2", one.transcriptEngine.ui.notesEnglish())
        one.append(NotesSegment(2, 2.0, "c", engine = "Whisper"))
        assertEquals(TranscriptEngine.Mixed, one.transcriptEngine)
        assertEquals("mixed", one.transcriptEngine.ui.notesEnglish())
        assertEquals("the previous transcript saves the words it always did", "mixed", TranscriptEngine.Mixed.wire)
        assertEquals("unknown", NotesDocument().apply { append(NotesSegment(0, 0.0, "a")) }.transcriptEngine.wire)
    }

    @Test fun `speaker model notices keep their words`() {
        assertEquals("Couldn’t cancel the speaker model download.", SpeakerModelNotice.CancelFailed.ui.notesEnglish())
        assertEquals("Getting the speaker model ready…", SpeakerModelNotice.Preparing(null).ui.notesEnglish())
        assertEquals("Getting the speaker model ready (27 MB, once)…", SpeakerModelNotice.Preparing(27).ui.notesEnglish())
    }
}
