package dev.chirp.android

import android.app.Activity
import android.content.*
import android.os.Looper
import android.speech.RecognizerIntent
import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

internal class QuickRig(context: Context, mic: Boolean = true, paired: Boolean = true, historyOn: Boolean = false, io: (() -> Unit) -> Unit = { it() }) {
    lateinit var wire: Wire
    lateinit var capture: ChirpImeServiceTest.FakeCapture
    val history = DictationHistory(context, SoftwareHistoryKeys()).also { if (historyOn) it.enable() else it.disable() }
    val model = QuickDictateModel(context, history = history,
        captureFactory = { _, frame, _, done -> ChirpImeServiceTest.FakeCapture(frame, done, mutableListOf()).also { capture = it } },
        transportFactory = { _, _, event, failure -> Wire(event, failure).also { wire = it } },
        micGranted = { mic }, pairing = { if (paired) Pairing.from("https://speech.example.test/chirp", "synthetic") else null }, io = io)
    fun finish(corrected: Boolean = true) {
        wire.ready(); wire.partial(1, "synthetic words"); model.stop()
        shadowOf(Looper.getMainLooper()).idle()
        wire.final("Synthetic words.", "synthetic words", corrected)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [31, 37])
class QuickDictateTest {
    private val app get() = RuntimeEnvironment.getApplication()
    @Before fun reducedMotion() {
        android.provider.Settings.Global.putFloat(app.contentResolver, android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
    }
    class TestQuick : QuickDictateActivity() {
        internal lateinit var rig: QuickRig
        override fun createModel() = QuickRig(applicationContext).also { rig = it }.model
    }
    @Test fun `stop during learned preferences load still stops the eventual capture`() {
        val pending = mutableListOf<() -> Unit>()
        val rig = QuickRig(app, io = { pending += it })
        rig.model.start(); assertTrue(rig.model.active)
        rig.model.stop(); assertTrue(rig.model.stopping)
        pending.removeAt(0).invoke()
        assertTrue(rig.capture.started); assertTrue(rig.capture.stopRequested)
        rig.model.cancel()
    }

    @Test fun `private utterance stays out of history after session expiry`() {
        val rig = QuickRig(app, historyOn = true)
        PrivateSession.set(true)
        rig.model.start()
        PrivateSession.set(false)
        rig.finish()
        assertTrue(rig.history.entries().isEmpty())
        assertEquals("Synthetic words.", rig.model.text)
    }

    @Test fun `open starts capture and final copies sensitive text with raw undo`() {
        val controller = Robolectric.buildActivity(TestQuick::class.java).setup()
        val activity = controller.get()
        assertTrue(activity.model.status.english(), activity.model.active)
        activity.rig.finish()
        val clip = app.getSystemService(android.content.ClipboardManager::class.java).primaryClip!!
        assertEquals("Synthetic words.", clip.getItemAt(0).text)
        assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        assertEquals("Copied — paste anywhere", activity.model.status.english())
        activity.model.useRaw()
        assertEquals("synthetic words", app.getSystemService(android.content.ClipboardManager::class.java).primaryClip!!.getItemAt(0).text)
        assertNull(activity.model.raw)
        assertTrue(activity.rig.capture.released); assertFalse(activity.model.active)
        controller.pause().stop().destroy()
    }
    @Test fun `Speak returns exactly its polished final and unknown confidence without copying`() {
        val request = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 5)
            .putExtra(RecognizerIntent.EXTRA_PROMPT, "Synthetic prompt").putExtra(RecognizerIntent.EXTRA_LANGUAGE, "xx")
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true).putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        val controller = Robolectric.buildActivity(TestQuick::class.java, request).setup()
        val activity = controller.get(); activity.rig.finish()
        val result = shadowOf(activity)
        assertEquals(Activity.RESULT_OK, result.resultCode)
        assertEquals(listOf("Synthetic words."), result.resultIntent.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS))
        assertArrayEquals(floatArrayOf(-1f), result.resultIntent.getFloatArrayExtra(RecognizerIntent.EXTRA_CONFIDENCE_SCORES), 0f)
        assertEquals(setOf(RecognizerIntent.EXTRA_RESULTS, RecognizerIntent.EXTRA_CONFIDENCE_SCORES), result.resultIntent.extras!!.keySet())
        assertNull(app.getSystemService(android.content.ClipboardManager::class.java).primaryClip)
        assertTrue(activity.isFinishing)
        controller.pause().stop().destroy()
    }
    @Test fun `back cancels and leaving even while finishing closes capture and ignores late finals`() {
        val controller = Robolectric.buildActivity(TestQuick::class.java, Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)).setup()
        val activity = controller.get(); activity.rig.wire.ready(); activity.model.stop()
        controller.pause().stop()
        activity.rig.wire.final("Late words")
        assertFalse(activity.model.active); assertEquals("", activity.model.text)
        assertTrue(activity.rig.capture.released); assertTrue(activity.rig.wire.cancelled)
        activity.onBackPressedDispatcher.onBackPressed()
        assertEquals(Activity.RESULT_CANCELED, shadowOf(activity).resultCode)
        controller.destroy()
    }
    @Test fun `network engine and microphone errors give the matching Activity result when abandoned`() {
        for ((message, code) in listOf("Computer unreachable — is Tailscale on?" to RecognizerIntent.RESULT_NETWORK_ERROR,
            "Speech engine hiccup" to RecognizerIntent.RESULT_SERVER_ERROR, "Microphone unavailable" to RecognizerIntent.RESULT_AUDIO_ERROR)) {
            val controller = Robolectric.buildActivity(TestQuick::class.java, Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)).setup()
            val activity = controller.get()
            activity.rig.wire.event(ServerEvent.Failure(if (code == RecognizerIntent.RESULT_SERVER_ERROR) "engine" else "bad_audio"))
            assertEquals(code, QuickDictateModel.errorFor(statusOf(message)))
            if (code == RecognizerIntent.RESULT_NETWORK_ERROR) {
                activity.model.start(); activity.rig.wire.failure()
            }
            activity.abandon(false)
            assertEquals(code, shadowOf(activity).resultCode)
            controller.pause().stop().destroy()
        }
    }
    @Test fun `untouched copied result closes after four seconds`() {
        val controller = Robolectric.buildActivity(TestQuick::class.java).setup()
        val activity = controller.get(); activity.rig.finish()
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(3999)); assertFalse(activity.isFinishing)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1)); assertTrue(activity.isFinishing)
        controller.pause().stop().destroy()
    }
    @Test fun `Check again retries the stream and Pair computer delivers the pairing entry`() {
        val controller = Robolectric.buildActivity(TestQuick::class.java).setup()
        val activity = controller.get(); val first = activity.rig.wire
        first.failure(); assertFalse(activity.model.active)
        activity.fix()
        assertTrue(activity.model.active); assertNotSame(first, activity.rig.wire)
        assertNull(shadowOf(activity).nextStartedActivity)
        activity.model.cancel(); activity.model.status = StatusLine.NOT_PAIRED
        activity.fix()
        val setup = shadowOf(activity).nextStartedActivity
        assertEquals("pair", setup.getStringExtra("section"))
        assertTrue(setup.flags and Intent.FLAG_ACTIVITY_CLEAR_TOP != 0)
        controller.pause().stop().destroy()
    }
    @Test fun `history respects explicit off and uses only this entry label`() {
        val off = QuickRig(app); off.model.start(); off.finish(); assertTrue(off.history.entries().isEmpty())
        val on = QuickRig(app, historyOn = true); on.model.appLabel = "Synthetic caller"; on.model.start(); on.finish()
        val row = on.history.entries().single()
        assertEquals("Synthetic caller", row.app); assertEquals("Synthetic words.", row.text); assertEquals("synthetic words", row.raw)
    }
    @Test fun `setup failures do not start microphone and manifest resolves Speak`() {
        val mic = QuickRig(app, mic = false); mic.model.start(); assertEquals(RecognizerIntent.RESULT_AUDIO_ERROR, mic.model.errorCode)
        val pair = QuickRig(app, paired = false); pair.model.start(); assertEquals(RecognizerIntent.RESULT_SERVER_ERROR, pair.model.errorCode)
        assertFalse(mic.model.active); assertFalse(pair.model.active)
        val match = app.packageManager.queryIntentActivities(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).setPackage(app.packageName), 0).single()
        assertEquals(QuickDictateActivity::class.java.name, match.activityInfo.name)
        assertTrue(match.activityInfo.exported)
        assertTrue(match.activityInfo.flags and android.content.pm.ActivityInfo.FLAG_EXCLUDE_FROM_RECENTS != 0)
        assertTrue(match.activityInfo.flags and android.content.pm.ActivityInfo.FLAG_NO_HISTORY != 0)
    }
}
