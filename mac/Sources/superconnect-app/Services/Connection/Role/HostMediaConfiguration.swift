import Foundation
import SuperconnectProducer

/// Negotiated display/codec settings, separate from connection lifecycle.
enum HostMediaConfiguration {
    /// Build a virtual display matching ANY tablet's panel from its reported caps. Adapts to
    /// arbitrary resolution + refresh; clamps the long edge to an encoder-safe size (preserving
    /// aspect) and forces even pixels so the H.264/HEVC encoder is happy on any device.
    static func displayConfig(from caps: [String: Any]?) -> VirtualDisplayConfig {
        guard let caps,
              let rawW = (caps["screenWidth"] as? NSNumber)?.intValue,
              let rawH = (caps["screenHeight"] as? NSNumber)?.intValue,
              rawW >= 640, rawH >= 400 else { return VirtualDisplayConfig() }
        let scale = 2
        var pw = rawW, ph = rawH
        // Cap the long edge (codec level limits) preserving aspect — a no-op for current tablets.
        let maxEdge = 4096
        if max(pw, ph) > maxEdge {
            let f = Double(maxEdge) / Double(max(pw, ph))
            pw = Int((Double(pw) * f).rounded()); ph = Int((Double(ph) * f).rounded())
        }
        // Backing pixels divisible by 2×scale ⇒ whole point dims and even pixels (encoder-safe).
        let step = 2 * scale
        pw -= pw % step; ph -= ph % step
        let reported = (caps["refreshRate"] as? NSNumber)?.doubleValue ?? 60
        let refresh = max(30, min(120, reported))
        return VirtualDisplayConfig(pointWidth: pw / scale, pointHeight: ph / scale, scale: scale, refreshRate: refresh)
    }

    static func codec(from caps: [String: Any]?) -> VideoCodec {
        // Compatibility escape hatch (AppViewModel's 编码 toggle): force H.264 even if the tablet offers
        // HEVC, for devices whose HEVC decoder misbehaves. Read here so it applies at session build.
        if UserDefaults.standard.bool(forKey: "sc.forceH264") { return .h264 }
        if let arr = caps?["codecs"] as? [Any], arr.compactMap({ $0 as? String }).contains("hevc") { return .hevc }
        return .h264
    }

    /// HDR10/PQ negotiation. GATED OFF (2026-05-31): a private CGVirtualDisplay cannot report
    /// EDR>1.0, so macOS tone-maps HDR→SDR before capture (no real benefit). The HDR transport
    /// is intact — flip this back on when the source can be HDR (e.g. a DriverKit HDR display).
    static func hdrEnabled(from caps: [String: Any]?) -> Bool {
        _ = caps
        return false
    }
}
