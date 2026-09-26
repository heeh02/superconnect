package com.superconnect.receiver

import com.superconnect.protocol.AuthCrypto
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class Session(
    private val frameWriter: OrderedFrameWriter,
    private val ownerId: Int,
    private val caps: ReceiverCaps,
    private val deviceName: String,
    private val peerId: String,
    private val authorizedCapabilities: Long = CapabilityNegotiation.BASELINE_RECEIVER_CAPABILITIES,
    private val productProfileV2: ProductCapabilityProfileV2 =
        ProductCapabilityProfileV2.baselineReceiver(),
    private val log: (String) -> Unit = {},
) {
    var onVideo: ((ReceivedVideoAccessUnit) -> Boolean)? = null
    var onVideoConfig: ((width: Int, height: Int, codec: String, hdr: String, lowLatency: Boolean) -> Unit)? = null
    var onReady: (() -> Unit)? = null
    var onAuthenticationReady: (() -> Boolean)? = null
    var onPairingPromptStarted: (() -> Unit)? = null
    var onAdmissionRejected: (() -> Unit)? = null
    var onAuthorized: ((authorized: Boolean, generation: Long) -> Unit)? = null
    var onCapabilityCommitted: ((projection: Int) -> Unit)? = null; var onFatal: (() -> Unit)? = null
    val generation: Long get() = reducer.generation
    var trustGate: ((peerId: String, deviceName: String, ownerId: Int,
                     hasMacEphPub: Boolean, onPromptStarted: () -> Unit,
                     onResult: (TrustDecision) -> Unit) -> Unit)? = null

    sealed class TrustDecision {
        data class Steady(val secret: ByteArray) : TrustDecision()
        data class Enroll(
            val secret: ByteArray,
            val tabletEphPriv: ByteArray,
            val tabletEphPub: ByteArray,
            val persist: () -> Boolean = { true },
        ) : TrustDecision()
        object Reject : TrustDecision()
    }

    private data class Enrollment(val secret: ByteArray, val persist: () -> Boolean)

    private val lock = Any()
    // Every route authenticates and activates SC-RECORD, including forwarded sockets.
    private val reducer = SessionReducer(peerId.toByteArray(Charsets.UTF_8), trustedLocal = false)
    private val authorizationLifecycle = SessionAuthorizationLifecycle(
        generation = { reducer.generation },
        notify = { authorized, generation -> onAuthorized?.invoke(authorized, generation) },
    )
    private val terminalMediaBridge = SessionTerminalMediaBridge(authorizationLifecycle) {
        onAdmissionRejected?.invoke()
    }
    private val artifacts = SessionArtifactOwner()
    private val recordMaterial = SecureRecordMaterialOwner()
    private var hadAuthenticatedRecords = false
    private var pendingMacPeerId = ""
    private var pendingMacName = "Mac"
    private var pendingMacKeyArtifact = 0L
    private var enrollment: Enrollment? = null
    private var pendingCredentialLoadOperation = 0L
    private val capabilityDriver: SessionCapabilityDriver
    private var timer: ScheduledFuture<*>? = null
    private var timerToken = 0L
    private var ready = false
    private var disposed = false
    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "sc-session-deadline").apply { isDaemon = true }
    }
    private val controlWriter = SessionControlWriter(
        frameWriter,
        caps,
        deviceName,
        peerId,
        reducer::sealFrame,
        ::failTransport,
        log,
    )
    private val finalAckWriter = SessionFinalAckWriter(
        frameWriter = frameWriter,
        sessionLock = lock,
        sessionGeneration = { reducer.generation },
        frame = reducer::sealFrame,
        isDisposed = { disposed },
        complete = { operation, success, generation ->
            drive(SessionReducerEvent(SessionReducer.EVENT_FINAL_ACK_SUBMITTED,
                operation = operation, flag = success, generation = generation))
            onBytes(ByteArray(0))
        },
        failTransport = ::failTransport,
        log = log,
    )
    private val inputWriter = SessionInputWriter(
        lock, { !disposed && ready && reducer.snapshot().recordsActive },
        reducer::sealFrame, frameWriter, controlWriter, ::failTransport,
    )
    private val frameRouter: SessionFrameRouter
    private val inboundPump: SessionInboundPump
    init {
        capabilityDriver = SessionCapabilityDriver(
            legacyGeneration = reducer.generation,
            authorizedCapabilities = authorizedCapabilities,
            productProfileV2 = productProfileV2,
            sendControl = controlWriter::send,
            complete = { operation: Long, success: Boolean ->
                drive(SessionReducerEvent(
                    SessionReducer.EVENT_CAPABILITIES_COMMITTED,
                    operation = operation,
                    flag = success,
                ))
            },
            committed = { projection -> onCapabilityCommitted?.invoke(projection) },
            fatal = ::failTransport,
            log = log,
        )
        frameRouter = SessionFrameRouter(
            isReady = { ready },
            videoConsumer = { onVideo },
            videoConfigConsumer = { onVideoConfig },
            streamingStarted = {
                drive(SessionReducerEvent(SessionReducer.EVENT_STREAMING_STARTED))
            },
            sendControl = controlWriter::send,
            closeRequested = {
                drive(SessionReducerEvent(SessionReducer.EVENT_CLOSE_REQUESTED))
            },
            authReceived = ::onAuth,
            helloReceived = ::onHello,
            receiveCapability = capabilityDriver::receiveControl,
            receiveIntentProfile = capabilityDriver::receiveIntentProfile,
            receiveIntent = capabilityDriver::receiveIntent,
            failTransport = ::failTransport,
            log = log,
        )
        inboundPump = SessionInboundPump(
            reducer, frameRouter,
            canAdvance = { pendingCredentialLoadOperation == 0L && !finalAckWriter.hasPending() },
            isDisposed = { disposed },
        )
        synchronized(lock) {
            val initial = reducer.apply(SessionReducerEvent(SessionReducer.EVENT_START))
            val open = initial.firstOrNull { it.type == SessionReducer.EFFECT_OPEN_TRANSPORT }
                ?: error("Rust session omitted open transport")
            execute(initial)
            drive(SessionReducerEvent(SessionReducer.EVENT_TRANSPORT_OPENED, operation = open.operation))
        }
    }
    fun onBytes(bytes: ByteArray) {
        synchronized(lock) {
            if (disposed) return
            try {
                inboundPump.push(bytes)
            } catch (error: Throwable) {
                val effects = runCatching(reducer::drainEffects).getOrDefault(emptyList())
                if (effects.isEmpty()) failTransport() else execute(effects)
            } finally { bytes.fill(0) }
        }
    }
    fun dispose() {
        synchronized(lock) {
            if (disposed) return
            finalAckWriter.cancel()
            drive(SessionReducerEvent(SessionReducer.EVENT_TRANSPORT_CLOSED))
            disposed = true
            timer?.cancel(false); timer = null; timerToken = 0
            ready = false
            clearSensitiveState()
            capabilityDriver.close()
            authorizationLifecycle.dispose()
            inboundPump.close()
            frameRouter.close()
            recordMaterial.close()
            reducer.close()
        }
        scheduler.shutdownNow()
    }

    private fun onHello(message: SessionHelloMessage) {
        if (disposed || reducer.phase() != SessionReducer.PHASE_HELLO) return
        execute(reducer.observeRecordVersion(message.recordVersion))
        val identity = message.peerId.toByteArray(Charsets.UTF_8)
        if (identity.isEmpty() || identity.size > 128) { failTransport(); return }
        pendingMacPeerId = message.peerId
        pendingMacName = message.deviceName ?: "Mac"
        if (!capabilityDriver.observeHello(message)) {
            failTransport()
            return
        }
        val authVersion = message.authVersion ?: 0
        val peerKey = message.enrollmentKey?.let(artifacts::putCopy) ?: 0
        pendingMacKeyArtifact = peerKey
        drive(SessionReducerEvent(SessionReducer.EVENT_PEER_HELLO, first = peerKey,
            authVersion = authVersion, identity = identity))
    }

    private fun onAuth(message: AuthWireMessage.Auth) {
        if (disposed || reducer.phase() != SessionReducer.PHASE_MUTUAL_AUTH) return
        drive(SessionReducerEvent(SessionReducer.EVENT_PEER_AUTH,
            first = artifacts.putCopy(message.proof), second = artifacts.putCopy(message.challenge)))
    }

    private fun drive(event: SessionReducerEvent) {
        if (disposed) return
        execute(reducer.apply(event))
    }

    private fun execute(effects: List<SessionReducerEffect>) {
        var closeTransport = false
        effects.forEach { effect ->
            if (disposed) return
            when (effect.type) {
                SessionReducer.EFFECT_OPEN_TRANSPORT -> Unit // accepted TcpPeer is already open
                SessionReducer.EFFECT_ARM_TIMER -> armTimer(effect.timerToken)
                SessionReducer.EFFECT_CANCEL_TIMER -> cancelTimer(effect.timerToken)
                SessionReducer.EFFECT_LOAD_CREDENTIAL -> loadCredential(effect)
                SessionReducer.EFFECT_REQUEST_ENROLLMENT -> drive(SessionReducerEvent(
                    SessionReducer.EVENT_ENROLLMENT_APPROVED, operation = effect.operation,
                    flag = enrollment != null))
                SessionReducer.EFFECT_PREPARE_ENROLLMENT -> prepareEnrollment(effect)
                SessionReducer.EFFECT_GENERATE_CHALLENGE -> drive(SessionReducerEvent(
                    SessionReducer.EVENT_CHALLENGE_GENERATED, operation = effect.operation,
                    first = artifacts.takeBytes(AuthCrypto.randomBytes(32))))
                SessionReducer.EFFECT_SEND_HELLO_ACK -> {
                    val challenge = bytes(effect.challenge)
                    recordMaterial.captureResponder(challenge)
                    controlWriter.sendHelloAck(challenge = challenge, needsPairing = effect.enrollment,
                        ephPub = enrollmentKey(effect.localEnrollmentKey)?.publicKey)
                }
                SessionReducer.EFFECT_SEND_ENROLLMENT -> sendEnrollment(envelope(effect.envelope))
                SessionReducer.EFFECT_VERIFY_PEER_PROOF -> verifyPeer(effect)
                SessionReducer.EFFECT_CLAIM_ADMISSION -> claimAdmission(effect)
                SessionReducer.EFFECT_CREATE_MUTUAL_PROOF -> createMutualProof(effect)
                SessionReducer.EFFECT_SUBMIT_AUTH_ACK -> submitAuthAck(effect)
                SessionReducer.EFFECT_SUBMIT_HELLO_ACK -> submitFinalHelloAck(effect)
                SessionReducer.EFFECT_WRITE_CREDENTIAL -> writeCredential(effect)
                SessionReducer.EFFECT_CANCEL_CREDENTIAL_WRITE -> clearEnrollment()
                SessionReducer.EFFECT_PREPARE_RECORD_CONTEXT -> execute(
                    recordMaterial.prepare(reducer, effect.operation))
                SessionReducer.EFFECT_ACTIVATE_RECORDS -> {
                    val activated = reducer.recordsActivated(effect.operation, true)
                    hadAuthenticatedRecords = true
                    execute(activated)
                }
                SessionReducer.EFFECT_DISPOSE_RECORDS -> recordMaterial.close()
                SessionReducer.EFFECT_COMMIT_CAPABILITIES -> {
                    if (!reducer.snapshot().recordsActive) {
                        return failTransport()
                    }
                    capabilityDriver.begin(effect.operation)
                }
                SessionReducer.EFFECT_NOTIFY_READY -> notifyReady()
                SessionReducer.EFFECT_NOTIFY_STREAMING -> log("Rust session entered streaming")
                SessionReducer.EFFECT_CLOSE_TRANSPORT -> {
                    ready = false
                    terminalMediaBridge.revokeFor(effect.type)
                    finalAckWriter.cancel()
                    inboundPump.close()
                    clearSensitiveState()
                    closeTransport = true
                }
                SessionReducer.EFFECT_NOTIFY_CLOSED -> {
                    ready = false
                    clearSensitiveState()
                }
                SessionReducer.EFFECT_RELEASE_ADMISSION -> ready = false
                SessionReducer.EFFECT_NOTIFY_FATAL -> notifyFatal(effect.fatalReason)
            }
        }
        // Submit the typed fatal response before asking TcpPeer to drain and close its writer.
        if (closeTransport) terminalMediaBridge.requestTransportCloseAfterEffects()
    }

    private fun loadCredential(effect: SessionReducerEffect) {
        val gate = trustGate
        if (gate == null) {
            drive(SessionReducerEvent(SessionReducer.EVENT_CREDENTIAL_LOADED,
                credentialState = SessionReducer.CREDENTIAL_UNAVAILABLE, operation = effect.operation))
            return
        }
        if (pendingCredentialLoadOperation != 0L) return failTransport()
        pendingCredentialLoadOperation = effect.operation
        try {
            gate(pendingMacPeerId, pendingMacName, ownerId,
                pendingMacKeyArtifact != 0L, { onPairingPromptStarted?.invoke() }) { decision ->
                synchronized(lock) {
                    if (disposed || pendingCredentialLoadOperation != effect.operation) {
                        decision.zeroizeSensitive()
                        if (!disposed) failTransport()
                        return@synchronized
                    }
                    pendingCredentialLoadOperation = 0L
                    var adopted = false
                    try {
                        when (decision) {
                            is TrustDecision.Steady -> {
                                val credential = artifacts.takeBytes(decision.secret)
                                adopted = true
                                drive(SessionReducerEvent(
                                    SessionReducer.EVENT_CREDENTIAL_LOADED,
                                    credentialState = SessionReducer.CREDENTIAL_PRESENT,
                                    operation = effect.operation, first = credential))
                            }
                            is TrustDecision.Enroll -> {
                                artifacts.takeEnrollmentKey(reducer.localEnrollmentKey,
                                    decision.tabletEphPriv, decision.tabletEphPub)
                                enrollment = Enrollment(decision.secret, decision.persist)
                                adopted = true
                                drive(SessionReducerEvent(
                                    SessionReducer.EVENT_CREDENTIAL_LOADED,
                                    credentialState = SessionReducer.CREDENTIAL_MISSING,
                                    operation = effect.operation))
                            }
                            else -> drive(SessionReducerEvent(
                                SessionReducer.EVENT_CREDENTIAL_LOADED,
                                credentialState = SessionReducer.CREDENTIAL_MISSING,
                                operation = effect.operation))
                        }
                    } catch (error: Throwable) {
                        log("credential callback failed: $error")
                        if (adopted) clearSensitiveState() else decision.zeroizeSensitive()
                        failTransport()
                    } finally {
                        if (!adopted) decision.zeroizeSensitive()
                    }
                    if (!disposed) onBytes(ByteArray(0))
                }
            }
        } catch (error: Throwable) {
            if (pendingCredentialLoadOperation == effect.operation) {
                pendingCredentialLoadOperation = 0L
                log("credential gate failed: $error")
                failTransport()
            }
        }
    }

    private fun prepareEnrollment(effect: SessionReducerEffect) {
        val decision = enrollment ?: run { failTransport(); return }
        val localKey = enrollmentKey(effect.localEnrollmentKey) ?: run { failTransport(); return }
        val peerKey = bytes(effect.peerEnrollmentKey)
        if (peerKey == null) { failTransport(); return }
        var salt: ByteArray? = null
        var nonce: ByteArray? = null
        var key: ByteArray? = null
        var sealed: ByteArray? = null
        try {
            salt = AuthCrypto.randomBytes(16)
            nonce = AuthCrypto.randomBytes(12)
            key = AuthCrypto.deriveEcdhKey(localKey.privateKey, peerKey, checkNotNull(salt))
            sealed = AuthCrypto.seal(decision.secret, checkNotNull(key), checkNotNull(nonce),
                AuthCrypto.PAIR_INFO)
            val credential = artifacts.putCopy(decision.secret)
            val challenge = artifacts.takeBytes(AuthCrypto.randomBytes(32))
            val envelope = artifacts.takeEnvelope(checkNotNull(sealed), checkNotNull(salt),
                checkNotNull(nonce))
            sealed = null; salt = null; nonce = null
            drive(SessionReducerEvent(SessionReducer.EVENT_ENROLLMENT_PREPARED,
                operation = effect.operation, first = credential,
                second = challenge, third = envelope))
        } catch (error: Throwable) {
            log("enrollment preparation failed: $error")
            failTransport()
        } finally {
            key?.fill(0)
            sealed?.fill(0)
            salt?.fill(0)
            nonce?.fill(0)
        }
    }

    private fun verifyPeer(effect: SessionReducerEffect) {
        val valid = try {
            AuthCrypto.verifyProof(bytes(effect.proof) ?: return failTransport(),
                bytes(effect.credential) ?: return failTransport(), pendingMacPeerId, peerId,
                bytes(effect.challenge) ?: return failTransport())
        } catch (_: Exception) { false }
        drive(SessionReducerEvent(SessionReducer.EVENT_PEER_PROOF_VERIFIED,
            operation = effect.operation, flag = valid))
    }

    private fun claimAdmission(effect: SessionReducerEffect) {
        if (onAuthenticationReady?.invoke() == false) {
            drive(SessionReducerEvent(SessionReducer.EVENT_ADMISSION_FAILED, operation = effect.operation))
        } else {
            drive(SessionReducerEvent(SessionReducer.EVENT_ADMISSION_SUCCEEDED,
                operation = effect.operation, first = ownerId.toLong()))
        }
    }

    private fun createMutualProof(effect: SessionReducerEffect) {
        val secret = bytes(effect.credential) ?: return failTransport()
        val initiatorChallenge = bytes(effect.challenge) ?: return failTransport()
        val proof = try { AuthCrypto.createProof(secret,
            peerId, pendingMacPeerId, initiatorChallenge) }
        catch (_: Exception) { return failTransport() }
        recordMaterial.captureMutual(secret, initiatorChallenge)
        drive(SessionReducerEvent(SessionReducer.EVENT_MUTUAL_PROOF_CREATED,
            operation = effect.operation, first = artifacts.takeBytes(proof)))
    }

    private fun submitAuthAck(effect: SessionReducerEffect) {
        val proof = bytes(effect.proof) ?: return failTransport()
        val payload = AuthWireNative.encode(AuthWireMessage.AuthAck(proof)) ?: return failTransport()
        finalAckWriter.submit(effect.operation, payload)
    }

    private fun submitFinalHelloAck(effect: SessionReducerEffect) {
        val payload = controlWriter.encodeFinalHelloAck() ?: return failTransport()
        finalAckWriter.submit(effect.operation, payload)
    }

    private fun writeCredential(effect: SessionReducerEffect) {
        val ownedEnrollment = enrollment
        val success = try {
            bytes(effect.credential) != null && ownedEnrollment?.persist?.invoke() == true
        } catch (error: Throwable) {
            log("credential persistence failed: $error")
            false
        }
        try {
            drive(SessionReducerEvent(SessionReducer.EVENT_CREDENTIAL_WRITE_COMPLETED,
                operation = effect.operation, flag = success))
        } finally {
            clearEnrollment()
        }
    }

    private fun notifyReady() {
        if (ready) return
        clearSensitiveState()
        ready = true
        authorizationLifecycle.ready()
        onReady?.invoke()
    }

    private fun notifyFatal(reason: Int) {
        ready = false
        clearSensitiveState()
        onFatal?.invoke()
        terminalMediaBridge.revokeFor(SessionReducer.EFFECT_NOTIFY_FATAL)
        if (!hadAuthenticatedRecords) controlWriter.sendSessionFatalError(reason)
        log("Rust session fatal=$reason")
    }

    private fun armTimer(token: Long) {
        check(token > 0 && timer == null)
        timerToken = token
        timer = scheduler.schedule({
            synchronized(lock) {
                if (!disposed && timerToken == token) drive(SessionReducerEvent(
                    SessionReducer.EVENT_TIMER_FIRED, first = token))
            }
        }, HANDSHAKE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
    }

    private fun cancelTimer(token: Long) {
        if (timerToken != token) return
        timer?.cancel(false); timer = null; timerToken = 0
    }

    private fun failTransport() {
        finalAckWriter.cancel()
        drive(SessionReducerEvent(SessionReducer.EVENT_TRANSPORT_FAILED))
        if (!ready) clearSensitiveState()
    }

    private fun bytes(id: Long): ByteArray? = artifacts.borrowBytes(id)
    private fun enrollmentKey(id: Long): SessionArtifactOwner.Artifact.EnrollmentKey? =
        artifacts.borrowEnrollmentKey(id)
    private fun envelope(id: Long): SessionArtifactOwner.Artifact.PairEnvelope? =
        artifacts.borrowEnvelope(id)
    private fun sendEnrollment(value: SessionArtifactOwner.Artifact.PairEnvelope?) {
        if (value == null) return failTransport()
        controlWriter.sendEnrollment(value.encrypted, value.salt, value.nonce)
    }
    fun requestKeyframe() = controlWriter.requestKeyframe()

    fun sendPointer(payload: ByteArray) = inputWriter.send(payload)
    fun sendText(text: String) = inputWriter.text(text)

    private fun clearEnrollment() {
        enrollment?.secret?.fill(0)
        enrollment = null
    }

    private fun clearSensitiveState() {
        pendingCredentialLoadOperation = 0L
        pendingMacKeyArtifact = 0L
        clearEnrollment()
        artifacts.clear()
        recordMaterial.close()
    }

    internal fun artifactCountForTesting(): Int = synchronized(lock) { artifacts.size() }

    private companion object {
        const val HANDSHAKE_TIMEOUT_SECONDS = 30L
    }
}
