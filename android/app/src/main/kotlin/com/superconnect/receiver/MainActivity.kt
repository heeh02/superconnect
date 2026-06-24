package com.superconnect.receiver

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.TextUtils
import android.text.style.ForegroundColorSpan
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
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
        val rt = InputRouter(sender,
            { floatArrayOf(surfaceView.left.toFloat(), surfaceView.top.toFloat(),
                surfaceView.width.toFloat(), surfaceView.height.toFloat()) },
            fingerAsPen = { fingerAsPen },
            drawingMode = { drawingMode })
        router = rt
        // "暂停输入" swallows screen touches so the user can operate the tablet itself; the floating ball
        // and control panel are separate views on top and keep working.
        root.setOnTouchListener { _, ev -> if (inputDisabled) true else rt.onTouch(ev) }
        // Hidden soft-keyboard capture surface (committed text / CJK → Mac); summoned from the control panel.
        val ime = ImeCatcher(this, onText = { kb.commitText(it) }, onBackspace = { kb.backspace(it) },
            onKey = { kb.onKeyEvent(it) })
        imeCatcher = ime
        root.addView(ime, FrameLayout.LayoutParams(1, 1))
        addFloatingBall()   // tap = 手指当笔, long-press = control panel
        maybeShowFirstRunHint()   // one-time dismissible bubble: explains ✎/↖ + the touchpad gestures
        val session = Session(t, caps, DeviceInfo.deviceName(), DeviceInfo.peerId(this), log = { Log.i(TAG, "[sess] $it") })
        session.trustGate = { pid, nm, local, ownerId, macEphPub, onResult ->
            wl.evaluate(pid, nm, local, ownerId, macEphPub, onResult) }
        session.onStatus = { s -> runOnUiThread { setStatus(s) } }
        // SC-AUTH-v1 pre-auth input gate: input/IME/keys reach the peer only once Session authorizes
        // (post-auth slot-claim, or wired/loopback exempt); revoked on every per-connection reset.
        session.onAuthorized = { ok -> sender.authorized = ok }
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

    // --- handwriting / control state (toggled from the floating ball + control panel) ---
    private var fingerAsPen = false     // 手指当笔: finger emits PEN ink (write on any device)
    private var drawingMode = false     // 绘画模式(触控笔): palm-reject fingers while the stylus is active
    private var inputDisabled = false   // 暂停输入: swallow screen touches (operate the tablet itself)
    private var ballHidden = false      // 隐藏悬浮球: fade the ball out (kept long-pressable to restore)
    private var floatingBall: FloatingBall? = null
    private var controlPanel: ControlPanel? = null
    private var lastStatus = ""
    private var lastCodec = ""
    private fun px(v: Int) = (v * resources.displayMetrics.density).toInt()

    /** Physical keys (hardware keyboard) → Mac, captured before any focused view. Unmapped keys
     *  (volume/back/home) fall through to Android. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        keyboard?.onKeyEvent(event) == true || super.dispatchKeyEvent(event)

    /** Draggable floating control: tap toggles 手指当笔, drag repositions, long-press opens the panel. */
    private fun addFloatingBall() {
        val ball = FloatingBall(this,
            onTap = { setFingerAsPen(!fingerAsPen) },
            onLongPress = { showControlPanel() })
        floatingBall = ball
        root.addView(ball, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        ball.post {   // initial dock: bottom-right, once root + ball are measured
            ball.x = (root.width - ball.width - px(20)).toFloat()
            ball.y = (root.height - ball.height - px(80)).toFloat()
        }
    }

    private fun setFingerAsPen(on: Boolean) { fingerAsPen = on; floatingBall?.active = on }

    /**
     * One-time gesture hint shown over the idle screen on first launch (confirmed onboarding gap, see
     * docs/UI-POLISH-DESIGN.md §3.4 Android). A dismissible card explaining the floating ball glyphs
     * (✎ 手指当笔 / ↖ 长按面板) + the core touchpad gestures. "Seen" is persisted in a plain UI pref —
     * NOT a service — so it never shows twice. Additive overlay layer; touches nothing input/transport.
     */
    private fun maybeShowFirstRunHint() {
        val prefs = getSharedPreferences("sc_ui", Context.MODE_PRIVATE)
        if (prefs.getBoolean("first_run_hint_seen", false)) return
        val card = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            background = android.graphics.drawable.GradientDrawable().apply {
                setColor(0xF21C1C1E.toInt()); cornerRadius = px(18).toFloat()
            }
            setPadding(px(24), px(22), px(24), px(20))
            addView(TextView(context).apply {
                text = "快速上手"; setTextColor(0xFFF2F2F7.toInt()); textSize = 19f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            })
            addView(TextView(context).apply {
                text = "• 单指滑动移动指针，轻点单击，双指轻点右键\n" +
                       "• 双指滑动滚动，双指捏合缩放，按住滑动拖拽\n" +
                       "• 悬浮球 ↖：轻点切换「手指当笔 ✎」，长按打开控制面板"
                setTextColor(0xFFC8C8CC.toInt()); textSize = 14f
                setLineSpacing(0f, 1.35f); setPadding(0, px(12), 0, 0)
            })
            addView(android.widget.Button(context).apply {
                text = "知道了"; isAllCaps = false
                contentDescription = "关闭快速上手提示"
            }, android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { gravity = Gravity.END; topMargin = px(14) })
        }
        val lp = FrameLayout.LayoutParams(px(420), WRAP_CONTENT, Gravity.CENTER)
        lp.setMargins(px(24), px(24), px(24), px(24))
        root.addView(card, lp)
        // the "知道了" button is the card's 3rd child
        (card.getChildAt(2) as android.widget.Button).setOnClickListener {
            root.removeView(card)
            prefs.edit().putBoolean("first_run_hint_seen", true).apply()
        }
    }

    private fun showControlPanel() {
        if (controlPanel != null) return
        val state = ControlPanel.State(
            statusText = lastStatus, port = 8888,
            vWidth = vW, vHeight = vH, vCodec = lastCodec,
            wirelessOn = wireless?.enabled() ?: false, wifiIp = wireless?.wifiIpv4() ?: "",
            pairedPeers = wireless?.trustedPeers()?.toList() ?: emptyList(),
            fingerAsPen = fingerAsPen, drawingMode = drawingMode,
            inputDisabled = inputDisabled, ballHidden = ballHidden,
        )
        val cb = ControlPanel.Callbacks(
            onFingerAsPen = { setFingerAsPen(it) },
            onDrawingMode = { drawingMode = it },
            onPauseInput = { inputDisabled = it },
            onHideBall = { ballHidden = it; floatingBall?.alpha = if (it) 0.08f else 0.6f },
            onKeyboard = { toggleKeyboard() },
            onToggleWireless = { wireless?.setEnabled(it) },
            onForgetPeer = { wireless?.forgetPeer(it) },
            onClose = { hideControlPanel() },
        )
        val panel = ControlPanel(this, state, cb)
        controlPanel = panel
        root.addView(panel)
    }

    private fun hideControlPanel() {
        controlPanel?.let { root.removeView(it) }
        controlPanel = null
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
        runOnUiThread { vW = w; vH = h; lastCodec = codec; fitSurface(); setStatus("已连接 · ${w}×${h} ${codec.uppercase()} · 等待画面…") }
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
        lastStatus = s
        statusView.visibility = View.VISIBLE
        // View-layer status clarity: a colored ● leads the line, its hue derived purely from the status
        // STRING (no service read) — blue=可连接/等待, amber=握手/等待画面, green=投屏中, gray=断开/离线.
        // The dot is decorative; statusContentDescription carries a spoken phrase for TalkBack.
        val dot = SpannableString("● ").apply {
            setSpan(ForegroundColorSpan(statusColor(s)), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        statusView.text = TextUtils.concat("Superconnect 接收端\n\n", dot, s)
        statusView.contentDescription = "${statusPhrase(s)}。$s"
    }

    /** Map a status string → semantic color (shared visual language; see docs/UI-POLISH-DESIGN.md §1.1). */
    private fun statusColor(s: String): Int = when {
        s.contains("投屏中") -> 0xFF34C759.toInt()                       // connected / streaming — green
        s.contains("握手") || s.contains("等待画面") -> 0xFFFF9F0A.toInt() // connecting / transitional — amber
        s.contains("等待 Mac") || s.contains("等待") -> 0xFF0A84FF.toInt() // available / idle — blue
        else -> 0xFF8E8E93.toInt()                                       // disconnected / offline — gray
    }

    /** Spoken status phrase for TalkBack — mirrors [statusColor]'s buckets. */
    private fun statusPhrase(s: String): String = when {
        s.contains("投屏中") -> "已连接，投屏中"
        s.contains("握手") || s.contains("等待画面") -> "正在连接"
        s.contains("等待 Mac") || s.contains("等待") -> "等待 Mac 连接"
        else -> "已断开"
    }

    private fun hideStatus() { statusView.visibility = View.GONE }

    /** BACK closes the control panel (if open) instead of exiting; otherwise default. */
    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (controlPanel != null) { hideControlPanel(); return }
        @Suppress("DEPRECATION") super.onBackPressed()
    }

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
