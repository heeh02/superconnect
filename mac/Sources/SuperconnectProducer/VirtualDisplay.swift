import Foundation
import CoreGraphics
import CGVirtualDisplayPrivate

/// Configuration for a Superconnect virtual display.
public struct VirtualDisplayConfig {
    public var name: String
    /// Logical (point) resolution apps see.
    public var pointWidth: Int
    public var pointHeight: Int
    /// Backing scale: 1 = LoDPI, 2 = HiDPI/Retina (backing pixels = points × scale).
    public var scale: Int
    public var widthMM: Double
    public var heightMM: Double
    public var refreshRate: Double
    /// When true, create the virtual display as a wide-gamut HDR reference display so
    /// macOS composites HDR content with EDR headroom (instead of tone-mapping to SDR).
    public var hdr: Bool = false

    /// Default ~ a 12.2" tablet at 2560×1600 backing (Huawei MatePad-class):
    /// logical 1280×800 points at 2× → 2560×1600 pixels, HiDPI.
    public init(name: String = "Superconnect Display",
                pointWidth: Int = 1280,
                pointHeight: Int = 800,
                scale: Int = 2,
                widthMM: Double = 262.0,
                heightMM: Double = 164.0,
                refreshRate: Double = 60,
                hdr: Bool = false) {
        self.name = name
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.refreshRate = refreshRate
        self.hdr = hdr
    }
}

/// Wraps the private CGVirtualDisplay API to create a true EXTENDED display.
/// The display exists only while this object is retained and the process lives.
public final class VirtualDisplay {
    private let display: CGVirtualDisplay
    public let config: VirtualDisplayConfig
    public let displayID: CGDirectDisplayID

    /// Designated initializer — full control over the listed mode and the
    /// descriptor's max backing pixels (the two together determine HiDPI).
    private init(explicit config: VirtualDisplayConfig,
                 modeWidth: Int, modeHeight: Int,
                 maxPixelsWide: Int, maxPixelsHigh: Int,
                 hiDPI: Bool) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = config.name
        descriptor.maxPixelsWide = UInt32(maxPixelsWide)
        descriptor.maxPixelsHigh = UInt32(maxPixelsHigh)
        descriptor.sizeInMillimeters = CGSize(width: config.widthMM, height: config.heightMM)
        descriptor.productID = 0x0053       // 'S'
        descriptor.vendorID = 0x0043        // 'C'
        descriptor.serialNum = 0x0001
        if config.hdr {
            // BT.2020 primaries + D65 white — wide gamut for an HDR display.
            descriptor.redPrimary   = CGPoint(x: 0.708, y: 0.292)
            descriptor.greenPrimary = CGPoint(x: 0.170, y: 0.797)
            descriptor.bluePrimary  = CGPoint(x: 0.131, y: 0.046)
            descriptor.whitePoint   = CGPoint(x: 0.3127, y: 0.3290)
        }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        if config.hdr {
            // Reference mode = HDR: makes macOS advertise EDR headroom for this display.
            settings.isReference = true
        }
        // List the native rate FIRST (becomes the default/current mode) plus 60 Hz
        // as a selectable fallback on high-refresh panels. Offering ≥2 refresh rates
        // at one resolution is what makes macOS System Settings render a Refresh-Rate
        // selector at all — with a single mode it shows none. Each listed rate also
        // gets a HiDPI variant, so the selector appears at the Retina resolution.
        var rates: [Double] = [config.refreshRate]
        if config.refreshRate > 60 { rates.append(60) }
        rates = Array(Set(rates)).sorted(by: >)
        settings.modes = rates.map {
            let m = CGVirtualDisplayMode(width: UInt32(modeWidth),
                                         height: UInt32(modeHeight),
                                         refreshRate: $0)
            if config.hdr {
                // Per-mode transfer function (private ivar). 16 = SMPTE ST.2084 / PQ
                // (ITU-T H.273 transfer_characteristics) — marks the mode as HDR.
                m.setValue(NSNumber(value: 16), forKey: "transferFunction")
            }
            return m
        }
        _ = display.apply(settings)

        self.display = display
        self.displayID = display.displayID
        self.config = config

        // macOS may bring a multi-mode display up on the lowest listed rate; pin it
        // to the native rate so it genuinely composites at e.g. 120 Hz (and Settings
        // reflects 120, not 60).
        forceMode(pointW: modeWidth, pixelW: maxPixelsWide, refresh: config.refreshRate)
    }

    /// Pin the active mode to the (pointW, pixelW, refresh) variant if it exists.
    /// No-op if the matching mode isn't found or is already current.
    private func forceMode(pointW: Int, pixelW: Int, refresh: Double) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return }
        guard let target = modes.first(where: {
            $0.width == pointW && $0.pixelWidth == pixelW && abs($0.refreshRate - refresh) < 1.0
        }) else { return }
        if let cur = CGDisplayCopyDisplayMode(displayID),
           abs(cur.refreshRate - refresh) < 1.0, cur.pixelWidth == pixelW { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, target, nil)
        _ = CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    /// Refresh rate (Hz) of the current mode, as macOS reports it (0 if unknown).
    /// Used to verify the display genuinely composites at the negotiated rate.
    public func currentRefreshRate() -> Double {
        CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
    }

    /// Standard initializer. Lists the logical point size as the mode and sizes
    /// the backing store to points × scale so HiDPI engages correctly.
    public convenience init(_ config: VirtualDisplayConfig = VirtualDisplayConfig()) {
        let scale = max(1, config.scale)
        self.init(explicit: config,
                  modeWidth: config.pointWidth,
                  modeHeight: config.pointHeight,
                  maxPixelsWide: config.pointWidth * scale,
                  maxPixelsHigh: config.pointHeight * scale,
                  hiDPI: scale > 1)
    }

    /// Experimental initializer — set the listed mode and max backing pixels
    /// independently (used by superconnect-probe to characterize HiDPI behavior).
    public convenience init(name: String, modeWidth: Int, modeHeight: Int,
                            maxPixelsWide: Int, maxPixelsHigh: Int, hiDPI: Bool,
                            widthMM: Double = 262, heightMM: Double = 164,
                            refreshRate: Double = 60) {
        let cfg = VirtualDisplayConfig(name: name, pointWidth: modeWidth, pointHeight: modeHeight,
                                       scale: hiDPI ? 2 : 1, widthMM: widthMM, heightMM: heightMM,
                                       refreshRate: refreshRate)
        self.init(explicit: cfg, modeWidth: modeWidth, modeHeight: modeHeight,
                  maxPixelsWide: maxPixelsWide, maxPixelsHigh: maxPixelsHigh, hiDPI: hiDPI)
    }

    // MARK: - Validation helpers (CoreGraphics, no TCC needed)

    public func isActiveInCoreGraphics() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.contains(displayID)
    }

    public func isMirrored() -> Bool {
        CGDisplayIsInMirrorSet(displayID) != 0
    }

    public func bounds() -> CGRect {
        CGDisplayBounds(displayID)
    }

    public func pixelSize() -> (width: Int, height: Int) {
        (Int(CGDisplayPixelsWide(displayID)), Int(CGDisplayPixelsHigh(displayID)))
    }

    /// Point (logical) and pixel (backing) dimensions of the current mode.
    /// HiDPI working ⇒ pixel == point × 2.
    public func modeInfo() -> (pointW: Int, pointH: Int, pixelW: Int, pixelH: Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            let p = pixelSize(); return (p.width, p.height, p.width, p.height)
        }
        return (mode.width, mode.height, mode.pixelWidth, mode.pixelHeight)
    }

    /// True backing-store pixels of the current mode.
    public func backingPixelSize() -> (width: Int, height: Int) {
        let m = modeInfo(); return (m.pixelW, m.pixelH)
    }
}
