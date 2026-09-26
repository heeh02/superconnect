package com.superconnect.receiver

import java.util.ArrayDeque

/** Single active media generation. A stale terminal callback cannot clear its replacement. */
internal class ReceiverGenerationFence {
    @Volatile private var activeGeneration = 0L

    fun current(): Long = activeGeneration

    fun isActive(generation: Long): Boolean = generation > 0 && activeGeneration == generation

    @Synchronized
    fun activate(generation: Long): Boolean {
        require(generation > 0) { "media generation must be positive" }
        if (activeGeneration == generation) return false
        activeGeneration = generation
        return true
    }

    @Synchronized
    fun terminate(generation: Long): Boolean {
        if (!isActive(generation)) return false
        activeGeneration = 0
        return true
    }
}

/** The UI/decoder-facing owner for authorization callbacks from the active Session generation. */
internal class ReceiverMediaAuthorizationOwner(
    private val ownershipLock: Any,
    private val activated: (generation: Long) -> (() -> Unit),
    private val terminated: (generation: Long) -> (() -> Unit),
) {
    private val fence = ReceiverGenerationFence()

    fun current(): Long = fence.current()

    fun isActive(generation: Long): Boolean = fence.isActive(generation)

    fun onAuthorized(authorized: Boolean, generation: Long): Boolean {
        val complete = synchronized(ownershipLock) {
            val changed = if (authorized) fence.activate(generation) else fence.terminate(generation)
            if (!changed) return false
            if (authorized) activated(generation) else terminated(generation)
        }
        complete()
        return true
    }
}

/** Owns access-unit arrays accepted by one decoder generation and wipes every retired byte. */
internal class GenerationBoundAccessUnitQueue(
    private val maximum: Int,
) {
    private val lock = Object()
    private val frames = ArrayDeque<ByteArray>()

    init {
        require(maximum > 0)
    }

    /** Returns true only when this queue takes ownership of [frame]. */
    fun offer(frame: ByteArray, accepts: () -> Boolean): Boolean = synchronized(lock) {
        if (!accepts()) return@synchronized false
        while (frames.size >= maximum) frames.removeFirst().fill(0)
        frames.addLast(frame)
        lock.notifyAll()
        true
    }

    fun take(timeoutMs: Long, accepts: () -> Boolean): ByteArray? = synchronized(lock) {
        if (!accepts()) {
            wipeLocked()
            return@synchronized null
        }
        if (frames.isEmpty() && timeoutMs > 0) {
            try {
                lock.wait(timeoutMs)
            } catch (_: InterruptedException) {
                // The caller re-checks ownership below.
            }
        }
        if (!accepts()) {
            wipeLocked()
            return@synchronized null
        }
        if (frames.isEmpty()) null else frames.removeFirst()
    }

    fun wipe() = synchronized(lock) {
        wipeLocked()
        lock.notifyAll()
    }

    internal fun pendingForTesting(): Int = synchronized(lock) { frames.size }

    private fun wipeLocked() {
        while (frames.isNotEmpty()) frames.removeFirst().fill(0)
    }
}
