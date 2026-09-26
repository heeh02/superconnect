package com.superconnect.receiver

import android.content.Context
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager

/** Receiver screen caps advertised to the Mac in hello_ack (it sizes the virtual display to these). */
data class ReceiverCaps(
    val codecs: List<String>,
    val pen: Boolean,
    val screenWidth: Int,    // native pixels
    val screenHeight: Int,   // native pixels
    val scale: Float,        // density (points = pixels / scale)
    val refreshRate: Float,
)

/** Device name, screen caps, and a stable per-install peer id — the Android analogue of HarmonyOS
 *  DeviceIdentity. Generic across brands; a brand layer can refine the name later. */
object DeviceInfo {
    fun deviceName(): String {
        val model = Build.MODEL ?: "Android"
        val mfr = Build.MANUFACTURER ?: ""
        return if (mfr.isNotEmpty() && !model.startsWith(mfr, ignoreCase = true)) "$mfr $model" else model
    }

    @Suppress("DEPRECATION")
    fun caps(context: Context): ReceiverCaps {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val dm = DisplayMetrics()
        wm.defaultDisplay.getRealMetrics(dm)   // real (full) resolution; defaultDisplay works back to API 24
        return ReceiverCaps(
            codecs = supportedDecoders(),
            pen = true,
            screenWidth = dm.widthPixels,
            screenHeight = dm.heightPixels,
            scale = dm.density,
            refreshRate = wm.defaultDisplay.refreshRate,
        )
    }

    /** Advertise only codecs accepted by this composition's canonical video_config consumer.
     *  Hardware decoder presence alone is insufficient: HEVC stays deferred until the config route
     *  can preserve and deliver that codec without failing the authenticated Session. */
    private fun supportedDecoders(): List<String> = advertisedCodecs()

    internal fun advertisedCodecs(): List<String> = VideoConfigWireNative.advertisedCodecs
}
