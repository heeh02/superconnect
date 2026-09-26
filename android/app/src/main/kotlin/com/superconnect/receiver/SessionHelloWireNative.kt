package com.superconnect.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal data class SessionHelloCaps(
    val codecs: Int = SessionHelloWireNative.CODEC_H264,
    val maxWidth: Int? = null, val maxHeight: Int? = null,
    val screenWidth: Int? = null, val screenHeight: Int? = null,
    val scale: Double? = null, val refreshRate: Int? = null, val refreshRateMax: Int? = null,
    val hidpi: Boolean? = null, val pen: Boolean? = null,
    val hdrHlg: Boolean? = null, val hdrPq: Boolean? = null,
)

internal data class SessionHelloMessage(
    val kind: Int, val legacyRole: String, val protocolVersion: Int = 2,
    val authVersion: Int? = null, val recordVersion: Int? = null,
    val capabilityVersion: Int? = null, val capabilityIntentVersion: Int? = null,
    val frameMetaVersion: Int? = null, val mediaRecoveryVersion: Int? = null,
    val udpVideoVersion: Int? = null, val udpVideoPort: Int? = null,
    val peerId: String, val platform: String? = null, val deviceName: String? = null,
    val appVersion: String? = null, val pairingToken: String? = null,
    val supportedRoles: Set<String> = emptySet(),
    val desiredRole: String? = null, val acceptedRole: String? = null,
    val projectionMode: String? = null, val caps: SessionHelloCaps? = null,
    val enrollmentKey: ByteArray? = null, val challenge: ByteArray? = null,
    val needsPairing: Boolean? = null,
)

internal fun SessionHelloMessage.zeroizeSensitive() {
    enrollmentKey?.fill(0)
    challenge?.fill(0)
}

internal object SessionHelloWireNative {
    const val KIND_HELLO = 1
    const val KIND_HELLO_ACK = 2
    const val CODEC_H264 = 1
    const val CODEC_HEVC = 2
    private const val RECORD_SIZE = 1008
    private const val ROLE_SOURCE = 1
    private const val ROLE_RECEIVER = 2
    private const val FIELD_CAPS = 1L
    private const val FIELD_KEY = 2L
    private const val FIELD_CHALLENGE = 4L
    private const val FIELD_PAIRING = 8L
    private const val CAP_MAX_WIDTH = 1
    private const val CAP_MAX_HEIGHT = 2
    private const val CAP_SCREEN_WIDTH = 4
    private const val CAP_SCREEN_HEIGHT = 8
    private const val CAP_SCALE = 16
    private const val CAP_REFRESH = 32
    private const val CAP_REFRESH_MAX = 64
    private const val CAP_HIDPI = 128
    private const val CAP_PEN = 256
    private const val CAP_HDR_HLG = 512
    private const val CAP_HDR_PQ = 1024
    private const val VALUE_HIDPI = 1
    private const val VALUE_PEN = 2
    private const val VALUE_HDR_HLG = 4
    private const val VALUE_HDR_PQ = 8

    external fun nativeEncode(record: ByteArray): ByteArray?
    external fun nativeDecode(source: ByteArray): ByteArray?

    fun encode(message: SessionHelloMessage): ByteArray? {
        val bytes = record(message)
        return try { nativeEncode(bytes) } finally { bytes.fill(0) }
    }

    fun decode(source: ByteArray): SessionHelloMessage? {
        val bytes = nativeDecode(source) ?: return null
        var key: ByteArray? = null
        var challenge: ByteArray? = null
        var transferred = false
        return try {
            if (bytes.size != RECORD_SIZE) return null
            val value = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            if (value.int != RECORD_SIZE || value.int != 1) return null
            val kind = value.int; val supported = value.int; val presence = value.long
            val protocol = u16(value); val auth = optional(u16(value)); val record = optional(u16(value))
            val capability = optional(u16(value)); val intent = optional(u16(value)); val frame = optional(u16(value))
            val recovery = optional(u16(value)); val udp = optional(u16(value)); val port = optional(u16(value))
            if (u16(value) != 0) return null
            val desired = role(value.int); val accepted = role(value.int); val projection = projection(value.int)
            val codecs = value.int; val capsPresence = value.int; val capsValues = value.int
            val maxWidth = value.int; val maxHeight = value.int; val screenWidth = value.int; val screenHeight = value.int
            val refresh = value.int; val refreshMax = value.int
            if (value.int != 0) return null
            val scale = value.double
            val legacyRole = readText(value) ?: return null; val peerId = readText(value) ?: return null
            val platform = readText(value); val deviceName = readText(value); val appVersion = readText(value)
            val pairingToken = readText(value)
            key = ByteArray(65).also(value::get); challenge = ByteArray(32).also(value::get)
            val pairing = value.get().toInt(); value.position(value.position() + 6)
            if (value.long != 0L) return null
            val caps = if (presence and FIELD_CAPS != 0L) SessionHelloCaps(
                codecs, cap(capsPresence, CAP_MAX_WIDTH, maxWidth), cap(capsPresence, CAP_MAX_HEIGHT, maxHeight),
                cap(capsPresence, CAP_SCREEN_WIDTH, screenWidth), cap(capsPresence, CAP_SCREEN_HEIGHT, screenHeight),
                if (capsPresence and CAP_SCALE != 0) scale else null,
                cap(capsPresence, CAP_REFRESH, refresh), cap(capsPresence, CAP_REFRESH_MAX, refreshMax),
                flag(capsPresence, CAP_HIDPI, capsValues, VALUE_HIDPI), flag(capsPresence, CAP_PEN, capsValues, VALUE_PEN),
                flag(capsPresence, CAP_HDR_HLG, capsValues, VALUE_HDR_HLG), flag(capsPresence, CAP_HDR_PQ, capsValues, VALUE_HDR_PQ),
            ) else null
            val returnedKey = if (presence and FIELD_KEY != 0L) key else null
            val returnedChallenge = if (presence and FIELD_CHALLENGE != 0L) challenge else null
            if (returnedKey == null) key.fill(0)
            if (returnedChallenge == null) challenge.fill(0)
            val result = SessionHelloMessage(kind, legacyRole, protocol, auth, record, capability, intent, frame,
                recovery, udp, port, peerId, platform, deviceName, appVersion, pairingToken,
                roles(supported), desired, accepted, projection, caps, returnedKey, returnedChallenge,
                if (presence and FIELD_PAIRING != 0L) pairing == 1 else null)
            transferred = true
            result
        } finally {
            bytes.fill(0)
            if (!transferred) {
                key?.fill(0)
                challenge?.fill(0)
            }
        }
    }

    private fun record(message: SessionHelloMessage): ByteArray {
        val value = ByteBuffer.allocate(RECORD_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        value.putInt(RECORD_SIZE).putInt(1).putInt(message.kind).putInt(roleBits(message.supportedRoles))
        var presence = 0L
        if (message.caps != null) presence = presence or FIELD_CAPS
        if (message.enrollmentKey != null) presence = presence or FIELD_KEY
        if (message.challenge != null) presence = presence or FIELD_CHALLENGE
        if (message.needsPairing != null) presence = presence or FIELD_PAIRING
        value.putLong(presence)
        put16(value, message.protocolVersion); put16(value, message.authVersion); put16(value, message.recordVersion)
        put16(value, message.capabilityVersion); put16(value, message.capabilityIntentVersion)
        put16(value, message.frameMetaVersion); put16(value, message.mediaRecoveryVersion)
        put16(value, message.udpVideoVersion); put16(value, message.udpVideoPort); put16(value, 0)
        value.putInt(role(message.desiredRole)).putInt(role(message.acceptedRole)).putInt(projection(message.projectionMode))
        val caps = message.caps
        value.putInt(caps?.codecs ?: 0)
        val capsPresenceOffset = value.position(); value.putInt(0)
        val capsValuesOffset = value.position(); value.putInt(0)
        var capPresence = 0; var capValues = 0
        fun number(bit: Int, item: Int?) { if (item != null) { capPresence = capPresence or bit; value.putInt(item) } else value.putInt(0) }
        number(CAP_MAX_WIDTH, caps?.maxWidth); number(CAP_MAX_HEIGHT, caps?.maxHeight)
        number(CAP_SCREEN_WIDTH, caps?.screenWidth); number(CAP_SCREEN_HEIGHT, caps?.screenHeight)
        number(CAP_REFRESH, caps?.refreshRate); number(CAP_REFRESH_MAX, caps?.refreshRateMax)
        value.putInt(0)
        if (caps?.scale != null) capPresence = capPresence or CAP_SCALE
        value.putDouble(caps?.scale ?: 0.0)
        fun bool(bit: Int, valueBit: Int, item: Boolean?) { if (item != null) { capPresence = capPresence or bit; if (item) capValues = capValues or valueBit } }
        bool(CAP_HIDPI, VALUE_HIDPI, caps?.hidpi); bool(CAP_PEN, VALUE_PEN, caps?.pen)
        bool(CAP_HDR_HLG, VALUE_HDR_HLG, caps?.hdrHlg); bool(CAP_HDR_PQ, VALUE_HDR_PQ, caps?.hdrPq)
        value.putInt(capsPresenceOffset, capPresence); value.putInt(capsValuesOffset, capValues)
        putText(value, message.legacyRole); putText(value, message.peerId); putText(value, message.platform)
        putText(value, message.deviceName); putText(value, message.appVersion); putText(value, message.pairingToken)
        putFixed(value, message.enrollmentKey, 65); putFixed(value, message.challenge, 32)
        value.put(if (message.needsPairing == true) 1 else 0); repeat(6) { value.put(0) }; value.putLong(0)
        return value.array()
    }

    private fun u16(value: ByteBuffer): Int = value.short.toInt() and 0xffff
    private fun optional(value: Int): Int? = value.takeIf { it != 0 }
    private fun put16(value: ByteBuffer, item: Int?) { value.putShort((item ?: 0).toShort()) }
    private fun role(value: String?): Int = when (value) { "host", "source" -> ROLE_SOURCE; "receiver", "sink" -> ROLE_RECEIVER; else -> 0 }
    private fun role(value: Int): String? = when (value) { ROLE_SOURCE -> "host"; ROLE_RECEIVER -> "receiver"; else -> null }
    private fun roles(value: Int): Set<String> = buildSet { if (value and ROLE_SOURCE != 0) add("host"); if (value and ROLE_RECEIVER != 0) add("receiver") }
    private fun roleBits(value: Set<String>): Int = value.fold(0) { bits, item -> bits or role(item) }
    private fun projection(value: String?): Int = when (value) { "extend" -> 1; "mirror" -> 2; "primary" -> 3; else -> 0 }
    private fun projection(value: Int): String? = when (value) { 1 -> "extend"; 2 -> "mirror"; 3 -> "primary"; else -> null }
    private fun cap(presence: Int, bit: Int, value: Int): Int? = value.takeIf { presence and bit != 0 }
    private fun flag(presence: Int, bit: Int, values: Int, valueBit: Int): Boolean? = if (presence and bit != 0) values and valueBit != 0 else null
    private fun putText(value: ByteBuffer, text: String?) {
        val bytes = text?.toByteArray(Charsets.UTF_8) ?: byteArrayOf()
        try {
            require(bytes.size <= 128)
            value.putInt(bytes.size).put(bytes)
            repeat(128 - bytes.size) { value.put(0) }
        } finally {
            bytes.fill(0)
        }
    }
    private fun readText(value: ByteBuffer): String? {
        val size = value.int
        if (size !in 0..128) return null
        val bytes = ByteArray(128).also(value::get)
        return try {
            if (size == 0) null else String(bytes, 0, size, Charsets.UTF_8)
        } finally {
            bytes.fill(0)
        }
    }
    private fun putFixed(value: ByteBuffer, input: ByteArray?, size: Int) { require(input == null || input.size == size); value.put(input ?: ByteArray(size)) }

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
    }
}
