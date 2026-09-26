package com.superconnect.receiver

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

/** FOSS receiver with optional tablet input. Every route uses mutual Auth + SC-RECORD. */
class MainActivity : Activity(), SurfaceHolder.Callback {
    private var transport: TcpServerTransport? = null
    private var sessionHost: ReceiverSessionHost? = null
    private var wireless: WirelessService? = null
    private var pairingDialog: android.app.AlertDialog? = null

    private lateinit var presentation: ReceiverPresentation
    private lateinit var pointerInput: PointerInputController
    private lateinit var keyboard: KeyboardHandler
    private lateinit var ime: ImeCatcher
    private lateinit var surfaceView: SurfaceView

    private val lifecycleLock = Any()
    private val generationFence = ReceiverMediaAuthorizationOwner(
        ownershipLock = lifecycleLock,
        activated = ::activateGeneration,
        terminated = ::terminateGeneration,
    )
    private var surface: Surface? = null
    private var decoder: VideoDecoder? = null
    private var decoderFailure: String? = null
    private var cfgW = 0
    private var cfgH = 0
    private var cfgMime = "video/avc"
    private var gotKeyframe = false
    private var frameCount = 0
    private var videoWidth = 0
    private var videoHeight = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        actionBar?.hide()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUi()
        buildUi()

        val caps = DeviceInfo.caps(this)
        val localPeerId = runCatching(FossDeviceIdentity::peerId).getOrElse { error ->
            Log.e(TAG, "AndroidKeyStore identity unavailable", error)
            setStatus("安全身份不可用，接收端保持关闭。")
            return
        }

        val wirelessOwner = WirelessService(this) { Log.i(TAG, "[wl] $it") }
        wirelessOwner.onPairingRequest = { _, name, promptId ->
            runOnUiThread { showPairingDialog(name, promptId) }
        }
        wirelessOwner.onPairingDismiss = {
            runOnUiThread { pairingDialog?.dismiss(); pairingDialog = null }
        }
        wirelessOwner.onEnabledChanged = { enabled ->
            runOnUiThread {
                updateWirelessButton(enabled)
                restartListener(enabled)
            }
        }
        wirelessOwner.onWifiAddressChanged = {
            runOnUiThread { updateWirelessButton(wirelessOwner.enabled()) }
        }
        wireless = wirelessOwner

        val sessions = ReceiverSessionHost(
            caps = caps,
            deviceName = DeviceInfo.deviceName(),
            peerId = localPeerId,
            authorizedCapabilities = FossProductPolicy.authorizedCapabilityBits,
            intentProductProfileV2 = FossProductPolicy.intentProfileV2,
            trustGate = { peerId, name, ownerId, hasMacEphPub, onPromptStarted, onResult ->
                wirelessOwner.evaluate(
                    peerId,
                    name,
                    ownerId,
                    hasMacEphPub,
                    onPromptStarted,
                    onResult,
                )
            },
            log = { Log.i(TAG, "[session] $it") },
        )
        sessions.onVideoConfig = { generation, width, height, codec, _, _ ->
            onVideoConfig(generation, width, height, codec)
        }
        sessions.onVideo = ::onVideo
        sessions.onAuthorized = generationFence::onAuthorized
        sessions.onPeerClosed = { ownerId ->
            wirelessOwner.cancelPairing(ownerId)
            if (sessions.activePeerId() < 0 && generationFence.current() == 0L) {
                runOnUiThread {
                    if (generationFence.current() == 0L) setStatus(waitingMessage())
                }
            }
        }
        sessionHost = sessions

        updateWirelessButton(wirelessOwner.enabled())
        restartListener(wirelessOwner.enabled())
    }

    private fun buildUi() {
        keyboard = KeyboardHandler(
            send = { bytes -> sessionHost?.sendPointer(bytes) ?: bytes.fill(0) },
            sendText = { sessionHost?.sendText(it) },
            active = { pointerInput.enabled && generationFence.current() != 0L },
        )
        ime = ImeCatcher(this, keyboard::commitText, keyboard::backspace, keyboard::onKeyEvent)
        pointerInput = PointerInputController(
            send = { bytes -> sessionHost?.sendPointer(bytes) ?: bytes.fill(0) },
            videoRect = { floatArrayOf(0f, 0f, surfaceView.width.toFloat(), surfaceView.height.toFloat()) },
        )
        presentation = ReceiverPresentation(
            activity = this,
            onExit = { finish() },
            onWireless = { wireless?.setEnabled(!(wireless?.enabled() ?: false)) },
            onPointerToggle = {
                keyboard.release()
                pointerInput.enabled = !pointerInput.enabled
                pointerInput.enabled
            },
            onKeyboard = {
                ime.requestFocus()
                (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                    .showSoftInput(ime, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
            },
        )
        surfaceView = presentation.surfaceView.also { it.holder.addCallback(this) }
        surfaceView.setOnTouchListener { _, event -> pointerInput.onTouch(event) }
        surfaceView.setOnHoverListener { _, event -> pointerInput.onHover(event) }
        presentation.videoContainer.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> fitSurface() }
        setContentView(presentation.root)
        presentation.root.addView(ime, android.widget.LinearLayout.LayoutParams(1, 1))
    }

    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean =
        if (::keyboard.isInitialized && keyboard.onKeyEvent(event)) true else super.dispatchKeyEvent(event)

    override fun onStart() {
        super.onStart()
        if (sessionHost != null && transport == null) restartListener(wireless?.enabled() == true)
    }

    override fun onStop() {
        keyboard.release()
        pointerInput.cancel()
        // 卓易通 may suspend the Android container after returning to Harmony home. Release
        // the peer before suspension, rather than letting a stale active slot reject reconnects.
        transport?.stop()
        transport = null
        wireless?.stopAdvertise()
        super.onStop()
    }

    /** Restarts only the listener. Both loopback and LAN are deliberately marked mutual-auth. */
    private fun restartListener(enableLan: Boolean) {
        transport?.stop()
        transport = null
        wireless?.stopAdvertise()
        // 卓易通 runs the APK in a separate Android container. HDC forwards into the Harmony
        // device namespace, not the container's loopback, so 127.0.0.1 accepts the socket but
        // immediately resets the forwarded connection. Bind the local receiver on all container
        // interfaces; wireless advertisement remains disabled unless the user explicitly enables it.
        val address = if (enableLan) "0.0.0.0" else "127.0.0.1"
        val sessions = sessionHost ?: return
        val listener = TcpServerTransport(port = PORT, bindAddress = address) {
            Log.i(TAG, "[tcp] $it")
        }
        listener.onPeer = sessions::accept
        listener.onListening = { actualAddress, actualPort ->
            if (enableLan) wireless?.startAdvertise(DeviceInfo.deviceName(), actualPort)
            runOnUiThread {
                setStatus(waitingMessage("监听 $actualAddress:$actualPort"))
            }
        }
        listener.onListenFailed = { failedAddress, failedPort ->
            runOnUiThread { setStatus("监听失败：$failedAddress:$failedPort") }
        }
        transport = listener
        listener.start(address, PORT, ListenerOrigin.Wireless, 1)
    }

    private fun updateWirelessButton(enabled: Boolean) {
        val address = wireless?.wifiIpv4().orEmpty()
        presentation.updateWireless(enabled, address, PORT)
    }

    private fun waitingMessage(prefix: String = "等待 Mac 连接…"): String {
        val route = if (wireless?.enabled() == true) {
            wireless?.wifiIpv4()?.takeIf { it.isNotEmpty() }?.let { "无线 $it:$PORT" }
                ?: "无线已开启"
        } else {
            "仅本机转发 127.0.0.1:$PORT"
        }
        return "$prefix\n$route\nViewOnly · SC-AUTH-v1 · SC-RECORD-v1"
    }

    private fun onVideoConfig(generation: Long, width: Int, height: Int, codec: String) {
        Log.i(TAG, "video_config ${width}x$height $codec")
        synchronized(lifecycleLock) {
            if (!generationFence.isActive(generation)) return
            cfgW = width
            cfgH = height
            cfgMime = VideoDecoder.mimeFor(codec)
            gotKeyframe = false
            maybeCreateDecoder(generation)
        }
        runOnUiThread {
            if (generationFence.isActive(generation)) {
                videoWidth = width
                videoHeight = height
                fitSurface()
                setStatus(decoderFailure ?: "已连接 · ${width}×$height ${codec.uppercase()} · 等待关键帧…")
            }
        }
    }

    /** Returns true only when the decoder takes ownership of the exact plaintext access-unit array. */
    private fun onVideo(generation: Long, frame: ReceivedVideoAccessUnit): Boolean {
        val accepted = synchronized(lifecycleLock) {
            if (!generationFence.isActive(generation)) return@synchronized false
            frameCount += 1
            if (!gotKeyframe && !frame.isKeyframe) return@synchronized false
            val admitted = decoder?.submit(frame.payload) == true
            if (admitted && frame.isKeyframe) gotKeyframe = true
            admitted
        }
        return accepted
    }

    private fun maybeCreateDecoder(generation: Long) {
        if (!generationFence.isActive(generation)) return
        val targetSurface = surface ?: return
        if (cfgW <= 0 || cfgH <= 0) return
        decoder?.stop()
        decoderFailure = null
        decoder = try {
            VideoDecoder(
                cfgMime,
                cfgW,
                cfgH,
                targetSurface,
                generation,
                generationFence::isActive,
                onFirstFrame = {
                    runOnUiThread {
                        if (generationFence.isActive(generation)) presentation.showVideo()
                    }
                },
            ) { Log.i(TAG, "[decoder:$generation] $it") }
                .also { it.start() }
        } catch (error: Exception) {
            Log.e(TAG, "decoder create failed", error)
            decoderFailure = "无法创建画面解码器：${error.javaClass.simpleName} · ${error.message}"
            runOnUiThread {
                if (generationFence.isActive(generation)) setStatus(decoderFailure ?: waitingMessage())
            }
            null
        }
    }

    private fun fitSurface() {
        presentation.fitVideo(videoWidth, videoHeight)
    }

    private fun setStatus(message: String) {
        presentation.showStatus(message)
    }

    private fun showPairingDialog(deviceName: String, promptId: Int) {
        if (isFinishing || isDestroyed) {
            wireless?.respondPairing(promptId, false)
            return
        }
        pairingDialog?.dismiss()
        var decided = false
        pairingDialog = android.app.AlertDialog.Builder(this)
            .setTitle("允许连接？")
            .setMessage("“$deviceName” 想连接到本机投屏。允许后将保存加密配对凭据。")
            .setCancelable(false)
            .setPositiveButton("允许") { _, _ ->
                if (!decided) {
                    decided = true
                    wireless?.respondPairing(promptId, true)
                }
            }
            .setNegativeButton("拒绝") { _, _ ->
                if (!decided) {
                    decided = true
                    wireless?.respondPairing(promptId, false)
                }
            }
            .show()
    }

    private fun hideSystemUi() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.systemBars())
                controller.systemBarsBehavior =
                    WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
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
        if (hasFocus) hideSystemUi()
        else if (::pointerInput.isInitialized) {
            pointerInput.cancel()
            keyboard.release()
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        synchronized(lifecycleLock) {
            surface = holder.surface
            generationFence.current().takeIf { it > 0 }?.let(::maybeCreateDecoder)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        synchronized(lifecycleLock) {
            decoder?.stop()
            decoder = null
            surface = null
            gotKeyframe = false
        }
    }

    override fun onDestroy() {
        if (::keyboard.isInitialized) keyboard.release()
        if (::pointerInput.isInitialized) pointerInput.cancel()
        pairingDialog?.dismiss()
        pairingDialog = null
        transport?.stop()
        transport = null
        sessionHost?.dispose()
        sessionHost = null
        wireless?.dispose()
        wireless = null
        generationFence.current().takeIf { it > 0 }?.let { generation ->
            generationFence.onAuthorized(false, generation)
        }
        super.onDestroy()
    }

    /** Called with [lifecycleLock] held; expensive decoder/UI work is returned for lock-free completion. */
    private fun activateGeneration(generation: Long): () -> Unit {
        val retired = decoder
        decoder = null
        resetMediaLocked()
        return {
            retired?.stop()
            runOnUiThread {
                if (generationFence.isActive(generation)) {
                    setStatus("已认证并启用加密记录 · 等待视频配置…")
                }
            }
        }
    }

    /** Called with [lifecycleLock] held and captures only the resource owned at this transition. */
    private fun terminateGeneration(generation: Long): () -> Unit {
        val retired = decoder
        decoder = null
        resetMediaLocked()
        return {
            retired?.stop()
            runOnUiThread {
                if (generationFence.current() == 0L) setStatus(waitingMessage())
            }
        }
    }

    private fun resetMediaLocked() {
        decoderFailure = null
        cfgW = 0
        cfgH = 0
        cfgMime = "video/avc"
        gotKeyframe = false
        frameCount = 0
        videoWidth = 0
        videoHeight = 0
    }

    private companion object {
        const val PORT = 18888
        const val TAG = "SCFossReceiver"
    }
}
