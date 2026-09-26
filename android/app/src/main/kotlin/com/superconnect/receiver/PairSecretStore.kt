package com.superconnect.receiver

internal enum class PairSecretWriteResult { Inserted, Unchanged, Conflict, Unavailable }

/** Secure-store contract shared by responder and Standard initiator session effect drivers. */
internal interface PairSecretStore {
    /** Returns a caller-owned plaintext copy. The caller must overwrite it after its final use. */
    fun secret(peerId: String): ByteArray?

    /** Borrows [secret] for this synchronous call; ownership remains with the caller. */
    fun storeIfAbsent(secret: ByteArray, peerId: String): PairSecretWriteResult
    fun remove(peerId: String)
}
