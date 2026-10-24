package dev.chirp.android

import android.net.Uri
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.JniUtils
import helium314.keyboard.latin.utils.protectedPrefs
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.File

@RunWith(RobolectricTestRunner::class)
class GestureLibraryTest {
    private fun elf(machine: Int, bits: Int = 2, type: Int = 3) = ByteArray(64).apply {
        this[0] = 0x7f; this[1] = 'E'.code.toByte(); this[2] = 'L'.code.toByte(); this[3] = 'F'.code.toByte()
        this[4] = bits.toByte(); this[5] = 1; this[16] = type.toByte(); this[18] = (machine and 0xff).toByte(); this[19] = (machine shr 8).toByte()
    }

    @Test fun `header check accepts only shared objects for this phone's ABI`() {
        assertEquals(GestureLibrary.Check.UNKNOWN, GestureLibrary.inspect(elf(183), "arm64-v8a"))
        assertEquals(GestureLibrary.Check.UNKNOWN, GestureLibrary.inspect(elf(62), "x86_64"))
        assertEquals(GestureLibrary.Check.WRONG_ABI, GestureLibrary.inspect(elf(62), "arm64-v8a"))
        assertEquals(GestureLibrary.Check.WRONG_ABI, GestureLibrary.inspect(elf(183, bits = 1), "arm64-v8a"))
        assertEquals(GestureLibrary.Check.NOT_LIBRARY, GestureLibrary.inspect(elf(183, type = 2), "arm64-v8a"))
        assertEquals(GestureLibrary.Check.NOT_LIBRARY, GestureLibrary.inspect("<html>not a library</html>".toByteArray(), "arm64-v8a"))
        assertEquals(GestureLibrary.Check.NOT_LIBRARY, GestureLibrary.inspect(ByteArray(4), "arm64-v8a"))
    }

    @Test fun `only the known SHA-256 counts as verified, as in HeliBoard`() {
        val known = "b1049983e6ac5cfc6d1c66e38959751044fad213dff0637a6cf1d2a2703e754f"
        assertEquals(GestureLibrary.Check.KNOWN, GestureLibrary.verdict(elf(183), known.uppercase(), "arm64-v8a", known))
        assertEquals(GestureLibrary.Check.UNKNOWN, GestureLibrary.verdict(elf(183), "00$known".take(64), "arm64-v8a", known))
        assertEquals(GestureLibrary.Check.WRONG_ABI, GestureLibrary.verdict(elf(62), known, "arm64-v8a", known))
    }

    @Test fun `install uses HeliBoard's loader file and checksum, remove clears both`() {
        val context = RuntimeEnvironment.getApplication()
        JniUtils.loadNativeLibrary() // static loader runs before the file exists, as in a real process start
        val candidate = File(context.filesDir, "candidate-test").apply { writeBytes(elf(183)) }
        GestureLibrary.install(context, candidate, "abc123")
        val installed = GestureLibrary.file(context)
        assertEquals(JniUtils.JNI_LIB_IMPORT_FILE_NAME, installed.name)
        assertTrue(installed.isFile); assertFalse(installed.canWrite()); assertFalse(candidate.exists())
        assertEquals("abc123", context.protectedPrefs().getString(Settings.PREF_LIBRARY_CHECKSUM, null))
        assertEquals(GestureLibrary.Status.NOT_LOADED, GestureLibrary.status(context, loaded = false))
        assertEquals(GestureLibrary.Status.ACTIVE, GestureLibrary.status(context, loaded = true))
        GestureLibrary.remove(context)
        assertFalse(installed.exists())
        assertFalse(context.protectedPrefs().contains(Settings.PREF_LIBRARY_CHECKSUM))
        assertEquals(GestureLibrary.Status.NONE, GestureLibrary.status(context, loaded = false))
        assertEquals("Loaded with no added file: the APK's own library", GestureLibrary.Status.BUILT_IN, GestureLibrary.status(context, loaded = true))
    }

    @Test fun `picked documents are staged privately and rejected files are deleted`() {
        val context = RuntimeEnvironment.getApplication()
        val picked = File(context.cacheDir, "picked.so").apply { writeBytes(elf(183)) }
        val (check, checksum) = GestureLibrary.stage(context, Uri.fromFile(picked), "arm64-v8a")
        assertEquals(GestureLibrary.Check.UNKNOWN, check)
        assertEquals(64, checksum.length)
        assertTrue(GestureLibrary.candidate(context).isFile)
        val text = File(context.cacheDir, "notes.txt").apply { writeText("hello") }
        assertEquals(GestureLibrary.Check.WRONG_ABI, GestureLibrary.stage(context, Uri.fromFile(picked), "x86_64").first)
        assertFalse(GestureLibrary.candidate(context).exists())
        assertEquals(GestureLibrary.Check.NOT_LIBRARY, GestureLibrary.stage(context, Uri.fromFile(text), "arm64-v8a").first)
        assertFalse(GestureLibrary.candidate(context).exists())
        assertFalse("Staging never installs", GestureLibrary.file(context).exists())
    }
}
