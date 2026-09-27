package com.superconnect.receiver

import android.view.MotionEvent

/** Adapts Android's actual callback facts to the gesture policy exercised by host tests. */
internal class AndroidFossTouchEvent(private val event: MotionEvent) : FossTouchEvent {
    override val pointerCount get() = event.pointerCount
    override val actionIndex get() = event.actionIndex
    override val actionMasked get() = event.actionMasked
    override val eventTime get() = event.eventTime
    override val historySize get() = event.historySize
    override fun getPointerId(index: Int) = event.getPointerId(index)
    override fun findPointerIndex(id: Int) = event.findPointerIndex(id)
    override fun getX(index: Int) = event.getX(index)
    override fun getY(index: Int) = event.getY(index)
    override fun getHistoricalX(index: Int, history: Int) = event.getHistoricalX(index, history)
    override fun getHistoricalY(index: Int, history: Int) = event.getHistoricalY(index, history)
}
