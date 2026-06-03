package com.superconnect.receiver

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView

/**
 * Generic Android receiver. Connection + handshake (TcpServerTransport + Session) and now HARDWARE
 * VIDEO DECODE: VIDEO frames → MediaCodec → SurfaceView, so the Mac's screen actually renders. Free/
 * generic (→ dev). Next: input capture (MotionEvent/KeyEvent → INPUT) + the wireless path.
 *
 * Decoder lifecycle: created once BOTH the SurfaceView surface and a `video_config` are known, and
 * recreated on a new config (resolution/codec change). Frames before the first keyframe are dropped
 * (MediaCodec needs the keyframe's inline SPS/PPS first).
 */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private var transport: TcpServerTransport? = null
    private lateinit var statusView: TextView
    private lateinit var surfaceView: SurfaceView

    private val lifecycleLock = Any()
    private var surface: Surface? = null
    private var decoder: VideoDecoder? = null
    private var cfgW = 0
    private var cfgH = 0
    private var cfgMime = "video/avc"
    private var gotKeyframe = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val root = FrameLayout(this)
        surfaceView = SurfaceView(this).also { it.holder.addCallback(this) }
        root.addView(surfaceView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        statusView = TextView(this).apply {
            textSize = 16f
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            setBackgroundColor(0xCC000000.toInt())
            setPadding(48, 48, 48, 48)
        }
        root.addView(statusView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        setContentView(root)

        val caps = DeviceInfo.caps(this)
        val t = TcpServerTransport(port = 8888, bindAddress = "127.0.0.1")
        val session = Session(t, caps, DeviceInfo.deviceName(), DeviceInfo.peerId(this))
        session.onStatus = { s -> runOnUiThread { setStatus(s) } }
        session.onVideoConfig = { w, h, codec, _ -> onVideoConfig(w, h, codec) }
        session.onVideo = { payload, kf -> onVideo(payload, kf) }
        session.attach()
        t.start()
        transport = t

        setStatus("等待 Mac 连接…\n本机 ${caps.screenWidth}×${caps.screenHeight} @${caps.scale}x\n" +
            "（有线：adb forward tcp:8888 tcp:8888）")
    }

    private fun onVideoConfig(w: Int, h: Int, codec: String) {
        synchronized(lifecycleLock) {
            cfgW = w; cfgH = h; cfgMime = VideoDecoder.mimeFor(codec); gotKeyframe = false
            maybeCreateDecoder()
        }
        runOnUiThread { setStatus("已连接 · ${w}×${h} ${codec.uppercase()} · 等待画面…") }
    }

    private fun onVideo(payload: ByteArray, isKeyframe: Boolean) {
        synchronized(lifecycleLock) {
            if (!gotKeyframe) {
                if (!isKeyframe) return            // wait for the keyframe (carries SPS/PPS)
                gotKeyframe = true
                runOnUiThread { hideStatus() }
            }
            decoder?.submit(payload)
        }
    }

    /** Create the decoder only when BOTH the surface and a video_config are known; recreate on change. */
    private fun maybeCreateDecoder() {
        val s = surface ?: return
        if (cfgW <= 0 || cfgH <= 0) return
        decoder?.stop()
        decoder = VideoDecoder(cfgMime, cfgW, cfgH, s).also { it.start() }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        synchronized(lifecycleLock) { surface = holder.surface; maybeCreateDecoder() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        synchronized(lifecycleLock) { decoder?.stop(); decoder = null; surface = null }
    }

    private fun setStatus(s: String) {
        statusView.visibility = View.VISIBLE
        statusView.text = "Superconnect 接收端\n\n$s"
    }

    private fun hideStatus() { statusView.visibility = View.GONE }

    override fun onDestroy() {
        transport?.stop()
        synchronized(lifecycleLock) { decoder?.stop(); decoder = null }
        super.onDestroy()
    }
}
