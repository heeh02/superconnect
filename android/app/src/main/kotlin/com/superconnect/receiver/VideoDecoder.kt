package com.superconnect.receiver

import android.media.MediaCodec
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
    private val log: (String) -> Unit = {},
) {
    private var codec: MediaCodec? = null
    private val frames = ArrayDeque<ByteArray>()
    private val lock = Object()
    @Volatile private var running = false
    private var worker: Thread? = null
    private var heldInput = -1
    private var ptsUs = 0L

    fun start() {
        val c = MediaCodec.createDecoderByType(mime)
        val fmt = MediaFormat.createVideoFormat(mime, width, height)
        if (Build.VERSION.SDK_INT >= 30) fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        c.configure(fmt, surface, null, 0)
        c.start()
        codec = c
        running = true
        worker = thread(name = "sc-decoder", isDaemon = true) { loop(c) }
        log("decoder started $mime ${width}x$height")
    }

    /** Enqueue one encoded frame (Annex-B). Newest-wins: drop the oldest if we're backing up. */
    fun submit(frame: ByteArray) {
        synchronized(lock) {
            while (frames.size > 4) frames.removeFirst()
            frames.addLast(frame)
            lock.notifyAll()
        }
    }

    private fun nextFrame(timeoutMs: Long): ByteArray? {
        synchronized(lock) {
            if (frames.isEmpty()) { try { lock.wait(timeoutMs) } catch (_: InterruptedException) {} }
            return if (frames.isEmpty()) null else frames.removeFirst()
        }
    }

    private fun loop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var rendered = 0
        var fed = 0
        try {
            while (running) {
                if (heldInput < 0) heldInput = c.dequeueInputBuffer(5_000)
                if (heldInput >= 0) {
                    val frame = nextFrame(5)
                    if (frame != null) {
                        val ib = c.getInputBuffer(heldInput)
                        if (ib != null) {
                            ib.clear(); ib.put(frame)
                            c.queueInputBuffer(heldInput, 0, frame.size, ptsUs, 0)
                            ptsUs += 16_666   // ~60 fps spacing; PTS only needs to be monotonic for display
                            if (++fed <= 2) log("fed input #$fed (${frame.size}B)")
                        }
                        heldInput = -1
                    }
                }
                var outIdx = c.dequeueOutputBuffer(info, 0)
                if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) log("output format: ${c.outputFormat}")
                while (outIdx >= 0) {
                    c.releaseOutputBuffer(outIdx, true)   // render to the Surface
                    if (++rendered == 1) log("FIRST FRAME RENDERED ✓")
                    outIdx = c.dequeueOutputBuffer(info, 0)
                }
            }
        } catch (e: Exception) {
            log("decoder loop err $e")
        }
    }

    fun stop() {
        running = false
        worker?.interrupt()
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
    }

    companion object {
        fun mimeFor(codec: String): String =
            if (codec.equals("hevc", true) || codec.equals("h265", true)) "video/hevc" else "video/avc"
    }
}
