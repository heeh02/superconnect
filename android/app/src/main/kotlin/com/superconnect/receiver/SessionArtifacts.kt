package com.superconnect.receiver

/** Sole owner of every reducer-addressable Kotlin authentication buffer. */
internal class SessionArtifactOwner {
    sealed interface Artifact {
        class SensitiveBytes(val value: ByteArray) : Artifact
        class EnrollmentKey(val privateKey: ByteArray, val publicKey: ByteArray) : Artifact
        class PairEnvelope(
            val encrypted: ByteArray,
            val salt: ByteArray,
            val nonce: ByteArray,
        ) : Artifact
    }

    private val values = mutableMapOf<Long, Artifact>()
    private var next = 100L

    fun takeBytes(value: ByteArray): Long = put(Artifact.SensitiveBytes(value))

    fun putCopy(value: ByteArray): Long = takeBytes(value.copyOf())

    fun takeEnrollmentKey(id: Long, privateKey: ByteArray, publicKey: ByteArray) {
        if (id <= 0 || values.containsKey(id)) {
            privateKey.fill(0)
            publicKey.fill(0)
            error("duplicate enrollment key artifact")
        }
        values[id] = Artifact.EnrollmentKey(privateKey, publicKey)
    }

    fun takeEnvelope(encrypted: ByteArray, salt: ByteArray, nonce: ByteArray): Long =
        put(Artifact.PairEnvelope(encrypted, salt, nonce))

    fun borrowBytes(id: Long): ByteArray? = (values[id] as? Artifact.SensitiveBytes)?.value

    fun borrowEnrollmentKey(id: Long): Artifact.EnrollmentKey? =
        values[id] as? Artifact.EnrollmentKey

    fun borrowEnvelope(id: Long): Artifact.PairEnvelope? = values[id] as? Artifact.PairEnvelope

    fun clear() {
        values.values.forEach { it.zeroize() }
        values.clear()
    }

    fun size(): Int = values.size

    private fun put(value: Artifact): Long {
        if (next == Long.MAX_VALUE) {
            value.zeroize()
            error("artifact identifier exhausted")
        }
        val id = next++
        values[id] = value
        return id
    }

    private fun Artifact.zeroize() {
        when (this) {
            is Artifact.SensitiveBytes -> value.fill(0)
            is Artifact.EnrollmentKey -> {
                privateKey.fill(0)
                publicKey.fill(0)
            }
            is Artifact.PairEnvelope -> {
                encrypted.fill(0)
                salt.fill(0)
                nonce.fill(0)
            }
        }
    }
}
