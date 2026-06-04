package com.superconnect.receiver

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView

/**
 * Settings / quick-toggles / cheat-sheet overlay — Kotlin/View port of harmony `ui/ControlPanel.ets`
 * (a subset: the Android receiver is always fullscreen, so no windowed-mode row). Built entirely in
 * code (no XML) to match the rest of the receiver. Opened by long-pressing the [FloatingBall]; a snapshot
 * of state is passed at construction, toggles report changes through [Callbacks], a tap on the dim
 * backdrop or ✕ closes it.
 */
class ControlPanel(
    context: Context,
    private val s: State,
    private val cb: Callbacks,
) : FrameLayout(context) {

    data class State(
        val statusText: String, val port: Int,
        val vWidth: Int, val vHeight: Int, val vCodec: String,
        val wirelessOn: Boolean, val wifiIp: String,
        val pairedPeers: List<String>,
        val fingerAsPen: Boolean, val drawingMode: Boolean,
        val inputDisabled: Boolean, val ballHidden: Boolean,
    )

    class Callbacks(
        val onFingerAsPen: (Boolean) -> Unit,
        val onDrawingMode: (Boolean) -> Unit,
        val onPauseInput: (Boolean) -> Unit,
        val onHideBall: (Boolean) -> Unit,
        val onKeyboard: () -> Unit,
        val onToggleWireless: (Boolean) -> Unit,
        val onForgetPeer: (String) -> Unit,
        val onClose: () -> Unit,
    )

    private val dp = resources.displayMetrics.density
    private fun px(v: Int) = (v * dp).toInt()
    private val accent = 0xFF2E7DF6.toInt()
    private val primaryText = 0xFFF2F2F7.toInt()
    private val secondaryText = 0xFFA0A0A8.toInt()
    private val tertiaryText = 0xFF7A7A80.toInt()

    init {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        setBackgroundColor(0xB0000000.toInt())              // dim backdrop
        setOnClickListener { cb.onClose() }                 // tap outside the card closes

        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                setColor(0xFF1C1C1E.toInt()); cornerRadius = px(18).toFloat()
            }
            setPadding(px(22), px(20), px(22), px(20))
            isClickable = true                              // swallow taps so they don't close the panel
        }
        val cardLp = LayoutParams(px(360), LayoutParams.WRAP_CONTENT, Gravity.CENTER)
        cardLp.setMargins(px(16), px(24), px(16), px(24))
        addView(card, cardLp)

        // header
        card.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(TextView(context).apply {
                text = "控制面板"; setTextColor(primaryText); textSize = 19f
                setTypeface(typeface, android.graphics.Typeface.BOLD)
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(context).apply {
                text = "✕"; setTextColor(secondaryText); textSize = 18f
                setPadding(px(12), px(2), px(4), px(2))
                setOnClickListener { cb.onClose() }
            })
        })

        val scroll = ScrollView(context).apply { isVerticalScrollBarEnabled = false }
        val col = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        scroll.addView(col)
        // cap the panel height so long content scrolls instead of overflowing the screen
        card.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            (resources.displayMetrics.heightPixels * 0.74f).toInt()
        ).apply { topMargin = px(8) })

        section(col, "快捷开关")
        toggleRow(col, "手指当笔（无触控笔也能手写）", s.fingerAsPen, cb.onFingerAsPen)
        toggleRow(col, "绘画模式（触控笔 · 手掌防误触）", s.drawingMode, cb.onDrawingMode)
        toggleRow(col, "暂停输入（操作平板本身）", s.inputDisabled, cb.onPauseInput)
        toggleRow(col, "隐藏悬浮球", s.ballHidden, cb.onHideBall)
        col.addView(Button(context).apply {
            text = "显示软键盘 ⌨"; isAllCaps = false
            setOnClickListener { cb.onKeyboard(); cb.onClose() }
        }, rowLp())

        section(col, "连接状态")
        infoRow(col, "状态", s.statusText)
        infoRow(col, "端口", s.port.toString())
        infoRow(col, "分辨率", if (s.vWidth > 0) "${s.vWidth} × ${s.vHeight}" else "—")
        infoRow(col, "编码", if (s.vCodec.isNotEmpty()) s.vCodec.uppercase() else "—")

        section(col, "无线连接")
        toggleRow(col, "无线模式 (Wi‑Fi)", s.wirelessOn, cb.onToggleWireless)
        infoRow(col, "Wi‑Fi 地址",
            if (s.wirelessOn) (if (s.wifiIp.isNotEmpty()) "${s.wifiIp} : ${s.port}" else "未连接 Wi‑Fi") else "仅 USB")
        caption(col, if (s.wirelessOn) "同一 Wi‑Fi 下的 Mac 可自动发现，或手动输入上面的地址连接。"
        else "开启后同网段 Mac 可无线连接；关闭时仅支持数据线 (USB)。切换在下次连接生效。")

        section(col, "已配对设备")
        if (s.pairedPeers.isEmpty()) {
            caption(col, "暂无。首次无线连接时在本机点「允许」即可记住该 Mac。")
        } else {
            for (peer in s.pairedPeers) {
                col.addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                    addView(TextView(context).apply {
                        text = peer; setTextColor(primaryText); textSize = 13f; maxLines = 1
                    }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                    addView(Button(context).apply {
                        text = "移除"; isAllCaps = false; textSize = 12f
                        setOnClickListener { cb.onForgetPeer(peer) }
                    })
                }, rowLp())
            }
        }

        section(col, "触控板手势")
        cheatRow(col, "移动", "单指滑动")
        cheatRow(col, "单击 / 右键", "轻点 / 双指轻点")
        cheatRow(col, "滚动 / 缩放", "双指滑动 / 双指捏合")
        cheatRow(col, "拖动", "按住滑动，松手放下")

        section(col, "键盘映射")
        cheatRow(col, "⊙ Meta", "⌥ Option")
        cheatRow(col, "Caps", "切换中 / 英文输入")
        cheatRow(col, "方向键 / 功能键", "已映射，直接用外接键盘")

        section(col, "画质设置")
        caption(col, "分辨率 / 刷新率 / 编码 / 码率由 Mac 端自动协商，可在 Mac 菜单栏 App 中调整。")
    }

    private fun rowLp() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
    ).apply { topMargin = px(4); bottomMargin = px(4) }

    private fun section(parent: LinearLayout, title: String) {
        parent.addView(TextView(parent.context).apply {
            text = title; setTextColor(accent); textSize = 13f
            setTypeface(typeface, android.graphics.Typeface.NORMAL)
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = px(16); bottomMargin = px(2) })
    }

    private fun infoRow(parent: LinearLayout, label: String, value: String) {
        parent.addView(LinearLayout(parent.context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(TextView(context).apply { text = label; setTextColor(secondaryText); textSize = 14f },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(context).apply {
                text = value; setTextColor(primaryText); textSize = 14f; gravity = Gravity.END
            })
        }, rowLp())
    }

    private fun toggleRow(parent: LinearLayout, label: String, on: Boolean, onChange: (Boolean) -> Unit) {
        parent.addView(LinearLayout(parent.context).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            addView(TextView(context).apply { text = label; setTextColor(primaryText); textSize = 14f },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(Switch(context).apply {
                isChecked = on
                setOnCheckedChangeListener { _, v -> onChange(v) }
            })
        }, rowLp())
    }

    private fun cheatRow(parent: LinearLayout, action: String, how: String) {
        parent.addView(LinearLayout(parent.context).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(TextView(context).apply { text = action; setTextColor(primaryText); textSize = 13f },
                LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(context).apply { text = how; setTextColor(secondaryText); textSize = 13f })
        }, rowLp())
    }

    private fun caption(parent: LinearLayout, text: String) {
        parent.addView(TextView(parent.context).apply {
            this.text = text; setTextColor(tertiaryText); textSize = 12f
        }, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { topMargin = px(2) })
    }
}
