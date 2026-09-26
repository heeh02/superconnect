package com.superconnect.receiver


/** Strict JSON/transport/effect adapter. Rust alone resolves and advances either negotiation. */
internal class SessionCapabilityDriver(
    private val legacyGeneration: Long,
    private val authorizedCapabilities: Long,
    private val productProfileV2: ProductCapabilityProfileV2,
    private val sendControl: (ByteArray) -> Unit,
    private val complete: (operation: Long, success: Boolean) -> Unit,
    private val committed: (projection: Int) -> Unit = {},
    private val fatal: () -> Unit,
    private val log: (String) -> Unit,
) : AutoCloseable {
    private var peerVersion: Int? = null
    private var intentV2 = false
    private var helloObserved = false
    private var commitOperation = 0L
    private var failed = false

    private var legacy: CapabilityNegotiation? = null
    private var pendingLegacyEnvelope: ByteArray? = null

    private var peerProfileV2: CapabilityIntentProfileV2PeerAdvertisement? = null
    private var intentGeneration = 0L
    private var localProfileSent = false
    private var offerReceived = false
    private var intentCommitted = false
    private var intentResolved: IntentV2Resolved? = null
    private var intent: CapabilityIntentV2Reducer? = null

    internal fun resolvedIntent(): IntentV2Resolved? =
        intentResolved?.takeIf { intentCommitted && !failed }

    fun observeHello(value: SessionHelloMessage): Boolean {
        if (helloObserved || failed) return false
        helloObserved = true
        peerVersion = value.capabilityVersion
        intentV2 = value.capabilityIntentVersion == INTENT_NEGOTIATION_VERSION
        return true
    }

    fun begin(operation: Long) {
        if (!helloObserved || operation == 0L || commitOperation != 0L || failed) {
            failClosed()
            return
        }
        commitOperation = operation
        if (intentV2) {
            if (peerProfileV2 != null) publishLocalProfile()
            return
        }
        beginLegacy()
    }

    /** The legacy v1 envelope remains active only when intent v2 was missing or not exactly 2. */
    fun receiveControl(source: ByteArray) {
        if (intentV2 || failed) {
            failClosed()
            return
        }
        if (legacy == null && commitOperation == 0L) {
            if (pendingLegacyEnvelope == null) pendingLegacyEnvelope = source.copyOf() else failClosed()
            return
        }
        receiveLegacyEnvelope(source)
    }

    fun receiveIntentProfile(source: ByteArray) {
        if (!intentV2 || failed || peerProfileV2 != null || offerReceived) {
            failClosed()
            return
        }
        val profile = CapabilityIntentV2Native.decodeProfileWire(source)
        val generation = profile?.generation
        if (profile == null || generation == null || generation == 0L ||
            profile.senderRole != IntentV2Role.Source) {
            failClosed()
            return
        }
        peerProfileV2 = profile
        intentGeneration = generation
        if (commitOperation != 0L) publishLocalProfile()
    }

    fun receiveIntent(source: ByteArray) {
        if (!intentV2 || failed || commitOperation == 0L || !localProfileSent) {
            failClosed()
            return
        }
        val message = CapabilityIntentV2Native.decodeWire(source) ?: run {
            failClosed()
            return
        }
        if (message.generation != intentGeneration) {
            failClosed()
            return
        }
        when {
            !offerReceived && message.kind == CapabilityIntentV2WireKind.Offer -> startIntent(message)
            offerReceived && message.kind == CapabilityIntentV2WireKind.Commit -> applyIntent(message)
            else -> failClosed()
        }
    }

    private fun beginLegacy() {
        val version = peerVersion
        if (version == null || version != LEGACY_NEGOTIATION_VERSION) {
            try {
                legacy = CapabilityNegotiation(
                    legacyGeneration, authorizedCapabilities, CapabilityProjection.Extend,
                )
                executeLegacy(legacy?.peerHello(version).orEmpty())
            } catch (_: Exception) {
                failClosed()
            }
            return
        }
        pendingLegacyEnvelope?.let {
            pendingLegacyEnvelope = null
            receiveLegacyEnvelope(it)
        }
    }

    private fun receiveLegacyEnvelope(source: ByteArray) {
        val message = CapabilityNative.decodeWire(source) ?: run {
            failClosed()
            return
        }
        try {
            var reducer = legacy
            if (reducer == null) {
                if (message.kind != CapabilityMessageKind.Offer ||
                    peerVersion != LEGACY_NEGOTIATION_VERSION) {
                    failClosed()
                    return
                }
                reducer = CapabilityNegotiation(
                    message.generation, authorizedCapabilities, message.projection,
                )
                legacy = reducer
                executeLegacy(reducer.peerHello(LEGACY_NEGOTIATION_VERSION))
            }
            executeLegacy(reducer.message(message))
        } catch (_: Exception) {
            failClosed()
        }
    }

    private fun publishLocalProfile() {
        if (failed || localProfileSent || intentGeneration == 0L) {
            failClosed()
            return
        }
        val encoded = CapabilityIntentV2Native.encodeProfileWire(
            CapabilityIntentProfileV2ProductAdvertisement(
                generation = intentGeneration,
                schemaVersion = INTENT_NEGOTIATION_VERSION,
                senderRole = IntentV2Role.Sink,
                productProfile = productProfileV2,
            ),
        ) ?: return failClosed()
        try {
            sendControl(encoded)
            localProfileSent = true
        } catch (_: Exception) {
            failClosed()
        }
    }

    private fun startIntent(offer: CapabilityIntentV2WireMessage) {
        if (offer.offererRole != IntentV2Role.Source || offer.selectorRole != IntentV2Role.Sink ||
            offer.resolved.localRole != IntentV2Role.Source) {
            failClosed()
            return
        }
        val peer = peerProfileV2 ?: return failClosed()
        val local = offer.resolved.copy(localRole = IntentV2Role.Sink)
        try {
            val reducer = CapabilityIntentV2Reducer(CapabilityIntentV2Config(
                generation = intentGeneration,
                productCapabilities = productProfileV2.axes.capabilityBits,
                peerCapabilities = peer.peerProfile.capabilityBits,
                side = SIDE_SELECTOR,
                desiredPeerRole = IntentV2Role.Source,
                resolved = local,
            ))
            intent = reducer
            intentResolved = local
            val helloEffects = reducer.apply(CapabilityIntentV2Event(
                type = EVENT_PEER_HELLO,
                generation = intentGeneration,
                version = INTENT_NEGOTIATION_VERSION,
                hasVersion = true,
            ))
            if (helloEffects.isNotEmpty()) {
                reducer.close()
                intent = null
                failClosed()
                return
            }
            offerReceived = true
            applyIntent(offer)
        } catch (_: Exception) {
            failClosed()
        } catch (_: LinkageError) {
            failClosed()
        }
    }

    private fun applyIntent(message: CapabilityIntentV2WireMessage) {
        val reducer = intent ?: return failClosed()
        try {
            executeIntent(reducer.apply(CapabilityIntentV2Event(
                type = when (message.kind) {
                    CapabilityIntentV2WireKind.Offer -> EVENT_OFFER
                    CapabilityIntentV2WireKind.Selection -> EVENT_SELECTION
                    CapabilityIntentV2WireKind.Commit -> EVENT_COMMIT
                },
                generation = intentGeneration,
                version = message.negotiationVersion,
                hasVersion = true,
                offererRole = message.offererRole,
                selectorRole = message.selectorRole,
                projection = message.projection,
                transport = message.transport,
                resolved = message.resolved,
            )))
        } catch (_: Exception) {
            failClosed()
        } catch (_: LinkageError) {
            failClosed()
        }
    }

    private fun executeIntent(effects: List<CapabilityIntentV2Effect>) {
        for (effect in effects) {
            if (failed) return
            when (effect.kind) {
                CapabilityIntentV2EffectKind.SendSelection -> sendIntent(effect)
                CapabilityIntentV2EffectKind.SendOffer,
                CapabilityIntentV2EffectKind.SendCommit -> failClosed()
                CapabilityIntentV2EffectKind.Committed -> {
                    if (!validIntentBinding(effect)) return failClosed()
                    intentCommitted = true
                    committed(effect.projection?.nativeValue ?: return failClosed())
                    log("Rust capability intent v2 binding committed")
                }
                CapabilityIntentV2EffectKind.Connected -> {
                    if (!intentCommitted || !validIntentBinding(effect)) return failClosed()
                    finish(true)
                }
                CapabilityIntentV2EffectKind.Rejected -> {
                    log("Rust capability intent v2 rejected reason=${effect.reason}")
                    failClosed()
                }
                CapabilityIntentV2EffectKind.Fatal -> {
                    log("Rust capability intent v2 fatal reason=${effect.reason}")
                    failClosed()
                }
            }
        }
    }

    private fun validIntentBinding(effect: CapabilityIntentV2Effect): Boolean =
        effect.localRole == IntentV2Role.Sink &&
            effect.peerRole == IntentV2Role.Source &&
            effect.negotiated && effect.resolved == intentResolved

    private fun sendIntent(effect: CapabilityIntentV2Effect) {
        val offerer = effect.offererRole ?: return failClosed()
        val selector = effect.selectorRole ?: return failClosed()
        val projection = effect.projection ?: return failClosed()
        val transport = effect.transport ?: return failClosed()
        val resolved = effect.resolved ?: return failClosed()
        val encoded = CapabilityIntentV2Native.encodeWire(CapabilityIntentV2WireMessage(
            kind = CapabilityIntentV2WireKind.Selection,
            generation = effect.generation,
            negotiationVersion = effect.negotiationVersion,
            offererRole = offerer,
            selectorRole = selector,
            projection = projection,
            transport = transport,
            resolved = resolved,
        )) ?: return failClosed()
        try {
            sendControl(encoded)
        } catch (_: Exception) {
            failClosed()
        }
    }

    private fun executeLegacy(effects: List<CapabilityEffect>) {
        effects.forEach { effect ->
            when (effect) {
                is CapabilityEffect.Send -> sendLegacy(effect.message)
                is CapabilityEffect.Committed -> {
                    committed(effect.binding.projection.nativeValue)
                    log("Rust capability committed projection=${effect.binding.projection.wire}")
                }
                is CapabilityEffect.Connected -> finish(
                    effect.binding.localRole == CapabilityNegotiation.ROLE_RECEIVER &&
                        effect.binding.peerRole == CapabilityNegotiation.ROLE_HOST,
                )
                is CapabilityEffect.Rejected -> log(
                    "Rust capability rejected event reason=${effect.reason}")
                is CapabilityEffect.Fatal -> {
                    log("Rust capability fatal reason=${effect.reason}")
                    failClosed()
                }
            }
        }
    }

    private fun failClosed() {
        if (failed) return
        failed = true
        if (commitOperation == 0L) fatal() else finish(false)
    }

    private fun finish(success: Boolean) {
        val operation = commitOperation
        if (operation == 0L) return
        commitOperation = 0
        complete(operation, success)
    }

    private fun sendLegacy(message: CapabilityMessage) {
        CapabilityNative.encodeWire(message)?.let(sendControl) ?: failClosed()
    }

    override fun close() {
        legacy?.close()
        legacy = null
        intent?.close()
        intent = null
        pendingLegacyEnvelope = null
        commitOperation = 0
        failed = true
    }

    companion object {
        const val LEGACY_NEGOTIATION_VERSION = 1
        const val INTENT_NEGOTIATION_VERSION = 2
        private const val SIDE_SELECTOR = 2
        private const val EVENT_PEER_HELLO = 1
        private const val EVENT_OFFER = 2
        private const val EVENT_SELECTION = 3
        private const val EVENT_COMMIT = 4
    }
}
