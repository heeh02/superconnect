package com.superconnect.receiver

internal fun Session.TrustDecision.zeroizeSensitive() {
    when (this) {
        is Session.TrustDecision.Steady -> secret.fill(0)
        is Session.TrustDecision.Enroll -> {
            secret.fill(0)
            tabletEphPriv.fill(0)
            tabletEphPub.fill(0)
        }
        Session.TrustDecision.Reject -> Unit
    }
}

/** Dismisses best-effort, then transfers [decision]; failed transfer always overwrites it. */
internal fun deliverTrustDecision(
    decision: Session.TrustDecision,
    dismiss: (() -> Unit)?,
    resolve: (Session.TrustDecision) -> Unit,
    log: (String) -> Unit = {},
) {
    try {
        try {
            dismiss?.invoke()
        } catch (error: Throwable) {
            log("pairing dismiss callback failed: $error")
        }
        resolve(decision)
    } catch (error: Throwable) {
        decision.zeroizeSensitive()
        log("pairing resolver failed: $error")
    }
}

/** Creates one enrollment decision transactionally; failure before transfer overwrites every mint. */
internal fun mintEnrollmentDecision(
    peerId: String,
    newSecret: () -> ByteArray,
    newKeyPair: () -> Pair<ByteArray, ByteArray>,
    persist: (secret: ByteArray, peerId: String) -> Boolean,
): Session.TrustDecision.Enroll {
    var secret: ByteArray? = null
    var privateKey: ByteArray? = null
    var publicKey: ByteArray? = null
    var transferred = false
    return try {
        secret = newSecret()
        val pair = newKeyPair()
        privateKey = pair.first
        publicKey = pair.second
        val ownedSecret = checkNotNull(secret)
        val ownedPrivateKey = checkNotNull(privateKey)
        val ownedPublicKey = checkNotNull(publicKey)
        check(ownedSecret.size == 32 && ownedPrivateKey.size == 32 && ownedPublicKey.size == 65) {
            "invalid enrollment material"
        }
        val decision = Session.TrustDecision.Enroll(
            ownedSecret,
            ownedPrivateKey,
            ownedPublicKey,
        ) { persist(ownedSecret, peerId) }
        transferred = true
        decision
    } finally {
        if (!transferred) {
            secret?.fill(0)
            privateKey?.fill(0)
            publicKey?.fill(0)
        }
    }
}
