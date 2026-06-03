package com.superconnect.receiver

import android.view.MotionEvent
import com.superconnect.protocol.InputTool
import com.superconnect.protocol.InputType
import kotlin.math.abs
import kotlin.math.sqrt

/** A semantic gesture event in VIEW PIXELS; [InputRouter] normalizes x/y to [0,1] and frames it. */
data class Emit(
    val type: Int, val tool: Int, val buttons: Int,
    val x: Float, val y: Float, val scrollX: Float, val scrollY: Float,
)

/**
 * Finger gesture state machine — Kotlin port of harmony `input/GestureController.ets`, byte-for-byte
 * logic (same thresholds, same states). Owns ALL finger disambiguation so the Mac stays a near-stateless
 * executor:
 *   Desktop (drawing=false): 1 finger = move+click(tap)+drag · 2-finger tap = right-click · 2-finger drag = scroll · pinch = zoom
 *   Drawing (drawing=true):  1 finger = discarded (only the pen inks) · 2-finger tap/drag as above
 *
 * Disambiguation is DEFER-THEN-COMMIT: the first finger Down emits only a no-button HOVER (cursor warps);
 * a real left press is withheld until intent is known (move > MOVE_GATE → drag, lift → click) so a 2nd
 * finger can promote to a 2-finger gesture with zero stray left clicks. Pen is handled by [InputRouter]
 * BEFORE this (stylus short-circuits to the pressure path); this machine is finger-only.
 *
 * Works in VIEW PIXELS; emits via [emit]; the router normalizes + frames onto the INPUT channel.
 */
class GestureController(private val emit: (Emit) -> Unit) {
    private companion object {
        const val MOVE_GATE = 8f        // 1-finger move that commits a drag
        const val TAP_SLOP = 8f         // max travel for a 1-finger tap-click
        const val TAP_MAX_MS = 250L     // max duration for a 1-finger tap-click
        const val SCROLL_START = 6f     // centroid travel that latches scroll
        const val PINCH_START = 8f      // spread travel that latches pinch-zoom
        const val PINCH_BIAS = 1.3f     // winning accumulator must beat the other by 30%
        const val TWO_TAP_SLOP = 12f    // max centroid travel for a 2-finger tap
        const val TWO_TAP_MAX_MS = 300L // max duration for a 2-finger right-click
        const val PRIMARY = 0x01
        const val SECONDARY = 0x02
    }

    private enum class S { Idle, Pending, OneFinger, TwoPending, Scrolling, Pinching, Swallow }

    private var st = S.Idle
    private var drawing = false
    private val ids = ArrayList<Int>()              // tracked pointer ids (1 or 2)
    private var downX = 0f; private var downY = 0f
    private var lastX = 0f; private var lastY = 0f
    private val buffered = ArrayList<FloatArray>()  // [x,y] buffered while Pending (replayed on drag commit)
    private var downMs = 0L
    private var maxTravel = 0f
    private var movedOnce = false
    private var twoStartX = 0f; private var twoStartY = 0f
    private var twoLastX = 0f; private var twoLastY = 0f
    private var twoTravel = 0f
    private var spreadLast = 0f                      // inter-finger distance last move
    private var spreadTravel = 0f                    // accumulated |spread change| since 2-finger start

    fun setDrawing(d: Boolean) { drawing = d }

    private fun dist(ax: Float, ay: Float, bx: Float, by: Float): Float {
        val dx = ax - bx; val dy = ay - by; return sqrt(dx * dx + dy * dy)
    }

    private fun reset() {
        st = S.Idle; ids.clear(); buffered.clear()
        maxTravel = 0f; movedOnce = false; twoTravel = 0f; spreadTravel = 0f; downMs = 0L
    }

    private fun fire(type: Int, buttons: Int, x: Float, y: Float) =
        emit(Emit(type, InputTool.FINGER.value, buttons, x, y, 0f, 0f))

    private fun fireScroll(dx: Float, dy: Float) =
        emit(Emit(InputType.SCROLL.value, InputTool.FINGER.value, 0, 0f, 0f, dx, dy))

    /** Zoom (magnify): scrollY = per-frame magnification delta (ratio; + = zoom in), x/y = centroid
     *  (cursor anchor), buttons = phase (1=began, 0=changed, 2=ended). */
    private fun fireZoom(delta: Float, cx: Float, cy: Float, phase: Int) =
        emit(Emit(InputType.ZOOM.value, InputTool.FINGER.value, phase, cx, cy, 0f, delta))

    /** Centroid of the tracked ids still present in [ev]; falls back to the last centroid. */
    private fun centroid(ev: MotionEvent): FloatArray {
        var sx = 0f; var sy = 0f; var n = 0
        for (id in ids) {
            val idx = ev.findPointerIndex(id)
            if (idx >= 0) { sx += ev.getX(idx); sy += ev.getY(idx); n++ }
        }
        return if (n > 0) floatArrayOf(sx / n, sy / n) else floatArrayOf(twoLastX, twoLastY)
    }

    /** Inter-finger distance; falls back to last value if a finger is momentarily absent. */
    private fun spread(ev: MotionEvent): Float {
        if (ids.size < 2) return spreadLast
        val i0 = ev.findPointerIndex(ids[0]); val i1 = ev.findPointerIndex(ids[1])
        if (i0 < 0 || i1 < 0) return spreadLast
        return dist(ev.getX(i0), ev.getY(i0), ev.getX(i1), ev.getY(i1))
    }

    /** Ids still down AFTER this event (the lifting pointer at actionIndex is excluded; CANCEL = none). */
    private fun remainingCount(ev: MotionEvent): Int {
        val a = ev.actionMasked
        if (a == MotionEvent.ACTION_CANCEL) return 0
        val lifting = if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_POINTER_UP)
            ev.getPointerId(ev.actionIndex) else -1
        var n = 0
        for (i in 0 until ev.pointerCount) if (ev.getPointerId(i) != lifting) n++
        return n
    }

    private fun stillDown(ev: MotionEvent, id: Int): Boolean {
        val a = ev.actionMasked
        if (a == MotionEvent.ACTION_CANCEL) return false
        val lifting = if (a == MotionEvent.ACTION_UP || a == MotionEvent.ACTION_POINTER_UP)
            ev.getPointerId(ev.actionIndex) else -1
        if (id == lifting) return false
        return ev.findPointerIndex(id) >= 0
    }

    fun onDown(ev: MotionEvent) {
        val live = ev.pointerCount

        // Two (or more) fingers already present in one Down callback.
        if (st == S.Idle && live >= 2) {
            ids.clear()
            for (i in 0 until live) ids.add(ev.getPointerId(i))
            enterTwo(ev)
            return
        }

        // First finger lands.
        if (st == S.Idle && live == 1) {
            val id = ev.getPointerId(ev.actionIndex)
            ids.clear(); ids.add(id)
            downX = ev.getX(ev.actionIndex); downY = ev.getY(ev.actionIndex)
            lastX = downX; lastY = downY
            buffered.clear(); buffered.add(floatArrayOf(downX, downY))
            downMs = ev.eventTime
            maxTravel = 0f; movedOnce = false
            st = S.Pending
            fire(InputType.HOVER.value, 0, downX, downY)   // warp cursor, no button yet
            // No timer press: a stationary lift becomes a CLICK (onUp); a move past MOVE_GATE commits a
            // left-drag. A 2nd finger promotes to a 2-finger gesture, and since nothing was pressed there
            // is no stray click.
            return
        }

        // Second finger arrives during the pending window → 2-finger gesture (nothing was pressed).
        if (st == S.Pending) {
            val id = ev.getPointerId(ev.actionIndex)
            if (ids.contains(id)) return
            ids.add(id)
            enterTwo(ev)
            return
        }

        // Extra finger during a committed one-finger drag → remember id, keep dragging.
        if (st == S.OneFinger) {
            val id = ev.getPointerId(ev.actionIndex)
            if (!ids.contains(id)) ids.add(id)
            return
        }
    }

    private fun enterTwo(ev: MotionEvent) {
        val c = centroid(ev)
        twoStartX = c[0]; twoStartY = c[1]
        twoLastX = c[0]; twoLastY = c[1]
        twoTravel = 0f
        spreadLast = spread(ev)
        spreadTravel = 0f
        downMs = ev.eventTime
        st = S.TwoPending
    }

    private fun commitOne() {
        if (drawing) return                  // pointer mode never presses — the pen owns ink
        st = S.OneFinger
        movedOnce = true
        fire(InputType.TOUCH_DOWN.value, PRIMARY, downX, downY)
        for (p in buffered) fire(InputType.TOUCH_MOVE.value, PRIMARY, p[0], p[1])
    }

    fun onMove(ev: MotionEvent) {
        when (st) {
            S.Pending -> {
                val idx = ev.findPointerIndex(ids[0]); if (idx < 0) return
                val cx = ev.getX(idx); val cy = ev.getY(idx)
                buffered.add(floatArrayOf(cx, cy))
                maxTravel = maxOf(maxTravel, dist(cx, cy, downX, downY))
                lastX = cx; lastY = cy
                if (!drawing && maxTravel > MOVE_GATE) commitOne()        // direct mode: start a left-drag
                else fire(InputType.HOVER.value, 0, cx, cy)              // pointer/deferred: cursor follows
            }
            S.OneFinger -> {
                val idx = ev.findPointerIndex(ids[0]); if (idx < 0) return
                for (h in 0 until ev.historySize) {                      // replay buffered samples → smooth
                    fire(InputType.TOUCH_MOVE.value, PRIMARY, ev.getHistoricalX(idx, h), ev.getHistoricalY(idx, h))
                }
                lastX = ev.getX(idx); lastY = ev.getY(idx)
                fire(InputType.TOUCH_MOVE.value, PRIMARY, lastX, lastY)
            }
            S.TwoPending, S.Scrolling, S.Pinching -> {
                val c = centroid(ev)
                val curSpread = spread(ev)
                val dSpread = curSpread - spreadLast
                twoTravel += dist(c[0], c[1], twoLastX, twoLastY)
                spreadTravel += abs(dSpread)
                // First accumulator to dominate (by PINCH_BIAS) wins, then sticky for the gesture.
                if (st == S.TwoPending) {
                    if (spreadTravel > PINCH_START && spreadTravel > twoTravel * PINCH_BIAS) {
                        st = S.Pinching
                        fireZoom(0f, c[0], c[1], 1)                       // magnify BEGAN
                    } else if (twoTravel > SCROLL_START && twoTravel >= spreadTravel * PINCH_BIAS) {
                        st = S.Scrolling
                    }
                }
                if (st == S.Scrolling) {
                    fireScroll(c[0] - twoLastX, c[1] - twoLastY)
                } else if (st == S.Pinching) {
                    val ratio = if (spreadLast > 0f) (curSpread / spreadLast - 1f) else 0f
                    fireZoom(ratio, c[0], c[1], 0)                        // magnify CHANGED (per-frame delta)
                }
                twoLastX = c[0]; twoLastY = c[1]; spreadLast = curSpread
            }
            else -> {}
        }
    }

    /** [cancel]=true (ACTION_CANCEL) suppresses the synthetic tap-click so a button never sticks. */
    fun onUp(ev: MotionEvent, cancel: Boolean) {
        val remaining = remainingCount(ev)
        val dt = ev.eventTime - downMs

        when (st) {
            S.Pending -> {
                if (!cancel) {
                    val upX = if (buffered.isNotEmpty()) buffered.last()[0] else downX
                    val upY = if (buffered.isNotEmpty()) buffered.last()[1] else downY
                    maxTravel = maxOf(maxTravel, dist(upX, upY, downX, downY))
                    val tap = maxTravel < TAP_SLOP && dt < TAP_MAX_MS
                    if (tap) {
                        fire(InputType.TOUCH_DOWN.value, PRIMARY, downX, downY)   // tap → left click
                        fire(InputType.TOUCH_UP.value, 0, downX, downY)
                    } else if (!drawing) {
                        fire(InputType.TOUCH_DOWN.value, PRIMARY, downX, downY)   // direct-mode slow drift → click
                        fire(InputType.TOUCH_UP.value, 0, upX, upY)
                    }
                    // pointer mode (drawing) + non-tap = finger just moved the cursor → no ink, no click
                }
                reset()
            }
            S.OneFinger -> {
                if (stillDown(ev, ids[0])) return            // end the drag only when the PRIMARY finger lifts
                fire(InputType.TOUCH_UP.value, 0, lastX, lastY)
                reset()
            }
            S.TwoPending -> {
                if (!cancel && dt < TWO_TAP_MAX_MS && twoTravel < TWO_TAP_SLOP) {
                    fire(InputType.TOUCH_DOWN.value, SECONDARY, twoStartX, twoStartY)  // 2-finger tap → right click
                    fire(InputType.TOUCH_UP.value, 0, twoStartX, twoStartY)
                }
                if (remaining == 0) reset() else st = S.Swallow
            }
            S.Scrolling -> { if (remaining == 0) reset() else st = S.Swallow }
            S.Pinching -> {
                fireZoom(0f, twoLastX, twoLastY, 2)          // magnify ENDED
                if (remaining == 0) reset() else st = S.Swallow
            }
            S.Swallow -> { if (remaining == 0) reset() }
            else -> reset()
        }
    }

    /** Pen took over mid finger-gesture (router calls this when a stylus lands) — release any held button. */
    fun abortForPen() {
        if (st == S.OneFinger || movedOnce) fire(InputType.TOUCH_UP.value, 0, lastX, lastY)
        reset()
    }
}
