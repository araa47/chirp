package dev.chirp.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.provider.Settings
import android.view.ContextThemeWrapper
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

@RunWith(RobolectricTestRunner::class)
@Config(application = ChirpApplication::class, sdk = [37])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class KeyboardRippleTest {
    @Test fun `reduced motion listening arc remains visible through the middle of the meter`() {
        val app = RuntimeEnvironment.getApplication()
        Settings.Global.putFloat(app.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        val strip = KeyboardStrip(ContextThemeWrapper(app, R.style.Theme_Chirp))
        strip.show(statusOf("Listening…"), "", true, false, false, false)
        strip.level(.5)
        val meter = (0 until strip.childCount).map(strip::getChildAt).single { it.contentDescription == "Microphone level" }
        meter.layout(0, 0, 72, 48)
        val bitmap = Bitmap.createBitmap(72, 48, Bitmap.Config.ARGB_8888)
        meter.draw(Canvas(bitmap))
        val middle = (20..28).sumOf { y -> (0 until 72).count { x -> (bitmap.getPixel(x, y) ushr 24) > 32 } }
        assertTrue("The listening arc must cross the visible middle, rather than being clipped outside it", middle >= 8)
    }
}
