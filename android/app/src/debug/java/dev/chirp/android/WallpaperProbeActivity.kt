package dev.chirp.android

import android.app.Activity
import android.app.WallpaperColors
import android.app.WallpaperManager
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.util.Log

/**
 * Debug-only: sets a photo-like gradient as the home and lock wallpaper, so the emulator's Match wallpaper
 * check (#332) runs on colours Android extracts from a real wallpaper. `--eia colors <top>,<middle>,<bottom>` (ARGB).
 */
class WallpaperProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val stops = intent.getIntArrayExtra("colors")?.takeIf { it.size == 3 } ?: return finish()
        val width = 540; val height = 1260
        val pixels = IntArray(width * height)
        for (y in 0 until height) {
            val t = y / (height - 1f)
            val (a, b, f) = if (t < .5f) Triple(stops[0], stops[1], t * 2) else Triple(stops[1], stops[2], t * 2 - 1)
            for (x in 0 until width) {
                // Fine grain, so the quantiser sees a photo rather than flat bands.
                val grain = (x * 7919 + y * 104729) % 23 - 11
                fun channel(shift: Int) = ((a shr shift and 0xff) + ((b shr shift and 0xff) - (a shr shift and 0xff)) * f + grain).toInt().coerceIn(0, 255)
                pixels[y * width + x] = Color.rgb(channel(16), channel(8), channel(0))
            }
        }
        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        val manager = WallpaperManager.getInstance(this)
        manager.setBitmap(bitmap, null, true, WallpaperManager.FLAG_SYSTEM or WallpaperManager.FLAG_LOCK)
        // The seed System UI's dynamic palette is built from. The system extracts it asynchronously (ImageWallpaper);
        // until it has, WallpaperColors.fromBitmap runs the same extraction on the same bitmap.
        val system = manager.getWallpaperColors(WallpaperManager.FLAG_SYSTEM)
        val primary = (system ?: WallpaperColors.fromBitmap(bitmap)).primaryColor.toArgb()
        Log.i("ChirpWallpaperProbe", "wallpaper set primary=%06X source=%s".format(primary and 0xffffff, if (system != null) "system" else "bitmap"))
        finish()
    }
}
