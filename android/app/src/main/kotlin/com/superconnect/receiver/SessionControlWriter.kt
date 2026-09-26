package com.superconnect.receiver

import com.superconnect.protocol.Channel

/** Encodes receiver CONTROL messages and consumes every payload handed to the ordered writer. */
internal class SessionControlWriter(
    private val frameWriter: OrderedFrameWriter,
    private val caps: ReceiverCaps,
    private val deviceName: String,
    private val peerId: String,
    private val frame: (Int, Int, ByteArray) -> ByteArray,
    private val failTransport: () -> Unit,
    private val log: (String) -> Unit,
) {
    fun sendEnrollment(encrypted: ByteArray, salt: ByteArray, nonce: ByteArray) {
        val payload = AuthWireNative.encode(AuthWireMessage.PairSecret(encrypted, salt, nonce))
            ?: return failTransport()
        send(payload)
    }

    fun sendHelloAck(challenge: ByteArray?, needsPairing: Boolean, ephPub: ByteArray?) {
        val payload = encodeHelloAck(challenge, needsPairing, ephPub) ?: return failTransport()
        send(payload)
    }

    fun encodeFinalHelloAck(): ByteArray? = encodeHelloAck(null, false, null)

    private fun encodeHelloAck(
        challenge: ByteArray?,
        needsPairing: Boolean,
        ephPub: ByteArray?,
    ): ByteArray? {
        val codecs = caps.codecs.fold(0) { bits, codec ->
            bits or when (codec) {
                "h264" -> SessionHelloWireNative.CODEC_H264
                "hevc" -> SessionHelloWireNative.CODEC_HEVC
                else -> 0
            }
        }
        val message = SessionHelloMessage(
            kind = SessionHelloWireNative.KIND_HELLO_ACK,
            legacyRole = "pad",
            authVersion = 1,
            recordVersion = 1,
            capabilityVersion = SessionCapabilityDriver.LEGACY_NEGOTIATION_VERSION,
            capabilityIntentVersion = SessionCapabilityDriver.INTENT_NEGOTIATION_VERSION,
            frameMetaVersion = 2,
            // Enhanced recovery anchors are deliberately outside the first free ViewOnly trial.
            // Ordinary authenticated request_keyframe remains available below.
            mediaRecoveryVersion = null,
            peerId = peerId,
            platform = "android",
            deviceName = deviceName,
            supportedRoles = setOf("receiver"),
            acceptedRole = "receiver",
            caps = SessionHelloCaps(
                codecs = codecs,
                screenWidth = caps.screenWidth,
                screenHeight = caps.screenHeight,
                scale = caps.scale.toDouble(),
                refreshRate = caps.refreshRate.toInt(),
                pen = caps.pen,
            ),
            enrollmentKey = ephPub,
            challenge = challenge,
            needsPairing = challenge?.let { needsPairing },
        )
        return SessionHelloWireNative.encode(message)
    }

    fun requestKeyframe() {
        ReceiverProgressNative.nativeEncodeKeyframeRequest(0)?.let(::send) ?: failTransport()
    }

    fun sendError(reason: Int) {
        ControlEnvelopeNative.nativeEncodeError(reason)?.let(::send)
            ?: failTransport()
    }

    fun sendSessionFatalError(reason: Int) {
        ControlEnvelopeNative.nativeEncodeSessionFatalError(reason)?.let(::send)
    }

    /** Consumes [payload]; OrderedFrameWriter must copy it before returning. */
    fun send(payload: ByteArray) {
        var frame: ByteArray? = null
        try {
            frame = frame(Channel.CONTROL.value, 0, payload)
            if (frameWriter.send(checkNotNull(frame), null, null) == null) failTransport()
        } catch (error: Throwable) {
            log("control writer rejected frame: $error")
            failTransport()
        } finally {
            frame?.fill(0)
            payload.fill(0)
        }
    }

}
