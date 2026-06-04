package com.superconnect.receiver

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.hypot

/**
 * In-app draggable control — Kotlin/View port of harmony `components/FloatingBall.ets`. A small circle
 * the user can reposition; it never needs an overlay/system-window permission because the receiver owns
 * the whole screen (it's just the last child of the root FrameLayout).
 *
 *   • Tap        → [onTap]        (toggle 手指当笔 / finger-as-pen)
 *   • Long-press → [onLongPress]  (open the control panel)
 *   • Drag       → reposition, then dock to the nearest left/right edge
 *
 * Tap-vs-drag is by movement slop; long-press by the standard timeout, cancelled the moment a drag
 * starts. [active] tints the ball + swaps the glyph (✎ when finger-as-pen is on, ↖ otherwise).
 */
class FloatingBall(
    context: Context,
    private val onTap: () -> Unit,
    private val onLongPress: () -> Unit,
) : View(context) {

    private val dp = resources.displayMetrics.density
    private val sizePx = (56 * dp).toInt()
    private val marginPx = 12 * dp

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textAlign = Paint.Align.CENTER; textSize = 24 * dp
    }

    var active: Boolean = false
        set(v) { field = v; invalidate() }

    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val longPressMs = ViewConfiguration.getLongPressTimeout().toLong()
    private val handler = Handler(Looper.getMainLooper())
    private var downRawX = 0f; private var downRawY = 0f
    private var startX = 0f; private var startY = 0f
    private var dragging = false
    private var longPressFired = false
    private val longPressRunnable = Runnable {
        if (!dragging) { longPressFired = true; onLongPress() }
    }

    init { alpha = 0.6f }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(sizePx, sizePx)

    override fun onDraw(canvas: Canvas) {
        val r = sizePx / 2f
        fill.color = if (active) 0xFF2E7DF6.toInt() else 0xCC3A3A3C.toInt()  // accent when writing, else dim gray
        canvas.drawCircle(r, r, r, fill)
        val fm = glyph.fontMetrics
        canvas.drawText(if (active) "✎" else "↖", r, r - (fm.ascent + fm.descent) / 2f, glyph)
    }

    override fun performClick(): Boolean { super.performClick(); return true }

    @Suppress("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downRawX = event.rawX; downRawY = event.rawY
                startX = x; startY = y
                dragging = false; longPressFired = false
                alpha = 0.95f
                handler.postDelayed(longPressRunnable, longPressMs)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - downRawX; val dy = event.rawY - downRawY
                if (!dragging && hypot(dx, dy) > slop) {
                    dragging = true
                    handler.removeCallbacks(longPressRunnable)
                }
                if (dragging) {
                    val p = parent as? View ?: return true
                    x = (startX + dx).coerceIn(0f, (p.width - width).toFloat())
                    y = (startY + dy).coerceIn(0f, (p.height - height).toFloat())
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                handler.removeCallbacks(longPressRunnable)
                alpha = 0.6f
                if (dragging) snapToEdge()
                else if (!longPressFired && event.actionMasked == MotionEvent.ACTION_UP) { performClick(); onTap() }
                dragging = false
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun snapToEdge() {
        val p = parent as? View ?: return
        val targetX = if (x + width / 2f < p.width / 2f) marginPx else p.width - width - marginPx
        val targetY = y.coerceIn(marginPx, p.height - height - marginPx)
        animate().x(targetX).y(targetY).setDuration(200).start()
    }
}
