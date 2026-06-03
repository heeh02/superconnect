package com.superconnect.receiver

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView

/**
 * Generic Android receiver. This increment brings up the CONNECTION: a TCP server + hello/hello_ack
 * handshake, so the Mac host can dial in (wired via `adb forward` 127.0.0.1:8888) and learn the
 * tablet's screen caps. The next increments add MediaCodec H.264/HEVC decode → SurfaceView and input
 * capture. All free/generic (→ dev); brand-specific tweaks and paid features layer on later.
 */
class MainActivity : Activity() {
    private var transport: TcpServerTransport? = null
    private lateinit var statusView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        statusView = TextView(this).apply {
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }
        setContentView(statusView)

        val caps = DeviceInfo.caps(this)
        val t = TcpServerTransport(port = 8888, bindAddress = "127.0.0.1")
        val session = Session(t, caps, DeviceInfo.deviceName(), DeviceInfo.peerId(this))
        session.onStatus = { s -> runOnUiThread { setStatus(s) } }
        session.onVideoConfig = { w, h, codec, _ ->
            runOnUiThread { setStatus("已连接 · 收到视频配置 ${w}×${h} ${codec.uppercase()}（解码器开发中）") }
        }
        session.onVideo = { _, _ -> /* MediaCodec decode → SurfaceView: next increment */ }
        session.attach()
        t.start()
        transport = t

        setStatus("等待 Mac 连接…\n本机 ${caps.screenWidth}×${caps.screenHeight} @${caps.scale}x\n" +
            "（有线：adb forward tcp:8888 tcp:8888）")
    }

    private fun setStatus(s: String) {
        statusView.text = "Superconnect 接收端（通用安卓版）\n\n$s"
    }

    override fun onDestroy() {
        transport?.stop()
        super.onDestroy()
    }
}
