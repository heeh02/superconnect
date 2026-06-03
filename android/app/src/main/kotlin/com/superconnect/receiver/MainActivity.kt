package com.superconnect.receiver

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.TextView
import com.superconnect.protocol.FrameCodec

/**
 * Placeholder shell for the generic Android receiver. The streaming pipeline — a TCP server (mirroring
 * HarmonyOS TcpServerTransport), MediaCodec H.264/HEVC decode → SurfaceView, and MotionEvent/KeyEvent
 * capture → INPUT frames — lands in the next increments, all on `dev` (free, generic; brand-specific
 * niceties layer on later). Today the app links the conformance-locked :protocol module.
 *
 * Uses bare `Activity` (no AppCompat) to keep the first scaffold dependency-free and easy to build.
 */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val tv = TextView(this).apply {
            text = "Superconnect 接收端（通用安卓版）\n\n线协议已就位（帧头 ${FrameCodec.HEADER_SIZE} 字节）。\n投屏管线开发中：TCP 服务 + MediaCodec 解码 + 触控/笔输入。"
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }
        setContentView(tv)
    }
}
