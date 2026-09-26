package com.superconnect.receiver

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/** Presentation only: the Activity owns sockets, consent, media and decoding. */
internal class ReceiverPresentation(
    private val activity: Activity,
    private val onExit: () -> Unit,
    private val onWireless: () -> Unit,
    private val onPointerToggle: () -> Boolean,
    private val onKeyboard: () -> Unit,
) {
    val root = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        setBackgroundColor(CREAM)
        setPadding(dp(28), dp(22), dp(28), dp(22))
    }
    val videoContainer = FrameLayout(activity).apply {
        background = rounded(DARK, 22)
        clipToOutline = true
    }
    val surfaceView = SurfaceView(activity)
    private val loading = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER
        setPadding(dp(24), dp(24), dp(24), dp(24))
        setBackgroundColor(CREAM)
    }
    private val heading = label("让这块屏幕，多一种可能。", 25, INK, true)
    private val detail = label("在 Mac 上连接此设备，画面将在这里出现。", 15, MUTED)
    private val status = label("等待连接", 13, ACCENT, true)
    private val address = label("正在获取连接地址…", 16, INK, true)
    private val wireless = button("关闭无线", false, onWireless)
    private val fullButton = button("进入全屏  ↗", true) { setFullscreen(true) }
    private val header = LinearLayout(activity).apply {
        gravity = Gravity.CENTER_VERTICAL
        orientation = LinearLayout.HORIZONTAL
    }
    private val sidebar = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
    private val footer = label("画面始终在你的设备之间传输。首次连接需在本机确认。", 12, MUTED)
    private val content = LinearLayout(activity).apply { orientation = LinearLayout.HORIZONTAL }
    private val edge = button("‹", false) { revealTray() }.apply { alpha = 0.38f }
    private val tray = LinearLayout(activity).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        background = rounded(CREAM, 18)
        setPadding(dp(8), dp(6), dp(8), dp(6))
        visibility = View.GONE
    }
    private var fullscreen = false
    private var displaying = false
    private val pointerButtons = mutableListOf<Button>()

    init {
        val brand = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        brand.addView(label("Superconnect", 23, INK, true))
        brand.addView(label("让 Mac 与平板，连接成一个工作空间。", 13, MUTED))
        header.addView(brand, LinearLayout.LayoutParams(0, dp(68), 1f))
        status.background = rounded(PALE, 16)
        status.setPadding(dp(15), dp(9), dp(15), dp(9))
        header.addView(status)
        root.addView(header)

        videoContainer.addView(surfaceView, FrameLayout.LayoutParams(MATCH, MATCH, Gravity.CENTER))
        loading.addView(label("▱", 64, ACCENT).apply { gravity = Gravity.CENTER })
        heading.gravity = Gravity.CENTER
        loading.addView(heading, column(MATCH, WRAP, 16))
        detail.gravity = Gravity.CENTER
        loading.addView(detail, column(MATCH, WRAP, 10))
        videoContainer.addView(loading, FrameLayout.LayoutParams(MATCH, MATCH))
        videoContainer.addView(edge, FrameLayout.LayoutParams(dp(30), dp(56), Gravity.END or Gravity.CENTER_VERTICAL))
        edge.visibility = View.GONE
        tray.addView(button("退出全屏", false) { setFullscreen(false) })
        tray.addView(pointerButton())
        tray.addView(button("键盘", false, onKeyboard))
        tray.addView(button("断开", false, onExit))
        videoContainer.addView(tray, FrameLayout.LayoutParams(WRAP, WRAP, Gravity.TOP or Gravity.END).apply {
            setMargins(dp(12), dp(12), dp(12), dp(12))
        })

        content.addView(videoContainer, LinearLayout.LayoutParams(0, MATCH, 1f))
        val scroll = ScrollView(activity).apply { isFillViewport = true; addView(sidebar) }
        content.addView(scroll, LinearLayout.LayoutParams(dp(292), MATCH).apply { leftMargin = dp(22) })
        root.addView(content, column(MATCH, 0, 14).apply { weight = 1f })
        root.addView(footer, column(MATCH, WRAP, 16))

        val connection = card("连接你的 Mac", "在同一 Wi-Fi 下，在 Mac 中添加下方地址。")
        connection.addView(address, column(MATCH, WRAP, 18))
        connection.addView(wireless, column(MATCH, dp(44), 16))
        sidebar.addView(connection)
        val display = card("专注于画面", "先在小窗口确认画面，再进入全屏。")
        display.addView(fullButton, column(MATCH, dp(46), 18))
        sidebar.addView(display, column(MATCH, WRAP, 14))
        val future = card("触控、手写笔与键盘", "在 Mac 上允许平板控制，即可点击、书写与输入文字。")
        future.addView(pointerButton(), column(MATCH, dp(42), 12))
        future.addView(button("打开键盘", false, onKeyboard), column(MATCH, dp(42), 8))
        listOf("文件传输").forEach { name ->
            future.addView(button("🔒  $name   ·   后续解锁", false) { showLocked(name) },
                column(MATCH, dp(42), 8))
        }
        sidebar.addView(future, column(MATCH, WRAP, 14))
        fullButton.isEnabled = false
        fullButton.alpha = 0.45f
    }

    fun updateWireless(enabled: Boolean, host: String, port: Int) {
        address.text = if (host.isNotEmpty()) "$host:$port" else "等待 Wi-Fi 地址"
        wireless.text = if (enabled) "关闭无线连接" else "开启无线连接"
    }

    fun showStatus(message: String) {
        displaying = false
        loading.animate().cancel()
        loading.alpha = 1f
        loading.visibility = View.VISIBLE
        fullButton.isEnabled = false
        fullButton.alpha = 0.45f
        val failed = message.contains("失败") || message.contains("无法") || message.contains("不可用")
        val connecting = message.contains("已连接") || message.contains("已认证")
        status.text = if (failed) "需要重试" else if (connecting) "正在准备画面" else "等待连接"
        heading.text = if (failed) "暂时无法显示画面" else if (connecting) "连接好了，画面马上到。" else "让这块屏幕，多一种可能。"
        detail.text = when {
            failed -> message.substringBefore("\n")
            connecting -> "保持应用打开，正在准备你的工作空间。"
            else -> "在 Mac 上连接此设备，画面将在这里出现。"
        }
    }

    fun showVideo() {
        if (displaying) return
        displaying = true
        loading.animate().alpha(0f).setDuration(220).withEndAction {
            loading.visibility = View.GONE
            loading.alpha = 1f
        }.start()
        status.text = "●  正在投屏"
        fullButton.isEnabled = true
        fullButton.alpha = 1f
    }

    fun fitVideo(width: Int, height: Int) {
        val cw = videoContainer.width
        val ch = videoContainer.height
        if (cw <= 0 || ch <= 0 || width <= 0 || height <= 0) return
        val scale = minOf(cw.toFloat() / width, ch.toFloat() / height)
        val w = (width * scale).toInt()
        val h = (height * scale).toInt()
        if (surfaceView.width == w && surfaceView.height == h) return
        surfaceView.layoutParams = FrameLayout.LayoutParams(w, h, Gravity.CENTER)
    }

    private fun setFullscreen(value: Boolean) {
        if (value && !displaying) return
        fullscreen = value
        header.visibility = if (value) View.GONE else View.VISIBLE
        footer.visibility = if (value) View.GONE else View.VISIBLE
        content.getChildAt(1).visibility = if (value) View.GONE else View.VISIBLE
        root.setPadding(if (value) 0 else dp(28), if (value) 0 else dp(22),
            if (value) 0 else dp(28), if (value) 0 else dp(22))
        (content.layoutParams as LinearLayout.LayoutParams).topMargin = if (value) 0 else dp(14)
        videoContainer.background = rounded(DARK, if (value) 0 else 22)
        edge.visibility = if (value) View.VISIBLE else View.GONE
        tray.visibility = View.GONE
        root.requestLayout()
    }

    private fun revealTray() {
        if (!fullscreen) return
        tray.visibility = View.VISIBLE
        tray.alpha = 0f
        tray.animate().alpha(1f).setDuration(160).start()
        tray.removeCallbacks(hideTray)
        tray.postDelayed(hideTray, 4000)
    }
    private val hideTray = Runnable { tray.visibility = View.GONE }

    private fun showLocked(name: String) {
        AlertDialog.Builder(activity).setTitle("$name · 后续解锁")
            .setMessage("当前版本支持查看 Mac 画面。$name 尚未开放，不影响投屏使用。")
            .setPositiveButton("知道了", null).show()
    }

    private fun pointerButton(): Button {
        val button = button("平板控制 · 开启", false) {}
        pointerButtons.add(button)
        button.setOnClickListener {
            val text = if (onPointerToggle()) "平板控制 · 开启" else "平板控制 · 关闭"
            pointerButtons.forEach { it.text = text }
        }
        return button
    }

    private fun card(title: String, caption: String): LinearLayout = LinearLayout(activity).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(PAPER, 20)
        setPadding(dp(20), dp(20), dp(20), dp(20))
        addView(label(title, 18, INK, true))
        addView(label(caption, 13, MUTED), column(MATCH, WRAP, 8))
    }
    private fun label(value: String, size: Int, color: Int, bold: Boolean = false): TextView =
        TextView(activity).apply {
            text = value; textSize = size.toFloat(); setTextColor(color)
            if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            setLineSpacing(dp(3).toFloat(), 1f)
        }
    private fun button(title: String, primary: Boolean, action: () -> Unit): Button = Button(activity).apply {
        text = title; textSize = 14f; isAllCaps = false
        setTextColor(if (primary) Color.WHITE else INK)
        background = rounded(if (primary) ACCENT else PALE, 12)
        minWidth = 0; minimumWidth = 0; minHeight = 0; minimumHeight = 0
        setPadding(dp(14), dp(8), dp(14), dp(8))
        setOnClickListener { action() }
    }
    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
    }
    private fun column(w: Int, h: Int, top: Int = 0) = LinearLayout.LayoutParams(w, h).apply { topMargin = dp(top) }
    private fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()
    private companion object {
        const val MATCH = ViewGroup.LayoutParams.MATCH_PARENT
        const val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
        val CREAM = Color.rgb(245, 241, 232)
        val PAPER = Color.rgb(255, 252, 246)
        val PALE = Color.rgb(235, 225, 211)
        val ACCENT = Color.rgb(164, 83, 46)
        val INK = Color.rgb(48, 43, 37)
        val MUTED = Color.rgb(129, 119, 106)
        val DARK = Color.rgb(33, 32, 29)
    }
}
