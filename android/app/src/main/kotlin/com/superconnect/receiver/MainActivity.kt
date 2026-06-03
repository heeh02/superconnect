package com.superconnect.receiver

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import com.superconnect.protocol.InputButtons
import com.superconnect.protocol.InputEvent
import com.superconnect.protocol.InputTool
import com.superconnect.protocol.InputType

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
        Log.i(TAG, "caps ${caps.screenWidth}x${caps.screenHeight}@${caps.scale} listen 127.0.0.1:8888")
        val t = TcpServerTransport(port = 8888, bindAddress = "127.0.0.1", log = { Log.i(TAG, "[tcp] $it") })
        inputSender = InputSender(t)
        surfaceView.setOnTouchListener { v, ev -> handleTouch(v, ev) }
        val session = Session(t, caps, DeviceInfo.deviceName(), DeviceInfo.peerId(this), log = { Log.i(TAG, "[sess] $it") })
        session.onStatus = { s -> runOnUiThread { setStatus(s) } }
        session.onVideoConfig = { w, h, codec, _ -> onVideoConfig(w, h, codec) }
        session.onVideo = { payload, kf -> onVideo(payload, kf) }
        session.attach()
        t.start()
        transport = t

        setStatus("等待 Mac 连接…\n本机 ${caps.screenWidth}×${caps.screenHeight} @${caps.scale}x\n" +
            "（有线：adb forward tcp:8888 tcp:8888）")
    }

    private var frameCount = 0

    // --- input capture (v0.2: single-finger direct manipulation + pen) ---
    private var inputSender: InputSender? = null
    private var trackedPointer = -1   // the one finger/pen we follow (extra fingers ignored for now)
    private var touchCount = 0

    /** Map a MotionEvent to INPUT events for the Mac. We track ONE pointer (the first down) so a stray
     *  second finger can't fight the cursor; 2-finger gestures (scroll/right-click) are the next step. */
    private fun handleTouch(v: View, ev: MotionEvent): Boolean {
        val w = v.width.toFloat().coerceAtLeast(1f)
        val h = v.height.toFloat().coerceAtLeast(1f)
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                trackedPointer = ev.getPointerId(0)
                sendPointer(InputType.TOUCH_DOWN, ev, 0, w, h)
            }
            MotionEvent.ACTION_MOVE -> {
                if (trackedPointer >= 0) {
                    val idx = ev.findPointerIndex(trackedPointer)
                    if (idx >= 0) sendPointer(InputType.TOUCH_MOVE, ev, idx, w, h)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (trackedPointer >= 0) {
                    val idx = ev.findPointerIndex(trackedPointer)
                    if (idx >= 0) sendPointer(InputType.TOUCH_UP, ev, idx, w, h)
                    trackedPointer = -1
                }
            }
            // ACTION_POINTER_DOWN / ACTION_POINTER_UP: ignore extra fingers (single-finger v0.2 basic)
        }
        return true
    }

    private fun sendPointer(type: InputType, ev: MotionEvent, i: Int, w: Float, h: Float) {
        val tool = when (ev.getToolType(i)) {
            MotionEvent.TOOL_TYPE_STYLUS -> InputTool.PEN
            MotionEvent.TOOL_TYPE_ERASER -> InputTool.ERASER
            MotionEvent.TOOL_TYPE_MOUSE -> InputTool.MOUSE
            else -> InputTool.FINGER
        }
        val x = (ev.getX(i) / w).coerceIn(0f, 1f)
        val y = (ev.getY(i) / h).coerceIn(0f, 1f)
        val tiltDeg = Math.toDegrees(ev.getAxisValue(MotionEvent.AXIS_TILT, i).toDouble())
        val orient = ev.getAxisValue(MotionEvent.AXIS_ORIENTATION, i).toDouble()
        // primary (left) while down/move; 0 on release — the Mac executes press/drag/release directly.
        val buttons = if (type == InputType.TOUCH_UP) 0 else InputButtons.PRIMARY
        if (++touchCount <= 2 || type == InputType.TOUCH_DOWN)
            Log.i(TAG, "touch $type tool=${tool.name} x=${"%.3f".format(x)} y=${"%.3f".format(y)}")
        inputSender?.send(InputEvent(
            type = type.value, tool = tool.value, buttons = buttons, flags = 0,
            timestampMs = ev.eventTime,
            x = x, y = y, pressure = ev.getPressure(i),
            tiltX = (tiltDeg * Math.sin(orient)).toFloat(),
            tiltY = (-tiltDeg * Math.cos(orient)).toFloat(),
            scrollX = 0f, scrollY = 0f, keyCode = 0, pointerId = ev.getPointerId(i),
        ))
    }

    private fun onVideoConfig(w: Int, h: Int, codec: String) {
        Log.i(TAG, "video_config ${w}x${h} $codec (mime=${VideoDecoder.mimeFor(codec)}) surface=${surface != null}")
        synchronized(lifecycleLock) {
            cfgW = w; cfgH = h; cfgMime = VideoDecoder.mimeFor(codec); gotKeyframe = false
            maybeCreateDecoder()
        }
        runOnUiThread { setStatus("已连接 · ${w}×${h} ${codec.uppercase()} · 等待画面…") }
    }

    private fun onVideo(payload: ByteArray, isKeyframe: Boolean) {
        synchronized(lifecycleLock) {
            frameCount++
            if (frameCount <= 3 || frameCount % 120 == 0)
                Log.i(TAG, "video #$frameCount kf=$isKeyframe size=${payload.size} gotKf=$gotKeyframe dec=${decoder != null}")
            if (!gotKeyframe) {
                if (!isKeyframe) return            // wait for the keyframe (carries SPS/PPS)
                gotKeyframe = true
                Log.i(TAG, "first keyframe (#$frameCount) → submitting to decoder")
                runOnUiThread { hideStatus() }
            }
            decoder?.submit(payload)
        }
    }

    /** Create the decoder only when BOTH the surface and a video_config are known; recreate on change. */
    private fun maybeCreateDecoder() {
        val s = surface
        if (s == null) { Log.i(TAG, "decoder deferred: no surface yet"); return }
        if (cfgW <= 0 || cfgH <= 0) { Log.i(TAG, "decoder deferred: no video_config"); return }
        decoder?.stop()
        Log.i(TAG, "creating decoder $cfgMime ${cfgW}x$cfgH")
        decoder = try {
            VideoDecoder(cfgMime, cfgW, cfgH, s, log = { Log.i(TAG, "[dec] $it") }).also { it.start() }
        } catch (e: Exception) {
            Log.e(TAG, "decoder create FAILED", e); null
        }
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

    companion object { private const val TAG = "SCRecv" }
}
