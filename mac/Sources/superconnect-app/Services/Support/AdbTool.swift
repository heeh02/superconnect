import Foundation

/// Thin wrapper around the Android `adb` CLI — the wired bridge for ANDROID tablets (Huawei Android /
/// generic Android), mirroring `HdcTool` for HarmonyOS. Locate adb, list authorized devices, read a
/// friendly name, and open a USB port-forward. Used by `AndroidWiredDiscovery` (enumeration) and
/// `AdbFportTunnel` (per-device tunnel). adb's wire to the device-side adbd is brand-agnostic, so one
/// path covers every Android tablet; brand-specific niceties (names, etc.) layer on top later.
enum AdbTool {
    /// Resolve the adb binary. Prefer a copy bundled in the app (self-contained, no Android SDK needed);
    /// platform-tools' adb is a UNIVERSAL macOS binary, so a single `adb/adb` serves both arches (no
    /// per-arch split like hdc). Falls back to a system adb (Android SDK platform-tools / Homebrew).
    static func path() -> String? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            for rel in ["adb/adb", "adb/\(archDir)/adb"] {   // flat (universal) first, then a per-arch dir
                let bundled = res.appendingPathComponent(rel).path
                if fm.isExecutableFile(atPath: bundled) {
                    dequarantineBundledIfNeeded(res.appendingPathComponent("adb").path)
                    return bundled
                }
            }
        }
        let candidates = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    #if arch(arm64)
    private static let archDir = "arm64"
    #else
    private static let archDir = "x86_64"
    #endif

    /// Serials of currently-attached, AUTHORIZED devices (`adb devices`). Skips the header and any
    /// `offline`/`unauthorized` entries (those can't be forwarded; the user must accept the RSA prompt).
    static func listDevices() -> [String] {
        guard let adb = path() else { return [] }
        let out = run(adb, ["devices"]).output
        return out
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .dropFirst()                                   // "List of devices attached"
            .compactMap { line -> String? in
                let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard cols.count >= 2, cols[1] == "device" else { return nil }   // only ready devices
                return cols[0]
            }
    }

    /// A friendly device name: Huawei's `ro.product.marketname` (e.g. "HUAWEI MatePad 11.5") when
    /// present, else the generic `ro.product.model`. nil if adb can't read it.
    static func deviceName(serial: String) -> String? {
        guard let adb = path() else { return nil }
        for prop in ["ro.product.marketname", "ro.config.marketing_name", "ro.product.model"] {
            let r = run(adb, ["-s", serial, "shell", "getprop", prop])
            let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.exit == 0, !name.isEmpty, !name.lowercased().contains("error") { return name }
        }
        return nil
    }

    /// Forward `tcp:<local>` on this Mac to `tcp:<remote>` on the device. LOCAL is unique per device
    /// (several tablets on one Mac, #51); REMOTE is the Android receiver's fixed listen port.
    @discardableResult
    static func forward(serial: String, local: UInt16, remote: UInt16) -> Bool {
        guard let adb = path() else { return false }
        let r = run(adb, ["-s", serial, "forward", "tcp:\(local)", "tcp:\(remote)"])
        guard r.exit == 0 else { return false }
        let o = r.output.lowercased()
        return !(o.contains("fail") || o.contains("error") || o.contains("cannot") || o.contains("unable"))
    }

    static func removeForward(serial: String, local: UInt16) {
        guard let adb = path() else { return }
        _ = run(adb, ["-s", serial, "forward", "--remove", "tcp:\(local)"])
    }

    // MARK: - quarantine + process helpers (same shape as HdcTool)

    private static var dequarantined = false
    private static func dequarantineBundledIfNeeded(_ dir: String) {
        guard !dequarantined else { return }
        dequarantined = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", dir]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> (output: String, exit: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return ("", -1) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        return (out, p.terminationStatus)
    }
}
