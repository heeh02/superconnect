package com.superconnect.receiver

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.view.Surface
import kotlin.concurrent.thread

/**
 * Hardware H.264/HEVC decode → Surface, the Android analogue of the HarmonyOS native OH_VideoDecoder
 * path. The Mac streams Annex-B with INLINE SPS/PPS (each keyframe carries them), so MediaCodec is
 * configured without csd and parses parameter sets in-band. Low-latency: KEY_LOW_LATENCY (API 30+),
 * newest-wins backpressure (cap the queue so we never accumulate display lag), render straight to the
 * SurfaceView's Surface. Runs on its own thread; `submit()` is called from the network thread.
 *
 * @param mime "video/avc" (H.264) or "video/hevc" (HEVC)
 */
class VideoDecoder(
    private val mime: String,
    private val width: Int,
    private val height: Int,
    private val surface: Surface,
    private val generation: Long,
    private val isGenerationActive: (Long) -> Boolean,
    private val onFirstFrame: () -> Unit = {},
    private val log: (String) -> Unit = {},
) {
    private var codec: MediaCodec? = null
    private val frames = GenerationBoundAccessUnitQueue(MAX_QUEUED_FRAMES)
    @Volatile private var running = false
    private var worker: Thread? = null
    private var heldInput = -1
    private var ptsUs = 0L

    fun start() {
        val c = MediaCodec.createDecoderByType(mime)
        val fmt = MediaFormat.createVideoFormat(mime, width, height)
        var stage = "configure"
        try {
            if (Build.VERSION.SDK_INT >= 30 && c.codecInfo.getCapabilitiesForType(mime)
                    .isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)) {
                fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            c.configure(fmt, surface, null, 0)
            stage = "start"
            c.start()
        } catch (error: Exception) {
            val name = c.name
            c.release()
            throw IllegalStateException("$name $stage: ${error.message}", error)
        }
        codec = c
        running = true
        worker = thread(name = "sc-decoder", isDaemon = true) { loop(c) }
        log("decoder started $mime ${width}x$height")
    }

    /** Takes ownership of one Annex-B access unit only when the running decoder queues it. */
    fun submit(frame: ByteArray): Boolean =
        frames.offer(frame) { running && isGenerationActive(generation) }

    private fun loop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var rendered = 0
        var fed = 0
        try {
            while (running && isGenerationActive(generation)) {
                if (heldInput < 0) heldInput = c.dequeueInputBuffer(5_000)
                if (heldInput >= 0) {
                    val frame = frames.take(5) { running && isGenerationActive(generation) }
                    if (frame != null) {
                        try {
                            if (!running || !isGenerationActive(generation)) continue
                            val ib = c.getInputBuffer(heldInput)
                            if (ib != null) {
                                ib.clear(); ib.put(frame)
                                c.queueInputBuffer(heldInput, 0, frame.size, ptsUs, 0)
                                ptsUs += 16_666   // ~60 fps spacing; PTS only needs to be monotonic for display
                                if (++fed <= 2) log("fed input #$fed (${frame.size}B)")
                            }
                        } finally {
                            frame.fill(0)
                        }
                        heldInput = -1
                    }
                }
                var outIdx = c.dequeueOutputBuffer(info, 0)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) log("output format: ${c.outputFormat}")
                while (outIdx >= 0) {
                    val render = running && isGenerationActive(generation)
                    c.releaseOutputBuffer(outIdx, render)
                    if (render && ++rendered == 1) {
                        log("FIRST FRAME RENDERED ✓")
                        onFirstFrame()
                    }
                    outIdx = c.dequeueOutputBuffer(info, 0)
                }
            }
        } catch (e: Exception) {
            log("decoder loop err $e")
        }
    }

    fun stop() {
        running = false
        frames.wipe()
        // Join the worker BEFORE releasing the codec. The worker loop calls dequeue/queue/release on the
        // same MediaCodec instance; stopping/releasing it from another thread while the worker is mid-call is
        // concurrent single-codec use — it can throw IllegalStateException or abort in native code (SIGABRT),
        // which the worker's `catch (Exception)` cannot intercept. running=false makes the loop exit within one
        // iteration (≤5 ms blocked in dequeueInputBuffer); join bounds the wait so teardown never hangs.
        val w = worker
        worker = null
        w?.interrupt()
        try { w?.join(500) } catch (_: InterruptedException) {}
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
        heldInput = -1
        frames.wipe()
    }

    companion object {
        private const val MAX_QUEUED_FRAMES = 4

        fun mimeFor(codec: String): String =
            if (codec.equals("hevc", true) || codec.equals("h265", true)) "video/hevc" else "video/avc"
    }
}
