package com.superconnect.receiver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FossGestureRestorationTest {
    private data class Point(val id: Int, val x: Float, val y: Float)

    private class Touch(
        override val actionMasked: Int,
        override val actionIndex: Int,
        override val eventTime: Long,
        private val points: List<Point>,
    ) : FossTouchEvent {
        override val pointerCount get() = points.size
        override val historySize get() = 0
        override fun getPointerId(index: Int) = points[index].id
        override fun findPointerIndex(id: Int) = points.indexOfFirst { it.id == id }
        override fun getX(index: Int) = points[index].x
        override fun getY(index: Int) = points[index].y
        override fun getHistoricalX(index: Int, history: Int): Float = error("no history")
        override fun getHistoricalY(index: Int, history: Int): Float = error("no history")
    }

    @Test fun singleFingerTapAndDragHaveNoPrematurePress() {
        val emitted = mutableListOf<Emit>()
        val gesture = GestureController(emitted::add)
        gesture.onDown(Touch(FossTouchEvent.ACTION_DOWN, 0, 0, listOf(Point(1, 20f, 30f))))
        assertEquals(listOf(FossInputType.HOVER.value), emitted.map { it.type })
        gesture.onUp(Touch(FossTouchEvent.ACTION_UP, 0, 100, listOf(Point(1, 20f, 30f))), false)
        assertEquals(listOf(3, 0, 2), emitted.map { it.type })
        emitted.clear()

        gesture.onDown(Touch(FossTouchEvent.ACTION_DOWN, 0, 200, listOf(Point(1, 20f, 30f))))
        gesture.onMove(Touch(FossTouchEvent.ACTION_MOVE, 0, 240, listOf(Point(1, 45f, 30f))))
        gesture.onUp(Touch(FossTouchEvent.ACTION_UP, 0, 260, listOf(Point(1, 45f, 30f))), false)
        assertEquals(listOf(3, 0, 1, 1, 2), emitted.map { it.type })
        assertEquals(1, emitted.first { it.type == FossInputType.TOUCH_DOWN.value }.buttons)
        assertEquals(0, emitted.last().buttons)
    }

    @Test fun twoFingerTapRightClicksWithoutStrayPrimary() {
        val emitted = mutableListOf<Emit>()
        val gesture = GestureController(emitted::add)
        gesture.onDown(Touch(0, 0, 0, listOf(Point(1, 0f, 0f))))
        gesture.onDown(Touch(5, 1, 30, listOf(Point(1, 0f, 0f), Point(2, 20f, 0f))))
        gesture.onUp(Touch(6, 1, 90, listOf(Point(1, 0f, 0f), Point(2, 20f, 0f))), false)
        gesture.onUp(Touch(1, 0, 100, listOf(Point(1, 0f, 0f))), false)
        val presses = emitted.filter { it.type == FossInputType.TOUCH_DOWN.value }
        assertEquals(1, presses.size)
        assertEquals(2, presses.single().buttons)
        assertEquals(1, emitted.count { it.type == FossInputType.TOUCH_UP.value })
    }

    @Test fun twoFingerScrollAndPinchUseExistingInputTypes() {
        val scroll = mutableListOf<Emit>()
        val scroller = GestureController(scroll::add)
        scroller.onDown(Touch(0, 0, 0, listOf(Point(1, 0f, 0f))))
        scroller.onDown(Touch(5, 1, 10, listOf(Point(1, 0f, 0f), Point(2, 20f, 0f))))
        scroller.onMove(Touch(2, 0, 20, listOf(Point(1, 0f, 18f), Point(2, 20f, 18f))))
        assertTrue(scroll.any { it.type == FossInputType.SCROLL.value && it.scrollY > 0f })
        assertFalse(scroll.any { it.type == FossInputType.TOUCH_DOWN.value })

        val zoom = mutableListOf<Emit>()
        val pincher = GestureController(zoom::add)
        pincher.onDown(Touch(0, 0, 0, listOf(Point(1, 0f, 0f))))
        pincher.onDown(Touch(5, 1, 10, listOf(Point(1, 0f, 0f), Point(2, 20f, 0f))))
        pincher.onMove(Touch(2, 0, 20, listOf(Point(1, -10f, 0f), Point(2, 30f, 0f))))
        pincher.onUp(Touch(6, 1, 30, listOf(Point(1, -10f, 0f), Point(2, 30f, 0f))), false)
        assertEquals(listOf(1, 0, 2), zoom.filter {
            it.type == FossInputType.ZOOM.value
        }.map { it.buttons })

        val cancelled = mutableListOf<Emit>()
        val interrupted = GestureController(cancelled::add)
        interrupted.onDown(Touch(0, 0, 0, listOf(Point(1, 0f, 0f))))
        interrupted.onDown(Touch(5, 1, 10, listOf(Point(1, 0f, 0f), Point(2, 20f, 0f))))
        interrupted.onMove(Touch(2, 0, 20, listOf(Point(1, -10f, 0f), Point(2, 30f, 0f))))
        interrupted.abortForPen()
        assertEquals(2, cancelled.last().buttons)
        assertEquals(FossInputType.ZOOM.value, cancelled.last().type)
    }

    @Test fun drawingModeRejectsPalmDuringPenAndGracePeriod() {
        assertFalse(fossRejectPalm(false, -600, 0))
        assertTrue(fossRejectPalm(true, 0, 1_000))
        assertTrue(fossRejectPalm(false, 1_000, 1_599))
        assertFalse(fossRejectPalm(false, 1_000, 1_600))
        fun route(stylus: Boolean, drawing: Boolean, fingerPen: Boolean, held: Boolean, now: Long) =
            fossTouchRoute(stylus, false, drawing, fingerPen, held, 1_000, now)
        assertEquals(FossTouchRoute.Pen, route(true, true, true, false, 1_100))
        assertEquals(FossTouchRoute.RejectPalm, route(false, true, true, true, 1_100))
        assertEquals(FossTouchRoute.RejectPalm, route(false, true, true, false, 1_599))
        assertEquals(FossTouchRoute.Pen, route(false, true, true, false, 1_600))
        assertEquals(FossTouchRoute.Gesture, route(false, true, false, false, 1_600))
        val emitted = mutableListOf<Emit>()
        val gesture = GestureController(emitted::add)
        gesture.setDrawing(true)
        gesture.onDown(Touch(0, 0, 0, listOf(Point(1, 0f, 0f))))
        gesture.onMove(Touch(2, 0, 30, listOf(Point(1, 30f, 0f))))
        gesture.onUp(Touch(1, 0, 60, listOf(Point(1, 30f, 0f))), false)
        assertFalse(emitted.any { it.type == FossInputType.TOUCH_DOWN.value })
    }
}
