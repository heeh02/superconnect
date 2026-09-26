package com.superconnect.receiver

import com.superconnect.protocol.Channel
import com.superconnect.protocol.FrameFlags
import com.superconnect.protocol.VideoFrameMeta

/** Owns decoded frame payloads until a typed route explicitly transfers the exact array. */
internal class SessionFrameRouter(
    private val isReady: () -> Boolean,
    private val videoConsumer: () -> ((ReceivedVideoAccessUnit) -> Boolean)?,
    private val videoConfigConsumer: () ->
        ((width: Int, height: Int, codec: String, hdr: String, lowLatency: Boolean) -> Unit)?,
    private val streamingStarted: () -> Unit,
    private val sendControl: (ByteArray) -> Unit,
    private val closeRequested: () -> Unit,
    private val authReceived: (AuthWireMessage.Auth) -> Unit,
    private val helloReceived: (SessionHelloMessage) -> Unit,
    private val receiveCapability: (ByteArray) -> Unit,
    private val receiveIntentProfile: (ByteArray) -> Unit,
    private val receiveIntent: (ByteArray) -> Unit,
    private val failTransport: () -> Unit,
    private val log: (String) -> Unit,
) : AutoCloseable {
    /** True only when the exact [payload] array moved to an asynchronous video consumer. */
    fun route(frame: SecureInboundFrame): Boolean = when (frame.channel) {
        Channel.CONTROL.value -> {
            val envelope = frame.control ?: run { failTransport(); return false }
            handleControl(frame.payload, envelope)
            false
        }
        Channel.VIDEO.value -> if (isReady()) {
            streamingStarted()
            routeVideo(frame.flags, frame.payload)
        } else {
            false
        }
        else -> {
            // ViewOnly Receiver accepts no INPUT/AUDIO/STATS application channel.
            failTransport()
            false
        }
    }

    private fun routeVideo(flags: Int, payload: ByteArray): Boolean {
        val parsed = VideoFrameMeta.parse(payload)
        if (VideoFrameMeta.hasMagic(payload) && parsed == null) {
            log("malformed SM video metadata → drop")
            return false
        }
        val videoPayload = parsed?.payload ?: payload
        val consumer = videoConsumer()
        if (consumer == null) {
            if (parsed != null) videoPayload.fill(0)
            return false
        }
        var childTransferred = false
        try {
            childTransferred = consumer(
                ReceivedVideoAccessUnit(
                    payload = videoPayload,
                    isKeyframe = parsed?.fields?.isKeyframe
                        ?: ((flags and FrameFlags.KEYFRAME) != 0),
                    sourceFrameId = parsed?.fields?.sourceFrameId ?: 0,
                    streamEpoch = parsed?.fields?.streamEpoch ?: 0,
                ),
            )
        } finally {
            if (parsed != null && !childTransferred) videoPayload.fill(0)
        }
        return parsed == null && childTransferred
    }

    private fun handleControl(payload: ByteArray, envelope: ControlEnvelopeEvent) {
        when (envelope.kind) {
            ControlEnvelopeKind.Ping, ControlEnvelopeKind.Pong, ControlEnvelopeKind.Bye -> {
            val sessionControl = SessionControlNative.nativeDecode(payload) ?: return failTransport()
            try {
                when (sessionControl[0].toInt()) {
                    SessionControlNative.KIND_PING -> SessionControlNative.nativeEncode(
                        SessionControlNative.KIND_PONG,
                        sessionControl[1].toInt() or SessionControlNative.FIELD_T1,
                        sessionControl[2],
                        sessionControl[3],
                        (System.nanoTime() / 1_000).coerceAtLeast(1),
                        0,
                    )?.let(sendControl) ?: failTransport()
                    SessionControlNative.KIND_BYE -> closeRequested()
                    else -> failTransport()
                }
            } finally {
                sessionControl.fill(0)
            }
            return
        }
            ControlEnvelopeKind.Auth, ControlEnvelopeKind.AuthAck, ControlEnvelopeKind.PairSecret -> {
            val auth = AuthWireNative.decode(payload) ?: return failTransport()
            try {
                if (auth is AuthWireMessage.Auth) authReceived(auth) else failTransport()
            } finally {
                auth.zeroize()
            }
            return
        }
            ControlEnvelopeKind.Hello, ControlEnvelopeKind.HelloAck -> {
            val hello = SessionHelloWireNative.decode(payload) ?: return failTransport()
            try {
                if (hello.kind == SessionHelloWireNative.KIND_HELLO) helloReceived(hello)
                else failTransport()
            } finally {
                hello.zeroizeSensitive()
            }
            return
        }
            ControlEnvelopeKind.RecoveryAnchor -> {
            // Not negotiated by the FOSS composition; never silently activate optional recovery.
            failTransport()
            return
        }
            ControlEnvelopeKind.VideoConfig -> {
            val config = VideoConfigWireNative.decode(payload) ?: return failTransport()
            routeVideoConfig(config)
            return
        }
            ControlEnvelopeKind.Capability -> receiveCapability(payload)
            ControlEnvelopeKind.CapabilityIntentProfileV2 -> receiveIntentProfile(payload)
            ControlEnvelopeKind.CapabilityIntentV2 -> receiveIntent(payload)
            else -> failTransport()
        }
    }

    internal fun routeVideoConfig(config: CanonicalVideoConfig) {
        if (!isReady()) return
        videoConfigConsumer()?.invoke(
            config.width,
            config.height,
            config.codec,
            "off",
            config.lowLatency,
        )
    }

    override fun close() {
        // ScSecureConnection owns and resets the only frame decoder.
    }
}
