package com.superconnect.receiver

import android.os.SystemClock
import android.view.MotionEvent
import kotlin.math.cos
import kotlin.math.sin

private const val PALM_GRACE_MS = 600L

/** Routes native touch through the established gesture policy and Rust's canonical INPUT encoder. */
internal class PointerInputController(
    private val send: (ByteArray) -> Unit,
    private val videoRect: () -> FloatArray,
) {
    var enabled = true
        set(value) { if (!value) cancel(); field = value }
    var fingerAsPen = false
        set(value) { if (field != value) cancel(); field = value }
    var drawingMode = false
        set(value) { if (field != value) cancel(); field = value }

    private var contactId = -1
    private var contactTool = FossInputTool.FINGER.value
    private var x = 0f
    private var y = 0f
    private var penDown = false
    private var lastStylusMs = -PALM_GRACE_MS
    private val gesture = GestureController(::emitGesture)

    fun onTouch(event: MotionEvent): Boolean {
        if (!enabled) return false
        val rect = videoRect()
        if (rect.size < 4 || rect[2] <= 0f || rect[3] <= 0f) return true
        val stylusPresent = hasStylus(event)
        when (fossTouchRoute(
            stylusPresent = stylusPresent,
            cancelledPen = event.actionMasked == MotionEvent.ACTION_CANCEL && penDown,
            drawingMode = drawingMode,
            fingerAsPen = fingerAsPen,
            penDown = penDown,
            lastStylusMs = lastStylusMs,
            nowMs = SystemClock.uptimeMillis(),
        )) {
        FossTouchRoute.Pen -> {
            val action = event.actionMasked
            if (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_POINTER_DOWN) {
                val tool = event.getToolType(event.actionIndex)
                if (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER) {
                    gesture.abortForPen()
                    if (contactId >= 0 && !penDown) {
                        emitContactRelease()
                        contactId = -1
                    }
                }
            }
            onPen(event, finger = !stylusPresent && !penDown)
            return true
        }
        FossTouchRoute.RejectPalm -> return true
        FossTouchRoute.Gesture -> Unit
        }
        gesture.setDrawing(drawingMode)
        val facts = AndroidFossTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> gesture.onDown(facts)
            MotionEvent.ACTION_MOVE -> gesture.onMove(facts)
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> gesture.onUp(facts, false)
            MotionEvent.ACTION_CANCEL -> gesture.onUp(facts, true)
        }
        return true
    }

    fun onHover(event: MotionEvent): Boolean {
        if (!enabled || contactId >= 0 || event.getToolType(0) != MotionEvent.TOOL_TYPE_STYLUS) {
            return false
        }
        emitPointer(FossInputType.HOVER.value, FossInputTool.PEN.value, 0, event, 0)
        return true
    }

    private fun hasStylus(event: MotionEvent): Boolean =
        (0 until event.pointerCount).any { index ->
            val tool = event.getToolType(index)
            tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER
        }

    private fun onPen(event: MotionEvent, finger: Boolean) {
        if (!finger) lastStylusMs = SystemClock.uptimeMillis()
        val action = event.actionMasked
        when (action) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val index = event.actionIndex
                val tool = event.getToolType(index)
                if (contactId < 0 && (finger && action == MotionEvent.ACTION_DOWN ||
                    !finger && (tool == MotionEvent.TOOL_TYPE_STYLUS ||
                        tool == MotionEvent.TOOL_TYPE_ERASER))) {
                    contactId = event.getPointerId(index)
                    contactTool = if (tool == MotionEvent.TOOL_TYPE_ERASER) {
                        FossInputTool.ERASER.value
                    } else FossInputTool.PEN.value
                    if (!finger) penDown = true
                    emitPointer(FossInputType.TOUCH_DOWN.value, contactTool, 1, event, index)
                }
            }
            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(contactId)
                if (index >= 0) emitPointer(FossInputType.TOUCH_MOVE.value, contactTool, 1, event, index)
            }
            MotionEvent.ACTION_POINTER_UP, MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val index = event.findPointerIndex(contactId)
                val lifting = action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL ||
                    event.getPointerId(event.actionIndex) == contactId
                if (contactId >= 0 && lifting) {
                    if (index >= 0) {
                        emitPointer(FossInputType.TOUCH_UP.value, contactTool, 0, event, index)
                    } else {
                        emitContactRelease()
                    }
                    contactId = -1
                    penDown = false
                }
            }
        }
    }

    private fun emitGesture(value: Emit) {
        val rect = videoRect()
        if (rect.size < 4 || rect[2] <= 0f || rect[3] <= 0f) return
        val scroll = value.type == FossInputType.SCROLL.value
        val nx = if (scroll) 0f else ((value.x - rect[0]) / rect[2]).coerceIn(0f, 1f)
        val ny = if (scroll) 0f else ((value.y - rect[1]) / rect[3]).coerceIn(0f, 1f)
        PointerInputNative.encodeExtended(value.type, value.tool, value.buttons,
            SystemClock.uptimeMillis(), nx, ny, 0f, 0f, 0f,
            value.scrollX, value.scrollY, 0)?.let(send)
    }

    private fun emitPointer(type: Int, tool: Int, buttons: Int, event: MotionEvent, index: Int) {
        val rect = videoRect()
        if (rect.size < 4 || rect[2] <= 0f || rect[3] <= 0f) return
        x = ((event.getX(index) - rect[0]) / rect[2]).coerceIn(0f, 1f)
        y = ((event.getY(index) - rect[1]) / rect[3]).coerceIn(0f, 1f)
        val tilt = event.getAxisValue(MotionEvent.AXIS_TILT, index) * 180f / Math.PI.toFloat()
        val orientation = event.getOrientation(index)
        val pressure = if (type == FossInputType.TOUCH_UP.value) 0f
            else event.getPressure(index).coerceIn(0f, 1f)
        PointerInputNative.encodeExtended(type, tool, buttons, event.eventTime, x, y,
            pressure, tilt * sin(orientation),
            -tilt * cos(orientation), 0f, 0f, event.getPointerId(index))?.let(send)
    }

    fun cancel() {
        gesture.abortForPen()
        if (contactId >= 0) {
            emitContactRelease()
            contactId = -1
        }
        penDown = false
    }

    private fun emitContactRelease() {
        PointerInputNative.encodeExtended(FossInputType.TOUCH_UP.value, contactTool, 0,
            SystemClock.uptimeMillis(), x, y, 0f, 0f, 0f, 0f, 0f, contactId)?.let(send)
    }
}

internal fun fossRejectPalm(penDown: Boolean, lastStylusMs: Long, nowMs: Long): Boolean =
    penDown || nowMs >= lastStylusMs && nowMs - lastStylusMs < PALM_GRACE_MS

internal enum class FossTouchRoute { Pen, RejectPalm, Gesture }

internal fun fossTouchRoute(
    stylusPresent: Boolean,
    cancelledPen: Boolean,
    drawingMode: Boolean,
    fingerAsPen: Boolean,
    penDown: Boolean,
    lastStylusMs: Long,
    nowMs: Long,
): FossTouchRoute = when {
    stylusPresent || cancelledPen -> FossTouchRoute.Pen
    drawingMode && fossRejectPalm(penDown, lastStylusMs, nowMs) -> FossTouchRoute.RejectPalm
    fingerAsPen -> FossTouchRoute.Pen
    else -> FossTouchRoute.Gesture
}
