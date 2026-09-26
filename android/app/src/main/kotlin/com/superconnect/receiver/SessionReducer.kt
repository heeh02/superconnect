package com.superconnect.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong

internal data class SessionReducerEvent(
    val type: Int,
    val credentialState: Int = 0,
    val operation: Long = 0,
    val first: Long = 0,
    val second: Long = 0,
    val third: Long = 0,
    val authVersion: Int = 0,
    val flag: Boolean = false,
    val identity: ByteArray? = null,
    val generation: Long? = null,
)

internal data class SessionReducerEffect(
    val type: Int,
    val fatalReason: Int,
    val presence: Long,
    val operation: Long,
    val timerToken: Long,
    val admissionClaim: Long,
    val credential: Long,
    val candidateCredential: Long,
    val challenge: Long,
    val localChallenge: Long,
    val peerChallenge: Long,
    val proof: Long,
    val envelope: Long,
    val localEnrollmentKey: Long,
    val peerEnrollmentKey: Long,
    val authVersion: Int,
    val mediaRole: Int,
    val enrollment: Boolean,
)

internal enum class SessionReducerSide(val nativeValue: Int) { Initiator(1), Responder(2) }
internal enum class SessionReducerMediaRole(val nativeValue: Int) { Host(1), Receiver(2) }

internal data class SessionReducerSnapshot(
    val generation: Long,
    val phase: Int,
    val pendingTimers: Int,
    val pendingOperations: Int,
    val side: SessionReducerSide,
    val mediaRole: SessionReducerMediaRole,
    val recordsActive: Boolean,
)

internal data class SecureInboundFrame(
    val channel: Int,
    val flags: Int,
    val payload: ByteArray,
    val control: ControlEnvelopeEvent?,
)

/** Single-owner, fail-closed adapter. Rust alone advances session phase and allocates operation/timer IDs. */
internal class SessionReducer(
    localIdentity: ByteArray,
    trustedLocal: Boolean,
    side: SessionReducerSide = SessionReducerSide.Responder,
    mediaRole: SessionReducerMediaRole = SessionReducerMediaRole.Receiver,
    private val freeHandle: (Long) -> Unit = SessionNative::nativeFree,
) : AutoCloseable {
    val generation: Long = nextGeneration.getAndUpdate { current ->
        check(current != Long.MAX_VALUE) { "session generation exhausted" }
        current + 1
    }
    val localEnrollmentKey: Long = 1
    private var handle = SessionNative.nativeNew(
        generation = generation,
        firstOperation = 2,
        localEnrollmentKey = localEnrollmentKey,
        origin = if (trustedLocal) ORIGIN_TRUSTED else ORIGIN_MUTUAL,
        side = side.nativeValue,
        mediaRole = mediaRole.nativeValue,
        localIdentity = localIdentity,
    )

    init {
        check(handle != 0L) { "Rust session handle was not created" }
    }

    @Synchronized
    fun apply(event: SessionReducerEvent): List<SessionReducerEffect> {
        check(handle != 0L) { "session handle is closed" }
        val raw = SessionNative.nativeApply(
            handle, event.type, event.credentialState, event.generation ?: generation,
            event.operation, event.first, event.second, event.third, event.authVersion,
            event.flag, event.identity,
        )
        return decodeEffects(raw)
    }

    @Synchronized
    fun observeRecordVersion(version: Int?): List<SessionReducerEffect> {
        check(handle != 0L) { "session handle is closed" }
        return decodeEffects(SessionNative.nativeObserveRecordVersion(handle, version ?: 0))
    }

    @Synchronized
    fun recordMaterialPrepared(operation: Long, pairSecret: ByteArray?,
        responderChallenge: ByteArray?, initiatorChallenge: ByteArray?): List<SessionReducerEffect> {
        check(handle != 0L) { "session handle is closed" }
        return decodeEffects(SessionNative.nativeRecordMaterialPrepared(
            handle, operation, pairSecret, responderChallenge, initiatorChallenge))
    }

    @Synchronized
    fun recordsActivated(operation: Long, success: Boolean): List<SessionReducerEffect> {
        check(handle != 0L) { "session handle is closed" }
        return decodeEffects(SessionNative.nativeRecordsActivated(handle, operation, success))
    }

    @Synchronized
    fun drainEffects(): List<SessionReducerEffect> {
        check(handle != 0L) { "session handle is closed" }
        return decodeEffects(SessionNative.nativeDrainEffects(handle))
    }

    @Synchronized
    fun sealFrame(channel: Int, flags: Int, payload: ByteArray): ByteArray {
        check(handle != 0L) { "session handle is closed" }
        return SessionNative.nativeSealFrame(handle, channel, flags, payload)
    }

    @Synchronized
    fun push(bytes: ByteArray): List<SecureInboundFrame> {
        check(handle != 0L) { "session handle is closed" }
        val raw = SessionNative.nativePush(handle, bytes)
        val output = mutableListOf<SecureInboundFrame>()
        try {
          var offset = 0
          while (offset < raw.size) {
            check(raw.size - offset >= INBOUND_HEADER) { "invalid secure inbound header" }
            val channel = raw[offset].toInt() and 0xff
            val flags = raw[offset + 1].toInt() and 0xff
            val hasControl = raw[offset + 2].toInt() == 1
            check(raw[offset + 3].toInt() == 0)
            val length = ByteBuffer.wrap(raw, offset + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            check(length >= 0 && raw.size - offset - INBOUND_HEADER >= length)
            val controlRecord = raw.copyOfRange(offset + 8, offset + 72)
            val control = if (hasControl) ControlEnvelopeNative.decodeRecord(controlRecord) else null
            controlRecord.fill(0)
            check((channel == 0) == (control != null)) { "invalid secure CONTROL projection" }
            val payload = raw.copyOfRange(offset + INBOUND_HEADER, offset + INBOUND_HEADER + length)
            output += SecureInboundFrame(channel, flags, payload, control)
              offset += INBOUND_HEADER + length
          }
          return output
        } finally {
          raw.fill(0)
        }
    }

    private fun decodeEffects(raw: LongArray): List<SessionReducerEffect> {
        check(raw.size == 1 + MAX_EFFECTS * EFFECT_FIELDS && raw[0] in 0..MAX_EFFECTS.toLong()) {
            "invalid Rust session effect record"
        }
        return (0 until raw[0].toInt()).map { index ->
            val offset = 1 + index * EFFECT_FIELDS
            SessionReducerEffect(
                type = raw[offset].toInt(), fatalReason = raw[offset + 1].toInt(),
                presence = raw[offset + 2], operation = raw[offset + 3],
                timerToken = raw[offset + 4], admissionClaim = raw[offset + 5],
                credential = raw[offset + 6], candidateCredential = raw[offset + 7],
                challenge = raw[offset + 8], localChallenge = raw[offset + 9],
                peerChallenge = raw[offset + 10], proof = raw[offset + 11],
                envelope = raw[offset + 12], localEnrollmentKey = raw[offset + 13],
                peerEnrollmentKey = raw[offset + 14], authVersion = raw[offset + 15].toInt(),
                mediaRole = raw[offset + 16].toInt(), enrollment = raw[offset + 17] == 1L,
            )
        }
    }

    @Synchronized
    fun snapshot(): SessionReducerSnapshot {
        check(handle != 0L) { "session handle is closed" }
        val raw = SessionNative.nativeSnapshot(handle)
        check(raw.size == 7 && raw[0] == generation) { "invalid Rust session snapshot" }
        return SessionReducerSnapshot(
            generation = raw[0],
            phase = raw[1].toInt(),
            pendingTimers = raw[2].toInt(),
            pendingOperations = raw[3].toInt(),
            side = SessionReducerSide.entries.firstOrNull { it.nativeValue.toLong() == raw[4] }
                ?: error("invalid Rust session side"),
            mediaRole = SessionReducerMediaRole.entries.firstOrNull {
                it.nativeValue.toLong() == raw[5]
            } ?: error("invalid Rust session media role"),
            recordsActive = raw[6] == 1L,
        )
    }

    fun phase(): Int = snapshot().phase

    @Synchronized
    override fun close() {
        if (handle == 0L) return
        val owned = handle
        freeHandle(owned)
        handle = 0
    }

    companion object {
        const val EVENT_START = 1
        const val EVENT_TRANSPORT_OPENED = 2
        const val EVENT_PEER_HELLO_ACK = 3
        const val EVENT_PEER_HELLO = 4
        const val EVENT_CREDENTIAL_LOADED = 5
        const val EVENT_ENROLLMENT_OPENED = 6
        const val EVENT_ENROLLMENT_APPROVED = 7
        const val EVENT_ENROLLMENT_PREPARED = 8
        const val EVENT_CHALLENGE_GENERATED = 9
        const val EVENT_AUTH_PROOF_CREATED = 10
        const val EVENT_PEER_AUTH = 11
        const val EVENT_PEER_PROOF_VERIFIED = 12
        const val EVENT_ADMISSION_SUCCEEDED = 13
        const val EVENT_ADMISSION_FAILED = 14
        const val EVENT_MUTUAL_PROOF_CREATED = 15
        const val EVENT_PEER_AUTH_ACK = 16
        const val EVENT_MUTUAL_PROOF_VERIFIED = 17
        const val EVENT_CREDENTIAL_WRITE_COMPLETED = 18
        const val EVENT_FINAL_ACK_SUBMITTED = 19
        const val EVENT_CAPABILITIES_COMMITTED = 20
        const val EVENT_STREAMING_STARTED = 21
        const val EVENT_CLOSE_REQUESTED = 22
        const val EVENT_TRANSPORT_CLOSED = 23
        const val EVENT_TRANSPORT_FAILED = 24
        const val EVENT_TIMER_FIRED = 25

        const val EFFECT_OPEN_TRANSPORT = 1
        const val EFFECT_ARM_TIMER = 2
        const val EFFECT_CANCEL_TIMER = 3
        const val EFFECT_LOAD_CREDENTIAL = 5
        const val EFFECT_SEND_HELLO = 4
        const val EFFECT_OPEN_ENROLLMENT = 6
        const val EFFECT_REQUEST_ENROLLMENT = 7
        const val EFFECT_PREPARE_ENROLLMENT = 8
        const val EFFECT_GENERATE_CHALLENGE = 9
        const val EFFECT_SEND_HELLO_ACK = 10
        const val EFFECT_SEND_ENROLLMENT = 11
        const val EFFECT_CREATE_AUTH_PROOF = 12
        const val EFFECT_VERIFY_PEER_PROOF = 13
        const val EFFECT_CLAIM_ADMISSION = 14
        const val EFFECT_CREATE_MUTUAL_PROOF = 15
        const val EFFECT_SUBMIT_AUTH_ACK = 16
        const val EFFECT_SUBMIT_HELLO_ACK = 17
        const val EFFECT_SEND_AUTH = 18
        const val EFFECT_VERIFY_MUTUAL_PROOF = 19
        const val EFFECT_WRITE_CREDENTIAL = 20
        const val EFFECT_CANCEL_CREDENTIAL_WRITE = 21
        const val EFFECT_COMMIT_CAPABILITIES = 22
        const val EFFECT_NOTIFY_READY = 23
        const val EFFECT_NOTIFY_STREAMING = 24
        const val EFFECT_CLOSE_TRANSPORT = 25
        const val EFFECT_NOTIFY_CLOSED = 26
        const val EFFECT_RELEASE_ADMISSION = 27
        const val EFFECT_NOTIFY_FATAL = 28
        const val EFFECT_PREPARE_RECORD_CONTEXT = 1001
        const val EFFECT_ACTIVATE_RECORDS = 1002
        const val EFFECT_DISPOSE_RECORDS = 1003

        const val CREDENTIAL_MISSING = 1
        const val CREDENTIAL_PRESENT = 2
        const val CREDENTIAL_UNAVAILABLE = 3

        const val PHASE_HELLO = 2
        const val PHASE_MUTUAL_AUTH = 5

        private const val ORIGIN_TRUSTED = 1
        private const val ORIGIN_MUTUAL = 2
        private const val EFFECT_FIELDS = 18
        private const val MAX_EFFECTS = 10
        private const val INBOUND_HEADER = 72
        private val nextGeneration = AtomicLong(1)
    }
}
