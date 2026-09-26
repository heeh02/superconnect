package com.superconnect.receiver

enum class AdmissionEventKind {
    Accepted,
    PairingPrompt,
    Authenticated,
    Closed,
    TimedOut,
}

data class AdmissionEvent(
    val kind: AdmissionEventKind,
    val id: Int,
    val token: Long = 0,
)

enum class AdmissionActionKind {
    StartAuthTimer,
    StartPairingTimer,
    CancelTimer,
    Claim,
    RejectBusy,
    RejectCapacity,
    Close,
    PendingReleased,
    ActiveReleased,
}

data class AdmissionAction(
    val kind: AdmissionActionKind,
    val id: Int,
    val timeoutMs: Long = 0,
    val token: Long = 0,
)

data class AdmissionSnapshot(
    val activeId: Int,
    val pendingCount: Int,
    val maxPending: Int,
)

/** Single-owner adapter. Rust is authoritative for capacity, claim, timeout, and release state. */
class SessionAdmission(maxPending: Int = 4) : AutoCloseable {
    private var handle = AdmissionNative.nativeNew(maxPending)

    init {
        check(handle != 0L) { "Rust admission handle was not created" }
    }

    @Synchronized
    fun apply(event: AdmissionEvent): List<AdmissionAction> {
        check(handle != 0L) { "admission handle is closed" }
        require(event.id > 0) { "admission owner must be positive" }
        val token = when (event.kind) {
            AdmissionEventKind.TimedOut -> event.token.also {
                require(it > 0) { "timeout token must be positive" }
            }
            else -> 0L.also { require(event.token == 0L) { "unexpected admission token" } }
        }
        val raw = AdmissionNative.nativeApply(handle, event.kind.nativeValue, event.id.toLong(), token)
        check(raw.size == 1 + MAX_EFFECTS * EFFECT_FIELDS && raw[0] in 0..MAX_EFFECTS.toLong()) {
            "invalid Rust admission effect record"
        }
        val actions = (0 until raw[0].toInt()).map { index -> decode(raw, 1 + index * EFFECT_FIELDS) }
        return actions
    }

    @Synchronized
    fun activeId(): Int = snapshot().activeId

    @Synchronized
    fun snapshot(): AdmissionSnapshot {
        check(handle != 0L) { "admission handle is closed" }
        val raw = AdmissionNative.nativeSnapshot(handle)
        check(raw.size == 3 && raw[0] in 0..Int.MAX_VALUE.toLong() &&
            raw[1] in 0..Int.MAX_VALUE.toLong() && raw[2] in 1..Int.MAX_VALUE.toLong()) {
            "invalid Rust admission snapshot"
        }
        val result = AdmissionSnapshot(raw[0].toInt().takeIf { it != 0 } ?: -1,
            raw[1].toInt(), raw[2].toInt())
        return result
    }

    @Synchronized
    override fun close() {
        if (handle == 0L) return
        val owned = handle
        handle = 0
        AdmissionNative.nativeFree(owned)
    }

    private fun decode(raw: LongArray, offset: Int): AdmissionAction {
        val kind = raw[offset]
        val timerKind = raw[offset + 1]
        val owner = raw[offset + 2]
        val token = raw[offset + 3]
        val timeout = raw[offset + 4]
        check(owner in 1..Int.MAX_VALUE.toLong() && token >= 0 && timeout >= 0) {
            "invalid Rust admission effect fields"
        }
        val actionKind = when (kind) {
            EFFECT_ARM_TIMER -> when (timerKind) {
                TIMER_AUTH -> AdmissionActionKind.StartAuthTimer
                TIMER_PAIRING -> AdmissionActionKind.StartPairingTimer
                else -> error("invalid Rust admission timer kind")
            }
            EFFECT_CANCEL_TIMER -> AdmissionActionKind.CancelTimer
            EFFECT_CLAIM -> AdmissionActionKind.Claim
            EFFECT_REJECT_BUSY -> AdmissionActionKind.RejectBusy
            EFFECT_REJECT_CAPACITY -> AdmissionActionKind.RejectCapacity
            EFFECT_CLOSE -> AdmissionActionKind.Close
            EFFECT_PENDING_RELEASED -> AdmissionActionKind.PendingReleased
            EFFECT_ACTIVE_RELEASED -> AdmissionActionKind.ActiveReleased
            else -> error("unknown Rust admission effect")
        }
        return AdmissionAction(actionKind, owner.toInt(), timeout, token)
    }

    private val AdmissionEventKind.nativeValue: Int
        get() = when (this) {
            AdmissionEventKind.Accepted -> 1
            AdmissionEventKind.PairingPrompt -> 2
            AdmissionEventKind.Authenticated -> 3
            AdmissionEventKind.TimedOut -> 4
            AdmissionEventKind.Closed -> 5
        }

    private companion object {
        const val EFFECT_FIELDS = 5
        const val MAX_EFFECTS = 2
        const val EFFECT_ARM_TIMER = 1L
        const val EFFECT_CANCEL_TIMER = 2L
        const val EFFECT_CLAIM = 3L
        const val EFFECT_REJECT_BUSY = 4L
        const val EFFECT_REJECT_CAPACITY = 5L
        const val EFFECT_CLOSE = 6L
        const val EFFECT_PENDING_RELEASED = 7L
        const val EFFECT_ACTIVE_RELEASED = 8L
        const val TIMER_AUTH = 1L
        const val TIMER_PAIRING = 2L
    }
}
