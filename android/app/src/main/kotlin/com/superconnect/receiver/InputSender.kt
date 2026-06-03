package com.superconnect.receiver

import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameCodec
import com.superconnect.protocol.InputCodec
import com.superconnect.protocol.InputEvent
import org.json.JSONObject

/**
 * Sends captured input to the Mac: fixed-size InputEvent records on the INPUT channel, and committed
 * (soft-keyboard / IME) text on the CONTROL channel as `{"type":"text",...}` — byte-identical to the
 * HarmonyOS FrameInputSender. The Mac's InputInjector executes the INPUT records (finger/pen/scroll/zoom/
 * key) and `Session.onText → injectText` types the committed text. Input handlers go through this seam
 * only (never the transport directly), mirroring the HarmonyOS Sender contract.
 */
class InputSender(private val transport: TcpServerTransport) {
    fun send(e: InputEvent) {
        transport.send(FrameCodec.encode(Channel.INPUT, 0, InputCodec.encode(e)))
    }

    /** Committed IME/soft-keyboard text → CONTROL `{type:text}` (Mac types it verbatim, incl. CJK). */
    fun sendText(text: String) {
        if (text.isEmpty()) return
        val msg = JSONObject().put("type", "text").put("text", text)
        transport.send(FrameCodec.encode(Channel.CONTROL, 0, msg.toString().toByteArray(Charsets.UTF_8)))
    }
}
