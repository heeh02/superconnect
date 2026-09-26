package com.superconnect.receiver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class FossVideoCodecProfileTest {
    @Test
    fun everyAdvertisedCodecIsAcceptedRoutedAndMappedToItsDecoderMime() {
        var routedCodec: String? = null
        var transportFailures = 0
        val router = SessionFrameRouter(
            isReady = { true },
            videoConsumer = { null },
            videoConfigConsumer = {{ _, _, codec, _, _ -> routedCodec = codec }},
            streamingStarted = {},
            sendControl = {},
            closeRequested = {},
            authReceived = {},
            helloReceived = {},
            receiveCapability = {},
            receiveIntentProfile = {},
            receiveIntent = {},
            failTransport = { transportFailures += 1 },
            log = {},
        )

        val advertised = DeviceInfo.advertisedCodecs()
        assertEquals(listOf("h264"), advertised)
        advertised.forEach { codec ->
            val wireCodec = VideoConfigWireNative.wireCodec(codec)
            assertNotNull("advertised codec $codec has no accepted canonical wire mapping", wireCodec)
            val config = VideoConfigWireNative.decodeRecord(intArrayOf(
                checkNotNull(wireCodec),
                1,
                1920,
                1080,
                60,
                0,
            ))
            assertNotNull("advertised codec $codec is rejected by VideoConfigWireNative", config)
            routedCodec = null
            router.routeVideoConfig(checkNotNull(config))
            assertEquals(codec, routedCodec)
            assertEquals(
                when (codec) {
                    "h264" -> "video/avc"
                    "hevc" -> "video/hevc"
                    else -> error("unexpected advertised codec $codec")
                },
                VideoDecoder.mimeFor(checkNotNull(routedCodec)),
            )
        }
        assertEquals(0, transportFailures)
        assertNull(
            "HEVC must remain fail-closed until the canonical consumer is implemented",
            VideoConfigWireNative.decodeRecord(intArrayOf(2, 1, 1920, 1080, 60, 0)),
        )
    }
}
