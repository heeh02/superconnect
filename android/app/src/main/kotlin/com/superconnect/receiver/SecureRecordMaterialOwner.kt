package com.superconnect.receiver

/** The only JVM owner for secret/challenge copies between auth effects and Rust Record preparation. */
internal class SecureRecordMaterialOwner : AutoCloseable {
    private var pairSecret: ByteArray? = null
    private var responderChallenge: ByteArray? = null
    private var initiatorChallenge: ByteArray? = null

    fun captureResponder(value: ByteArray?) {
        responderChallenge?.fill(0)
        responderChallenge = value?.copyOf()
    }

    fun captureMutual(secret: ByteArray, initiator: ByteArray) {
        pairSecret?.fill(0)
        initiatorChallenge?.fill(0)
        pairSecret = secret.copyOf()
        initiatorChallenge = initiator.copyOf()
    }

    fun captureInitiator(secret: ByteArray, responder: ByteArray, initiator: ByteArray) {
        close()
        pairSecret = secret.copyOf()
        responderChallenge = responder.copyOf()
        initiatorChallenge = initiator.copyOf()
    }

    fun prepare(reducer: SessionReducer, operation: Long): List<SessionReducerEffect> {
        val secret = pairSecret
        val responder = responderChallenge
        val initiator = initiatorChallenge
        pairSecret = null
        responderChallenge = null
        initiatorChallenge = null
        return try {
            reducer.recordMaterialPrepared(operation, secret, responder, initiator)
        } finally {
            secret?.fill(0); responder?.fill(0); initiator?.fill(0)
        }
    }

    override fun close() {
        pairSecret?.fill(0); responderChallenge?.fill(0); initiatorChallenge?.fill(0)
        pairSecret = null; responderChallenge = null; initiatorChallenge = null
    }
}
