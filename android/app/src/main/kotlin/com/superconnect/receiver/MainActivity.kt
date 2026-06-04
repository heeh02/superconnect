package com.superconnect.receiver

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView
import kotlin.math.min

/**
 * Generic Android receiver. Connection + handshake (TcpServerTransport + Session), HARDWARE VIDEO
 * DECODE (VIDEO frames → MediaCodec → SurfaceView), and INPUT capture: touch/pen → InputRouter +
 * GestureController (tap/drag/hover, 2-finger right-click + scroll, pinch), physical + soft keyboard →
 * KeyboardHandler (+ AndroidKeyMap / ImeCatcher). Capture-only: all disambiguation lives in the
 * decoupled input handlers, mirroring the HarmonyOS receiver. Free/generic (→ dev).
 *
 * Decoder lifecycle: created once BOTH the SurfaceView surface and a `video_config` are known, and
 * recreated on a new config (resolution/codec change). Frames before the first keyframe are dropped
 * (MediaCodec needs the keyframe's inline SPS/PPS first).
 */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private var transport: TcpServerTransport? = null
    private var wireless: WirelessService? = null
    private var pairingDialog: android.app.AlertDialog? = null   // live TOFU prompt (dismissed on settle/teardown)
    private lateinit var statusView: TextView
    private lateinit var surfaceView: SurfaceView

    private val lifecycleLock = Any()
    private var surface: Surface? = null
    private var decoder: VideoDecoder? = null
    private var cfgW = 0
    private var cfgH = 0
    private var cfgMime = "video/avc"
    private var gotKeyframe = false

    private lateinit var root: FrameLayout
    private var vW = 0   // last video_config width/height (for aspect-correct sizing)
    private var vH = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        actionBar?.hide()   // no "Superconnect" title bar — full-bleed video
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()

        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        // SurfaceView is centered and resized to the video's aspect ratio (no distortion, minimal bars).
        surfaceView = SurfaceView(this).also { it.holder.addCallback(this) }
        root.addView(surfaceView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT, Gravity.CENTER))
        root.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitSurface() }
        statusView = TextView(this).apply {
            textSize = 15f
            gravity = Gravity.CENTER
            setTextColor(0xFFE5E5E5.toInt())
            setBackgroundColor(Color.BLACK)
            setPadding(56, 56, 56, 56)
            setLineSpacing(0f, 1.3f)
        }
        root.addView(statusView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        setContentView(root)

        val caps = DeviceInfo.caps(this)
        // Wireless (Wi-Fi LAN): bind 0.0.0.0 so ONE listener serves BOTH the wired adb-forwarded loopback
        // client AND LAN clients; advertise over mDNS/NSD so the Mac auto-discovers us (same _superconnect.
        // _tcp the Mac already browses for HarmonyOS); TOFU-pair unknown LAN Macs (loopback/wired exempt).
        // Free 1-pad-1-mac, wired + wireless.
        val wl = WirelessService(this) { Log.i(TAG, "[wl] $it") }
        wl.onPairingRequest = { _, name, promptId -> runOnUiThread { showPairingDialog(name, promptId) } }
        wl.onPairingDismiss = { runOnUiThread { pairingDialog?.dismiss(); pairingDialog = null } }
        wireless = wl
        val bind = wl.bindAddress()
        Log.i(TAG, "caps ${caps.screenWidth}x${caps.screenHeight}@${caps.scale} listen $bind:8888")
        val t = TcpServerTransport(port = 8888, bindAddress = bind, log = { Log.i(TAG, "[tcp] $it") })
        t.onClientGone = { ownerId -> wl.cancelPairing(ownerId) }   // a disconnect frees any in-flight pairing prompt
        // Advertise over mDNS only AFTER the socket is bound (fired on the server thread) — never before
        // accept() is ready, and never at all if the bind fails. Carries the actually-bound port.
        t.onListening = { _, port -> wl.startAdvertise(DeviceInfo.deviceName(), port) }
        // Input: one InputSender seam → InputRouter (finger gesture FSM + pen) + KeyboardHandler
        // (physical keys + IME text). MainActivity is capture-only; all disambiguation lives in the
        // decoupled handlers (mirrors HarmonyOS InputRouter/GestureController/KeyboardHandler).
        val sender = InputSender(t)
        val kb = KeyboardHandler(sender); keyboard = kb
        // Touch listener on the FULL-SCREEN root (not the letterboxed SurfaceView) so a finger anywhere is
        // captured; the router maps it against the SurfaceView's live rect within root → correct Mac coords
        // even with black bars. (surfaceView.{left,top,width,height} are already in root's coordinate space.)
        val rt = InputRouter(sender, {
            floatArrayOf(surfaceView.left.toFloat(), surfaceView.top.toFloat(),
                surfaceView.width.toFloat(), surfaceView.height.toFloat())
        }); router = rt
        root.setOnTouchListener { _, ev -> rt.onTouch(ev) }
        // Hidden soft-keyboard capture surface (committed text / CJK → Mac) + a small ⌨ toggle to summon it.
        val ime = ImeCatcher(this, onText = { kb.commitText(it) }, onBackspace = { kb.backspace(it) },
            onKey = { kb.onKeyEvent(it) })
        imeCatcher = ime
        root.addView(ime, FrameLayout.LayoutParams(1, 1))
        addKeyboardToggle()
        val session = Session(t, caps, DeviceInfo.deviceName(), DeviceInfo.peerId(this), log = { Log.i(TAG, "[sess] $it") })
        session.pairingGate = { pid, nm, local, ownerId, onResult -> wl.evaluate(pid, nm, local, ownerId, onResult) }
        session.onStatus = { s -> runOnUiThread { setStatus(s) } }
        session.onVideoConfig = { w, h, codec, _ -> onVideoConfig(w, h, codec) }
        session.onVideo = { payload, kf -> onVideo(payload, kf) }
        session.attach()
        t.start()                  // binds, then fires onListening → wl.startAdvertise (mDNS) on success
        transport = t

        val ip = wl.wifiIpv4()
        val wlLine = if (ip.isEmpty()) "无线：开（未连 Wi‑Fi）" else "无线：$ip:8888"
        setStatus("等待 Mac 连接…\n本机 ${caps.screenWidth}×${caps.screenHeight} @${caps.scale}x\n$wlLine\n有线：adb forward tcp:8888 tcp:8888")
    }

    private var frameCount = 0

    // --- input: router (finger gesture FSM + pen) + physical/soft keyboard, mirroring HarmonyOS ---
    private var router: InputRouter? = null
    private var keyboard: KeyboardHandler? = null
    private var imeCatcher: ImeCatcher? = null
    private var kbShown = false

    /** Physical keys (hardware keyboard) → Mac, captured before any focused view. Unmapped keys
     *  (volume/back/home) fall through to Android. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        keyboard?.onKeyEvent(event) == true || super.dispatchKeyEvent(event)

    /** Small ⌨ button to summon the soft keyboard (there's no visible field). The hidden ImeCatcher
     *  forwards committed text / CJK to the Mac. A fuller control surface lands with the floating ball. */
    private fun addKeyboardToggle() {
        val btn = Button(this).apply {
            text = "⌨"
            alpha = 0.55f
            setOnClickListener { toggleKeyboard() }
        }
        root.addView(btn, FrameLayout.LayoutParams(150, 150, Gravity.BOTTOM or Gravity.END).also {
            it.setMargins(0, 0, 40, 40)
        })
    }

    private fun toggleKeyboard() {
        val ime = imeCatcher ?: return
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        if (kbShown) {
            imm.hideSoftInputFromWindow(ime.windowToken, 0)
            ime.clearFocus(); kbShown = false
        } else {
            ime.requestFocus()
            imm.showSoftInput(ime, InputMethodManager.SHOW_IMPLICIT); kbShown = true
        }
    }

    private fun onVideoConfig(w: Int, h: Int, codec: String) {
        Log.i(TAG, "video_config ${w}x${h} $codec (mime=${VideoDecoder.mimeFor(codec)}) surface=${surface != null}")
        synchronized(lifecycleLock) {
            cfgW = w; cfgH = h; cfgMime = VideoDecoder.mimeFor(codec); gotKeyframe = false
            maybeCreateDecoder()
        }
        runOnUiThread { vW = w; vH = h; fitSurface(); setStatus("已连接 · ${w}×${h} ${codec.uppercase()} · 等待画面…") }
    }

    /** Size the SurfaceView to the video's aspect ratio, centered — undistorted, minimal black bars. */
    private fun fitSurface() {
        val cw = root.width; val ch = root.height
        if (cw <= 0 || ch <= 0 || vW <= 0 || vH <= 0) return
        val scale = min(cw.toFloat() / vW, ch.toFloat() / vH)
        val tw = (vW * scale).toInt(); val th = (vH * scale).toInt()
        val lp = surfaceView.layoutParams as FrameLayout.LayoutParams
        if (lp.width != tw || lp.height != th) {
            lp.width = tw; lp.height = th; lp.gravity = Gravity.CENTER
            surfaceView.layoutParams = lp
        }
    }

    private fun hideSystemUi() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemUi()   // re-assert immersive after dialogs / swipe-reveal
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

    /** TOFU prompt for an unknown LAN Mac (wireless). 允许 → trust+proceed, 拒绝 → reject. Runs on the UI
     *  thread; the tap echoes `promptId` back via WirelessService.respondPairing so a stale tap (its prompt
     *  already timed out / was cancelled by a disconnect) can't settle a different prompt. The dialog handle
     *  is kept so onPairingDismiss/onDestroy can tear it down deterministically (no WindowLeaked). */
    private fun showPairingDialog(deviceName: String, promptId: Int) {
        // A finishing/destroyed Activity can't host a dialog (BadTokenException) — reject so the gate still settles.
        if (isFinishing || isDestroyed) { wireless?.respondPairing(promptId, false); return }
        pairingDialog?.dismiss()   // never stack two prompts
        var decided = false
        pairingDialog = android.app.AlertDialog.Builder(this)
            .setTitle("允许连接？")
            .setMessage("“$deviceName” 想通过无线网络连接到本机投屏。\n允许后将记住该设备。")
            .setCancelable(false)
            .setPositiveButton("允许") { _, _ -> if (!decided) { decided = true; wireless?.respondPairing(promptId, true) } }
            .setNegativeButton("拒绝") { _, _ -> if (!decided) { decided = true; wireless?.respondPairing(promptId, false) } }
            .show()
    }

    override fun onDestroy() {
        pairingDialog?.dismiss(); pairingDialog = null
        transport?.stop()         // close sockets first → read loop ends (fires onClientGone → cancelPairing)
        wireless?.dispose()        // then drop any in-flight prompt + stop mDNS advertising + release the timer thread
        synchronized(lifecycleLock) { decoder?.stop(); decoder = null }
        super.onDestroy()
    }

    companion object { private const val TAG = "SCRecv" }
}
