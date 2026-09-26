package com.superconnect.receiver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class ReceiverGenerationFenceTest {
    @Test
    fun authenticatedByeRevokesMediaBeforeDelayedCloseAndStaleCloseKeepsReplacement() {
        var activeOwnerId = OLD_OWNER
        val media = ProductionMediaFixture()
        val hostRouter = ActiveSessionAuthorizationRouter(
            activeOwnerId = { activeOwnerId },
            downstream = { authorized, generation ->
                media.owner.onAuthorized(authorized, generation)
            },
        )
        val oldAuthorization = SessionAuthorizationLifecycle(
            generation = { OLD_GENERATION },
            notify = { authorized, generation ->
                hostRouter.route(OLD_OWNER, authorized, generation)
            },
        )
        var closeAfterWritesQueued = false
        var physicalCloseCompleted = false
        val oldTerminal = SessionTerminalMediaBridge(oldAuthorization) {
            closeAfterWritesQueued = true
        }

        assertTrue(oldAuthorization.ready())
        val oldMedia = media.configure(OLD_GENERATION)
        val pending = ByteArray(32) { 0x41 }
        assertTrue(oldMedia.submit(pending))
        assertEquals(1, oldMedia.pending())

        // Production EFFECT_CLOSE_TRANSPORT revokes media before TcpPeer drains queued writes.
        assertTrue(oldTerminal.revokeFor(SessionReducer.EFFECT_CLOSE_TRANSPORT))
        assertFalse(closeAfterWritesQueued)
        assertFalse(physicalCloseCompleted)
        assertFalse(media.owner.isActive(OLD_GENERATION))
        assertTrue(oldMedia.stopped)
        assertEquals(0, oldMedia.pending())
        assertTrue(pending.all { it == 0.toByte() })
        assertFalse(oldMedia.mayRunLateUiOrRender())
        val late = ByteArray(8) { 0x55 }
        assertFalse(oldMedia.submit(late))
        late.fill(0) // The caller retains ownership when the media owner rejects the array.

        oldTerminal.requestTransportCloseAfterEffects()
        assertTrue(closeAfterWritesQueued)
        assertFalse(physicalCloseCompleted) // write/flush is deliberately still blocked

        activeOwnerId = NEW_OWNER
        val newAuthorization = SessionAuthorizationLifecycle(
            generation = { NEW_GENERATION },
            notify = { authorized, generation ->
                hostRouter.route(NEW_OWNER, authorized, generation)
            },
        )
        assertTrue(newAuthorization.ready())
        val newMedia = media.configure(NEW_GENERATION)
        val firstFrame = ByteArray(24) { 0x22 }
        assertTrue(newMedia.submit(firstFrame))

        // The eventual old peer close is routed with its exact owner/generation and cannot retire new media.
        physicalCloseCompleted = true
        hostRouter.route(OLD_OWNER, false, OLD_GENERATION)
        assertTrue(physicalCloseCompleted)
        assertTrue(media.owner.isActive(NEW_GENERATION))
        val dequeued = newMedia.take()
        assertSame(firstFrame, dequeued)
        dequeued?.fill(0)
    }

    @Test
    fun recordFatalRevokesThroughProductionAuthorizationAndWipesPendingMedia() {
        val media = ProductionMediaFixture()
        val hostRouter = ActiveSessionAuthorizationRouter(
            activeOwnerId = { FATAL_OWNER },
            downstream = { authorized, generation ->
                media.owner.onAuthorized(authorized, generation)
            },
        )
        val authorization = SessionAuthorizationLifecycle(
            generation = { FATAL_GENERATION },
            notify = { authorized, generation ->
                hostRouter.route(FATAL_OWNER, authorized, generation)
            },
        )
        val terminal = SessionTerminalMediaBridge(authorization) {}

        assertTrue(authorization.ready())
        val activeMedia = media.configure(FATAL_GENERATION)
        val pending = ByteArray(17) { 0x33 }
        assertTrue(activeMedia.submit(pending))

        assertTrue(terminal.revokeFor(SessionReducer.EFFECT_NOTIFY_FATAL))
        assertFalse(media.owner.isActive(FATAL_GENERATION))
        assertTrue(activeMedia.stopped)
        assertEquals(0, activeMedia.pending())
        assertTrue(pending.all { it == 0.toByte() })
        assertFalse(activeMedia.mayRunLateUiOrRender())
        assertFalse(terminal.revokeFor(SessionReducer.EFFECT_CLOSE_TRANSPORT))
    }

    @Test
    fun pausedOldTerminationCannotRetireReplacementDecoderConfigOrFirstFrame() {
        val oldTransitionEntered = CountDownLatch(1)
        val releaseOldTransition = CountDownLatch(1)
        val media = ProductionMediaFixture { generation ->
            if (generation == OLD_GENERATION) {
                oldTransitionEntered.countDown()
                await(releaseOldTransition)
            }
        }
        var activeOwnerId = OLD_OWNER
        val hostRouter = ActiveSessionAuthorizationRouter(
            activeOwnerId = { activeOwnerId },
            downstream = { authorized, generation ->
                media.owner.onAuthorized(authorized, generation)
            },
        )
        val oldAuthorization = SessionAuthorizationLifecycle(
            generation = { OLD_GENERATION },
            notify = { authorized, generation ->
                hostRouter.route(OLD_OWNER, authorized, generation)
            },
        )
        val oldTerminal = SessionTerminalMediaBridge(oldAuthorization) {}
        assertTrue(oldAuthorization.ready())
        val oldMedia = media.configure(OLD_GENERATION)
        val oldPending = ByteArray(12) { 0x41 }
        assertTrue(oldMedia.submit(oldPending))

        val failure = AtomicReference<Throwable?>()
        val oldClose = thread(name = "old-generation-terminal") {
            try {
                assertTrue(oldTerminal.revokeFor(SessionReducer.EFFECT_CLOSE_TRANSPORT))
            } catch (error: Throwable) {
                failure.compareAndSet(null, error)
            }
        }
        await(oldTransitionEntered)
        assertFalse(media.owner.isActive(OLD_GENERATION))

        activeOwnerId = NEW_OWNER
        val newAuthorization = SessionAuthorizationLifecycle(
            generation = { NEW_GENERATION },
            notify = { authorized, generation ->
                hostRouter.route(NEW_OWNER, authorized, generation)
            },
        )
        val newReadyAttempted = CountDownLatch(1)
        val newReadyCompleted = CountDownLatch(1)
        val newMedia = AtomicReference<TestMedia?>()
        val firstFrame = ByteArray(24) { 0x22 }
        val replacement = thread(name = "new-generation-ready") {
            try {
                newReadyAttempted.countDown()
                assertTrue(newAuthorization.ready())
                val decoder = media.configure(NEW_GENERATION)
                newMedia.set(decoder)
                assertTrue(decoder.submit(firstFrame))
            } catch (error: Throwable) {
                failure.compareAndSet(null, error)
            } finally {
                newReadyCompleted.countDown()
            }
        }

        // New Ready has been attempted, but cannot overtake the old transition's atomic resource capture.
        await(newReadyAttempted)
        try {
            assertFalse(newReadyCompleted.await(100, TimeUnit.MILLISECONDS))
        } finally {
            releaseOldTransition.countDown()
        }
        oldClose.join(3_000)
        replacement.join(3_000)
        assertFalse(oldClose.isAlive)
        assertFalse(replacement.isAlive)
        failure.get()?.let { throw it }

        assertTrue(oldMedia.stopped)
        assertEquals(0, oldMedia.pending())
        assertTrue(oldPending.all { it == 0.toByte() })
        val activeMedia = checkNotNull(newMedia.get())
        assertSame(activeMedia, media.current())
        assertEquals(NEW_GENERATION, media.configGeneration())
        assertTrue(media.owner.isActive(NEW_GENERATION))
        assertFalse(activeMedia.stopped)
        assertEquals(1, activeMedia.pending())
        val dequeued = activeMedia.take()
        assertSame(firstFrame, dequeued)
        dequeued?.fill(0)
    }

    /** Mirrors MainActivity's unconditional detach/reset rule under its shared lifecycle lock. */
    private class ProductionMediaFixture(
        private val beforeTerminateLocked: (generation: Long) -> Unit = {},
    ) {
        private val lifecycleLock = Any()
        private var currentMedia: TestMedia? = null
        private var configuredGeneration = 0L
        lateinit var owner: ReceiverMediaAuthorizationOwner
            private set

        init {
            owner = ReceiverMediaAuthorizationOwner(
                ownershipLock = lifecycleLock,
                activated = {
                    val retired = currentMedia
                    currentMedia = null
                    configuredGeneration = 0L
                    { retired?.stop() }
                },
                terminated = { generation ->
                    beforeTerminateLocked(generation)
                    val retired = currentMedia
                    currentMedia = null
                    configuredGeneration = 0L
                    { retired?.stop() }
                },
            )
        }

        fun configure(generation: Long): TestMedia {
            var retired: TestMedia? = null
            val created = synchronized(lifecycleLock) {
                check(owner.isActive(generation))
                retired = currentMedia
                TestMedia(generation, owner::isActive).also { decoder ->
                    currentMedia = decoder
                    configuredGeneration = generation
                }
            }
            retired?.stop()
            return created
        }

        fun current(): TestMedia? = synchronized(lifecycleLock) { currentMedia }

        fun configGeneration(): Long = synchronized(lifecycleLock) { configuredGeneration }
    }

    private class TestMedia(
        val generation: Long,
        private val isGenerationActive: (Long) -> Boolean,
    ) {
        private val frames = GenerationBoundAccessUnitQueue(4)
        var stopped = false
            private set

        fun submit(frame: ByteArray): Boolean =
            frames.offer(frame) { !stopped && isGenerationActive(generation) }

        fun take(): ByteArray? =
            frames.take(0) { !stopped && isGenerationActive(generation) }

        fun pending(): Int = frames.pendingForTesting()

        fun mayRunLateUiOrRender(): Boolean = !stopped && isGenerationActive(generation)

        fun stop() {
            stopped = true
            frames.wipe()
        }
    }

    private companion object {
        const val OLD_OWNER = 7
        const val NEW_OWNER = 8
        const val FATAL_OWNER = 9
        const val OLD_GENERATION = 41L
        const val NEW_GENERATION = 42L
        const val FATAL_GENERATION = 43L

        fun await(latch: CountDownLatch) {
            assertTrue("barrier timeout", latch.await(3, TimeUnit.SECONDS))
        }
    }
}
