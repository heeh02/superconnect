package com.superconnect.receiver

import java.nio.ByteBuffer
import java.nio.ByteOrder

internal sealed interface AuthWireMessage {
    data class Auth(val proof: ByteArray, val challenge: ByteArray) : AuthWireMessage
    data class AuthAck(val proof: ByteArray) : AuthWireMessage
    data class PairSecret(
        val sealedSecret: ByteArray,
        val pairingSalt: ByteArray,
        val aeadNonce: ByteArray,
    ) : AuthWireMessage
}

internal fun AuthWireMessage.zeroize() = when (this) {
    is AuthWireMessage.Auth -> { proof.fill(0); challenge.fill(0) }
    is AuthWireMessage.AuthAck -> proof.fill(0)
    is AuthWireMessage.PairSecret -> { sealedSecret.fill(0); pairingSalt.fill(0); aeadNonce.fill(0) }
}

internal object AuthWireNative {
    private const val RECORD_SIZE = 160
    private const val KIND_AUTH = 1
    private const val KIND_AUTH_ACK = 2
    private const val KIND_PAIR_SECRET = 3
    private external fun nativeEncodeWire(record: ByteArray): ByteArray?
    private external fun nativeDecodeWire(source: ByteArray): ByteArray?

    fun encode(value: AuthWireMessage): ByteArray? {
        val record = ByteBuffer.allocate(RECORD_SIZE).order(ByteOrder.nativeOrder())
        return try {
            record.putInt(RECORD_SIZE).putInt(1)
            when (value) {
                is AuthWireMessage.Auth -> {
                    if (value.proof.size != 32 || value.challenge.size != 32) return null
                    record.put(KIND_AUTH.toByte()).position(16)
                    record.put(value.proof).put(value.challenge)
                }
                is AuthWireMessage.AuthAck -> {
                    if (value.proof.size != 32) return null
                    record.put(KIND_AUTH_ACK.toByte()).position(16)
                    record.put(value.proof)
                }
                is AuthWireMessage.PairSecret -> {
                    if (value.sealedSecret.size != 48 || value.pairingSalt.size != 16 ||
                        value.aeadNonce.size != 12) return null
                    record.put(KIND_PAIR_SECRET.toByte()).position(80)
                    record.put(value.sealedSecret).put(value.pairingSalt).put(value.aeadNonce)
                }
            }
            nativeEncodeWire(record.array())
        } finally {
            record.array().fill(0)
        }
    }

    fun decode(source: ByteArray): AuthWireMessage? {
        val bytes = nativeDecodeWire(source) ?: return null
        return try {
            if (bytes.size != RECORD_SIZE) return null
            val record = ByteBuffer.wrap(bytes).order(ByteOrder.nativeOrder())
            if (record.int != RECORD_SIZE || record.int != 1) return null
            when (record.get().toInt()) {
                KIND_AUTH -> AuthWireMessage.Auth(bytes.copyOfRange(16, 48), bytes.copyOfRange(48, 80))
                KIND_AUTH_ACK -> AuthWireMessage.AuthAck(bytes.copyOfRange(16, 48))
                KIND_PAIR_SECRET -> AuthWireMessage.PairSecret(
                    bytes.copyOfRange(80, 128), bytes.copyOfRange(128, 144), bytes.copyOfRange(144, 156))
                else -> null
            }
        } finally {
            bytes.fill(0)
        }
    }

    init {
        val explicit = System.getProperty("superconnect.wire.library")
        if (explicit.isNullOrBlank()) System.loadLibrary("superconnect_wire") else System.load(explicit)
    }
}
