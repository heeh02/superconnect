package com.superconnect.receiver

/** Owns the one media authorization emitted by a Session generation. */
internal class SessionAuthorizationLifecycle(
    private val generation: () -> Long,
    private val notify: (authorized: Boolean, generation: Long) -> Unit,
) {
    private var authorizedGeneration = 0L

    @Synchronized
    fun ready(): Boolean {
        val current = generation()
        require(current > 0) { "session generation must be positive" }
        if (authorizedGeneration == current) return false
        check(authorizedGeneration == 0L) { "session authorization replaced without termination" }
        authorizedGeneration = current
        notify(true, current)
        return true
    }

    fun revokeForTerminalEffect(effectType: Int): Boolean {
        require(
            effectType == SessionReducer.EFFECT_CLOSE_TRANSPORT ||
                effectType == SessionReducer.EFFECT_NOTIFY_FATAL,
        ) { "effect is not a media terminal boundary: $effectType" }
        return revoke()
    }

    fun dispose(): Boolean = revoke()

    @Synchronized
    private fun revoke(): Boolean {
        val owned = authorizedGeneration
        if (owned == 0L) return false
        authorizedGeneration = 0L
        notify(false, owned)
        return true
    }
}

/** Separates immediate media revocation from the later request to drain and close the transport. */
internal class SessionTerminalMediaBridge(
    private val authorization: SessionAuthorizationLifecycle,
    private val closeTransportAfterWrites: () -> Unit,
) {
    private var transportCloseRequested = false

    fun revokeFor(effectType: Int): Boolean =
        authorization.revokeForTerminalEffect(effectType)

    @Synchronized
    fun requestTransportCloseAfterEffects(): Boolean {
        if (transportCloseRequested) return false
        transportCloseRequested = true
        closeTransportAfterWrites()
        return true
    }
}

/** Routes a Session callback only while its peer still owns the host admission slot. */
internal class ActiveSessionAuthorizationRouter(
    private val activeOwnerId: () -> Int,
    private val downstream: (authorized: Boolean, generation: Long) -> Unit,
) {
    fun route(ownerId: Int, authorized: Boolean, generation: Long) {
        if (authorized || activeOwnerId() == ownerId) downstream(authorized, generation)
    }
}
