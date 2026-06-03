package com.superconnect.receiver

import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameCodec
import com.superconnect.protocol.InputCodec
import com.superconnect.protocol.InputEvent

/**
 * Encodes captured input events and sends them to the Mac on the INPUT channel (over the reliable TCP
 * Session). The Mac's InputInjector executes them: a FINGER touchDown with buttons=primary → leftMouseDown
 * at the normalized point (tap = click, drag = drag); a PEN draws with pressure/tilt. v0.2 alignment:
 * single-finger direct manipulation + pen. (2-finger scroll / right-click — the GestureController port —
 * is the next alignment increment.)
 */
class InputSender(private val transport: TcpServerTransport) {
    fun send(e: InputEvent) {
        transport.send(FrameCodec.encode(Channel.INPUT, 0, InputCodec.encode(e)))
    }
}
