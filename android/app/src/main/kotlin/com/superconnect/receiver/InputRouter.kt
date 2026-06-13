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
 *   • finger        → [GestureController] (trackpad gestures), OR — when a handwriting mode is on —
 *                     the pen-ink path / palm-rejected (see below)
 *   • mouse         → finger path for now (absolute), per the parity analysis.
 *
 * Two independent handwriting toggles (owned by the page, read live through accessors):
 *   • [drawingMode]  (触控笔/绘画模式, HarmonyOS parity): while the stylus is on the glass — or within
 *     [PALM_GRACE_MS] after it — fingers are DROPPED (palm rejection). The stylus inks with pressure.
 *   • [fingerAsPen]  (手指当笔): the finger itself emits PEN ink, so a device with NO stylus can write.
 * Precedence per finger event: palm-reject (drawingMode + pen active) ▸ fingerAsPen ink ▸ gesture FSM.
 *
 * [videoRect] returns the on-screen video rectangle `[left, top, width, height]` in the SAME coordinate
 * space as the touch events fed to [onTouch]. The listener lives on the FULL-SCREEN root, so a finger
 * anywhere is captured; we map it against the video rect — (raw − left)/width → [0,1] — black-bar
 * touches clamped to the nearest edge (harmless).
 */
class InputRouter(
    private val sender: InputSender,
    private val videoRect: () -> FloatArray,        // [left, top, width, height] of the video surface
    private val fingerAsPen: () -> Boolean = { false },
    private val drawingMode: () -> Boolean = { false },
) {
    private var inkId = -1          // single tracked contact for the PEN-ink path (stylus or finger-as-pen)
    private var penDown = false     // a STYLUS is currently on the glass (drives palm rejection)
    private var lastPenMs = 0L      // uptime of the last stylus event (drives the post-lift grace window)

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

    private fun msSincePen(): Long = SystemClock.uptimeMillis() - lastPenMs

    /** Touch entry — the full-screen root's OnTouchListener delegates here. Always consumes (returns true). */
    fun onTouch(ev: MotionEvent): Boolean {
        val r = videoRect(); if (r[2] <= 0f || r[3] <= 0f) return true   // no video laid out yet
        // Real stylus anywhere in the gesture → pen pressure path (also marks pen activity for palm rejection).
        if (anyStylus(ev)) {
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) gc.abortForPen()   // release/reset finger FSM
            onPen(ev)
            return true
        }
        // ── finger ──
        val drawing = drawingMode()
        if (drawing && (penDown || msSincePen() < PALM_GRACE_MS)) return true   // palm rejection (stylus owns ink)
        if (fingerAsPen()) { onFingerPen(ev); return true }                     // finger writes as a pen
        gc.setDrawing(drawing)   // drawing + finger (pen idle) = pointer (no ink); desktop = direct drag
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

    // ── Stylus pen path (verified pressure/tilt; single tracked contact). Marks pen activity. ──
    //    Binds ink to the STYLUS pointer by id and follows it across multi-touch: the stylus may land or
    //    lift as a SECONDARY pointer (POINTER_DOWN/UP) when a palm/finger is co-present. Mirrors harmony's
    //    findPen()-by-penId so a resting palm never strands the pen's down or up.
    private fun onPen(ev: MotionEvent) {
        lastPenMs = SystemClock.uptimeMillis()
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val ai = ev.actionIndex
                val t = ev.getToolType(ai)
                if (t == MotionEvent.TOOL_TYPE_STYLUS || t == MotionEvent.TOOL_TYPE_ERASER) {
                    penDown = true
                    inkId = ev.getPointerId(ai)
                    emitPen(ev, ai, InputType.TOUCH_DOWN.value, InputButtons.PRIMARY)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                if (inkId < 0) return
                val pi = ev.findPointerIndex(inkId); if (pi < 0) return
                emitPen(ev, pi, InputType.TOUCH_MOVE.value, InputButtons.PRIMARY)
            }
            MotionEvent.ACTION_POINTER_UP -> {
                // a contact lifted while others remain — release ink only if it is the stylus contact
                if (inkId >= 0 && ev.getPointerId(ev.actionIndex) == inkId) {
                    penDown = false
                    emitPen(ev, ev.actionIndex, InputType.TOUCH_UP.value, 0)
                    inkId = -1
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                penDown = false
                if (inkId < 0) return
                val pi = ev.findPointerIndex(inkId)
                if (pi >= 0) emitPen(ev, pi, InputType.TOUCH_UP.value, 0)
                inkId = -1
            }
        }
    }

    // ── Finger-as-pen: the first finger inks like a stylus (tool=PEN + pressure). Extra fingers ignored
    //    (single stroke). Does NOT set penDown — it is not a stylus, so it never palm-rejects itself. ──
    private fun onFingerPen(ev: MotionEvent) {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                inkId = ev.getPointerId(ev.actionIndex)
                emitPen(ev, ev.actionIndex, InputType.TOUCH_DOWN.value, InputButtons.PRIMARY)
            }
            MotionEvent.ACTION_MOVE -> {
                if (inkId < 0) return
                val pi = ev.findPointerIndex(inkId); if (pi < 0) return
                emitPen(ev, pi, InputType.TOUCH_MOVE.value, InputButtons.PRIMARY)
            }
            MotionEvent.ACTION_POINTER_UP -> {
                // the inking finger lifted while extra fingers remain — end the single stroke cleanly
                if (inkId >= 0 && ev.getPointerId(ev.actionIndex) == inkId) {
                    emitPen(ev, ev.actionIndex, InputType.TOUCH_UP.value, 0)
                    inkId = -1
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (inkId < 0) return
                val pi = ev.findPointerIndex(inkId)
                if (pi >= 0) emitPen(ev, pi, InputType.TOUCH_UP.value, 0)
                inkId = -1
            }
        }
    }

    /** Emit a PEN-tool ink event. Finger contacts report tool FINGER → still mapped to PEN here (so the
     *  Mac's PenInjector draws with the tablet-pointer subtype + pressure); a finger's tilt axes read 0. */
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

    private companion object {
        const val PALM_GRACE_MS = 600L   // drop fingers this long after the last stylus activity (drawing mode)
    }
}
