package com.superconnect.receiver

import android.os.SystemClock
import android.view.MotionEvent
import kotlin.math.cos
import kotlin.math.sin

/** One pointer gesture, mapped to the same aspect-correct rectangle used to display the video. */
internal class PointerInputController(
    private val send: (ByteArray) -> Unit,
    private val videoRect: () -> FloatArray,
) {
    var enabled = true
        set(value) { if (!value) cancel(); field = value }
    private var pointer = -1
    private var tool = 0
    private var x = 0f
    private var y = 0f

    fun onTouch(event: MotionEvent): Boolean {
        if (!enabled) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val index = event.actionIndex
                val eventTool = event.getToolType(index)
                if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN &&
                    eventTool != MotionEvent.TOOL_TYPE_STYLUS && eventTool != MotionEvent.TOOL_TYPE_ERASER) return true
                cancel()
                pointer = event.getPointerId(index)
                tool = when (eventTool) {
                    MotionEvent.TOOL_TYPE_STYLUS -> 1
                    MotionEvent.TOOL_TYPE_ERASER -> 2
                    else -> 0
                }
                emit(0, event, index, 1)
            }
            MotionEvent.ACTION_MOVE -> {
                val index = event.findPointerIndex(pointer)
                if (index >= 0) emit(1, event, index, 1)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val index = event.actionIndex
                if (event.getPointerId(index) == pointer) {
                    emit(2, event, index, 0)
                    pointer = -1
                }
            }
            MotionEvent.ACTION_CANCEL -> cancel()
        }
        return true
    }

    fun onHover(event: MotionEvent): Boolean {
        if (!enabled || pointer >= 0 || event.getToolType(0) != MotionEvent.TOOL_TYPE_STYLUS) return false
        tool = 1
        emit(3, event, 0, 0)
        return true
    }

    private fun emit(type: Int, event: MotionEvent, index: Int, buttons: Int) {
        val rect = videoRect()
        if (rect[2] <= 0 || rect[3] <= 0) return
        x = ((event.getX(index) - rect[0]) / rect[2]).coerceIn(0f, 1f)
        y = ((event.getY(index) - rect[1]) / rect[3]).coerceIn(0f, 1f)
        val tilt = event.getAxisValue(MotionEvent.AXIS_TILT, index) * 180f / Math.PI.toFloat()
        val orientation = event.getOrientation(index)
        PointerInputNative.encode(type, tool, buttons, event.eventTime, x, y,
            event.getPressure(index).coerceIn(0f, 1f), tilt * sin(orientation), -tilt * cos(orientation))?.let(send)
    }

    fun cancel() {
        if (pointer < 0) return
        PointerInputNative.encode(2, tool, 0, SystemClock.uptimeMillis(), x, y, 0f, 0f, 0f)?.let(send)
        pointer = -1
    }
}
