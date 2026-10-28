package dev.chirp.android

import android.content.Context
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [37])
class BubblePlacementTest {
    // A 1080×2400 phone at 2.625: 56 dp = 147 px, 8 dp = 21, 16 dp = 42; status bar 120, nav bar 60.
    private val m = BubbleMetrics(1080, 2400, 120, 2340, 147, 21, 42)

    @Test fun `default is the right edge just above the field centre`() {
        val at = BubblePlacement.bubble(m, Area(42, 600, 900, 760), null)
        assertEquals(BubbleEdge.RIGHT, at.edge); assertEquals(1080 - 147, at.x)
        assertEquals(680 - 147, at.y)
    }
    @Test fun `never covers the field's text, nudged to the nearer side that fits`() {
        val field = Area(0, 500, 1080, 900) // full width, so any height overlaps horizontally
        val at = BubblePlacement.bubble(m, field, BubbleSpot(BubbleEdge.LEFT, BubblePlacement.fraction(560, m)))
        assertEquals(0, at.x)
        assertFalse(BubblePlacement.overlaps(Area(at.x, at.y, at.x + 147, at.y + 147), field))
        assertEquals(500 - 147 - 21, at.y)
        val low = BubblePlacement.bubble(m, field, BubbleSpot(BubbleEdge.LEFT, BubblePlacement.fraction(860, m)))
        assertEquals(900 + 21, low.y)
    }
    @Test fun `a remembered spot is restored and fractions survive the range`() {
        val spot = BubbleSpot(BubbleEdge.LEFT, BubblePlacement.fraction(1200, m))
        val at = BubblePlacement.bubble(m, Area(300, 300, 700, 400), spot)
        assertEquals(1200, at.y); assertEquals(BubbleEdge.LEFT, at.edge)
        assertEquals(0f, BubblePlacement.fraction(-50, m)); assertEquals(1f, BubblePlacement.fraction(9999, m))
    }
    @Test fun `with IME insets the bubble stays above the keyboard`() {
        val ime = m.copy(imeTop = 1500)
        val at = BubblePlacement.bubble(ime, Area(42, 300, 900, 400), BubbleSpot(BubbleEdge.RIGHT, 0.9f))
        assertTrue(at.y + 147 <= 1500)
    }
    @Test fun `without IME insets a field in the lower half puts the bubble above the field`() {
        val field = Area(42, 1900, 700, 2050)
        val at = BubblePlacement.bubble(m, field, BubbleSpot(BubbleEdge.RIGHT, 0.95f))
        assertTrue(at.y + 147 <= field.top)
    }
    @Test fun `snap goes to the nearest edge and drags stay on screen`() {
        assertEquals(BubbleEdge.LEFT, BubblePlacement.nearestEdge(539, 1080))
        assertEquals(BubbleEdge.RIGHT, BubblePlacement.nearestEdge(541, 1080))
        val dragged = BubblePlacement.dragged(m, -400, 5000)
        assertEquals(0, dragged.x); assertEquals(2340 - 147, dragged.y)
    }
    @Test fun `the panel goes above the field when there is room, otherwise below, never full width`() {
        val above = BubblePlacement.panel(m, Area(42, 1500, 1038, 1640), BubbleEdge.RIGHT, 1400, 945, 700)
        assertEquals(1500 - 21 - 700, above.top); assertEquals(1080 - 42, above.right); assertEquals(945, above.width)
        val below = BubblePlacement.panel(m, Area(42, 200, 1038, 330), BubbleEdge.LEFT, 200, 945, 700)
        assertEquals(330 + 21, below.top); assertEquals(42, below.left)
    }
    @Test fun `the hide target sits at bottom centre and catches a bubble dropped near it`() {
        val target = BubblePlacement.hideTarget(m, 168)
        assertEquals(540, target.centerX); assertTrue(target.bottom < 2340)
        assertTrue(BubblePlacement.overTarget(target.centerX + 40, target.centerY - 60, target))
        assertFalse(BubblePlacement.overTarget(100, 400, target))
    }
    @Test fun `posture keys separate cover and inner, portrait and landscape`() {
        assertEquals("cover-portrait", BubblePlacement.posture(1080, 2092, 2.625f))
        assertEquals("inner-portrait", BubblePlacement.posture(1840, 2208, 2.625f))
        assertEquals("inner-landscape", BubblePlacement.posture(2208, 1840, 2.625f))
        assertEquals("cover-landscape", BubblePlacement.posture(2092, 1080, 2.625f))
    }
    @Test fun `spots persist per posture as an edge and a fraction only`() {
        val context = RuntimeEnvironment.getApplication()
        val store = SettingsStore(context)
        assertNull(store.bubbleSpot("cover-portrait"))
        store.saveBubbleSpot("cover-portrait", BubbleSpot(BubbleEdge.LEFT, .25f))
        store.saveBubbleSpot("inner-portrait", BubbleSpot(BubbleEdge.RIGHT, 1.7f))
        assertEquals(BubbleSpot(BubbleEdge.LEFT, .25f), store.bubbleSpot("cover-portrait"))
        assertEquals(BubbleSpot(BubbleEdge.RIGHT, 1f), store.bubbleSpot("inner-portrait"))
        val keys = context.getSharedPreferences(SettingsStore.FILE, Context.MODE_PRIVATE).all.keys
        assertEquals(setOf("bubble_edge_cover-portrait", "bubble_y_cover-portrait", "bubble_edge_inner-portrait", "bubble_y_inner-portrait"), keys)
    }
    @Test fun `each error maps to exactly one fix and server text never chooses one`() {
        assertEquals(BubbleFix.PAIR, BubbleFix.forStatus(statusOf("Pair your computer to dictate")))
        assertEquals(BubbleFix.PAIR, BubbleFix.forStatus(statusOf("Pairing refused — pair again in Chirp settings")))
        assertEquals(BubbleFix.MICROPHONE, BubbleFix.forStatus(statusOf("Allow the microphone for Chirp")))
        assertEquals("Allow", english.getString(BubbleFix.MICROPHONE.label))
        assertEquals(BubbleFix.QUICK_DICTATE, BubbleFix.forStatus(statusOf("Android blocked the microphone here")))
        assertEquals(BubbleFix.TAILSCALE_ON, BubbleFix.forStatus(statusOf("Tailscale is off")))
        ConnectionFailure.Kind.entries.forEach { assertEquals(BubbleFix.CHECK_AGAIN, BubbleFix.forStatus(it)) }
        assertEquals(BubbleFix.CHECK_AGAIN, BubbleFix.forStatus(statusOf("Chirp server took too long — try again")))
        assertEquals(BubbleFix.TRY_AGAIN, BubbleFix.forStatus(statusOf("Didn't catch that")))
        assertEquals(BubbleFix.TRY_AGAIN, BubbleFix.forStatus(statusOf("Chirp server is busy — try again")))
        assertNull(BubbleFix.forStatus(statusOf("Listening…")))
        assertNull(PanelModel(FloatingState.LISTENING, status = StatusLine.BUBBLE_NOT_PAIRED).fix)
    }
}
