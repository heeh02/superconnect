package com.superconnect.receiver

import android.os.SystemClock
import android.view.MotionEvent
import com.superconnect.protocol.InputButtons
import com.superconnect.protocol.InputEvent
import com.superconnect.protocol.InputTool
import com.superconnect.protocol.InputType

/**
 * Input dispatch seam — Kotlin port of harmony `input/InputRouter.ets`. Owns the wire seam (every send
 * goes through [InputSender], so the bytes match the inline version) and routes pointer streams to
 * cohesive, self-contained handlers:
 *   • stylus/eraser → pen pressure path (pressure + tilt, single tracked contact)
 *   • finger        → [GestureController] (the gesture FSM)
 *   • mouse         → finger path for now (absolute), per the parity analysis — the Mac's mouse path
 *                     expects RELATIVE deltas, so routing mouse as a finger avoids the pinned-cursor
 *                     bug until the dedicated TrackpadHandler (relative cursor) lands in a later phase.
 *
 * Each handler's latches are internal to it, so a change to one cannot affect the others (the project's
 * modularity rule). The FSM emits in VIEW PIXELS; this seam normalizes x/y to [0,1] (except SCROLL,
 * whose deltas pass through in pixels for the Mac to scale).
 *
 * [videoRect] returns the on-screen video rectangle `[left, top, width, height]` in the SAME coordinate
 * space as the touch events fed to [onTouch]. The touch listener lives on the FULL-SCREEN root (not the
 * letterboxed SurfaceView), so a finger anywhere is captured; we then map it against the video rect —
 * (raw − left)/width → [0,1] across the Mac screen, with black-bar touches clamped to the nearest edge
 * (harmless) rather than lost. This is what restores touch after the aspect-fit/letterbox UI change.
 */
class InputRouter(
    private val sender: InputSender,
    private val videoRect: () -> FloatArray,   // [left, top, width, height] of the video surface, in touch coords
) {
    private var drawing = false
    private var penId = -1

    private val gc = GestureController { m ->
        val isScroll = m.type == InputType.SCROLL.value
        val r = videoRect(); val left = r[0]; val top = r[1]
        val w = r[2].coerceAtLeast(1f); val h = r[3].coerceAtLeast(1f)
        val nx = if (isScroll) 0f else ((m.x - left) / w).coerceIn(0f, 1f)
        val ny = if (isScroll) 0f else ((m.y - top) / h).coerceIn(0f, 1f)
        sender.send(InputEvent(
            type = m.type, tool = m.tool, buttons = m.buttons, flags = 0,
            timestampMs = SystemClock.uptimeMillis(),
            x = nx, y = ny, scrollX = m.scrollX, scrollY = m.scrollY,
        ))
    }

    /** Drawing mode (set by the future floating ball / control panel): 1 finger inks-only, no left press. */
    fun setDrawing(d: Boolean) { drawing = d; gc.setDrawing(d) }

    /** Touch entry — the full-screen root's OnTouchListener delegates here. Always consumes (returns true). */
    fun onTouch(ev: MotionEvent): Boolean {
        val r = videoRect(); if (r[2] <= 0f || r[3] <= 0f) return true   // no video laid out yet
        // Stylus anywhere in the gesture → pen pressure path (P1 adds history replay + palm rejection).
        if (anyStylus(ev)) {
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) gc.abortForPen()   // release/reset finger FSM
            onPen(ev)
            return true
        }
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> gc.onDown(ev)
            MotionEvent.ACTION_MOVE -> gc.onMove(ev)
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP -> gc.onUp(ev, false)
            MotionEvent.ACTION_CANCEL -> gc.onUp(ev, true)
        }
        return true
    }

    private fun anyStylus(ev: MotionEvent): Boolean {
        for (i in 0 until ev.pointerCount) {
            val t = ev.getToolType(i)
            if (t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER) return true
        }
        return false
    }

    // ── Pen path (preserves the verified pressure/tilt behavior; single tracked stylus contact) ──
    private fun onPen(ev: MotionEvent) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                penId = ev.getPointerId(ev.actionIndex)
                emitPen(ev, ev.actionIndex, InputType.TOUCH_DOWN.value, InputButtons.PRIMARY)
            }
            MotionEvent.ACTION_MOVE -> {
                if (penId < 0) return
                val pi = ev.findPointerIndex(penId); if (pi < 0) return
                emitPen(ev, pi, InputType.TOUCH_MOVE.value, InputButtons.PRIMARY)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (penId < 0) return
                val pi = ev.findPointerIndex(penId)
                if (pi >= 0) emitPen(ev, pi, InputType.TOUCH_UP.value, 0)
                penId = -1
            }
        }
    }

    private fun emitPen(ev: MotionEvent, pi: Int, type: Int, buttons: Int) {
        val r = videoRect(); val left = r[0]; val top = r[1]
        val w = r[2].coerceAtLeast(1f); val h = r[3].coerceAtLeast(1f)
        val tool = if (ev.getToolType(pi) == MotionEvent.TOOL_TYPE_ERASER) InputTool.ERASER.value else InputTool.PEN.value
        val tiltDeg = Math.toDegrees(ev.getAxisValue(MotionEvent.AXIS_TILT, pi).toDouble())
        val orient = ev.getAxisValue(MotionEvent.AXIS_ORIENTATION, pi).toDouble()
        sender.send(InputEvent(
            type = type, tool = tool, buttons = buttons, flags = 0, timestampMs = ev.eventTime,
            x = ((ev.getX(pi) - left) / w).coerceIn(0f, 1f), y = ((ev.getY(pi) - top) / h).coerceIn(0f, 1f),
            pressure = ev.getPressure(pi),
            tiltX = (tiltDeg * Math.sin(orient)).toFloat(), tiltY = (-tiltDeg * Math.cos(orient)).toFloat(),
            pointerId = ev.getPointerId(pi),
        ))
    }
}
