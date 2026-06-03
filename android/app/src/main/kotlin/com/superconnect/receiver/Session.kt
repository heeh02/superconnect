package com.superconnect.receiver

import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameCodec
import com.superconnect.protocol.FrameFlags
import org.json.JSONArray
import org.json.JSONObject

/**
 * Receiver session — drives the hello/hello_ack handshake and routes frames. The Mac dials in and
 * sends `hello`; we reply `hello_ack` advertising our screen caps + name + role, after which the Mac
 * sizes a virtual display to our screen and streams VIDEO. Mirrors HarmonyOS Session (FREE subset —
 * no paid udpVideoPort). VIDEO + ping are handled here; MediaCodec decode and INPUT send are wired by
 * the caller / land in the next increments. Control messages are JSON (org.json ships in Android).
 */
class Session(
    private val transport: TcpServerTransport,
    private val caps: ReceiverCaps,
    private val deviceName: String,
    private val peerId: String,
    private val log: (String) -> Unit = {},
) {
    var onVideo: ((payload: ByteArray, isKeyframe: Boolean) -> Unit)? = null
    var onVideoConfig: ((width: Int, height: Int, codec: String, hdr: String) -> Unit)? = null
    var onStatus: ((String) -> Unit)? = null

    fun attach() {
        transport.onClientChange = { connected -> onStatus?.invoke(if (connected) "已连接 · 握手中…" else "等待 Mac 连接…") }
        transport.onFrame = { channel, flags, payload -> route(channel, flags, payload) }
    }

    private fun route(channel: Int, flags: Int, payload: ByteArray) {
        when (channel) {
            Channel.CONTROL.value -> handleControl(payload)
            Channel.VIDEO.value -> onVideo?.invoke(payload, (flags and FrameFlags.KEYFRAME) != 0)
            else -> {}   // INPUT/AUDIO/STATS not received by a receiver
        }
    }

    private fun handleControl(payload: ByteArray) {
        val msg = try { JSONObject(String(payload, Charsets.UTF_8)) } catch (e: Exception) { log("bad control json: $e"); return }
        when (msg.optString("type")) {
            "hello" -> { log("received hello → sending hello_ack"); sendHelloAck() }
            "video_config" -> onVideoConfig?.invoke(
                msg.optInt("width"), msg.optInt("height"),
                msg.optString("codec", "h264"), msg.optString("hdr", "off"))
            "ping" -> sendControl(JSONObject().put("type", "pong").put("seq", msg.optInt("seq")))
            else -> {}
        }
    }

    private fun sendHelloAck() {
        val c = JSONObject()
            .put("codecs", JSONArray(caps.codecs))
            .put("pen", caps.pen)
            .put("screenWidth", caps.screenWidth)
            .put("screenHeight", caps.screenHeight)
            .put("scale", caps.scale.toDouble())
            .put("refreshRate", caps.refreshRate.toDouble())
        val ack = JSONObject()
            .put("type", "hello_ack")
            .put("role", "pad")
            .put("protocolVersion", 2)
            .put("peerId", peerId)
            .put("platform", "android")
            .put("deviceName", deviceName)
            .put("supportedRoles", JSONArray(listOf("receiver")))
            .put("acceptedRole", "receiver")
            .put("caps", c)
        sendControl(ack)
        onStatus?.invoke("已连接 · 投屏中")
    }

    private fun sendControl(obj: JSONObject) {
        transport.send(FrameCodec.encode(Channel.CONTROL, 0, obj.toString().toByteArray(Charsets.UTF_8)))
    }
}
