import Foundation

/// Thin wrapper around the HarmonyOS `hdc` CLI: locate it, list connected (wired)
/// devices, and open a USB port-forward for a specific device. Used by `WiredDiscovery`
/// (enumeration) and `HdcFportTunnel` (per-device tunnel).
enum HdcTool {
    /// Resolve the hdc binary. Prefer the copy bundled inside the app (so the user needs NO
    /// DevEco install); fall back to a DevEco Studio / HarmonyOS-CLI location on dev machines.
    static func path() -> String? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("hdc/hdc").path
            if fm.isExecutableFile(atPath: bundled) {
                dequarantineBundledIfNeeded(res.appendingPathComponent("hdc").path)
                return bundled
            }
        }
        let candidates = [
            "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
            "/Applications/DevEco-Studio.app/Contents/tools/hdc/hdc",
            "\(NSHomeDirectory())/command-line-tools/sdk/default/openharmony/toolchains/hdc",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // A downloaded app's nested binaries can keep the com.apple.quarantine flag, which Gatekeeper
    // uses to block the app from spawning them. Clear it once (best-effort) so the bundled hdc runs
    // without the user having to touch the terminal.
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

    /// Serials of currently-attached devices (`hdc list targets`). Empty if hdc missing
    /// or nothing connected. "[Empty]" sentinel is filtered out.
    static func listTargets() -> [String] {
        guard let hdc = path() else { return [] }
        let out = run(hdc, ["list", "targets"])
        return out
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && $0 != "Empty" }
    }

    /// Forward `tcp:port` on this Mac to `tcp:port` on the given device.
    @discardableResult
    static func fport(serial: String, port: UInt16) -> Bool {
        guard let hdc = path() else { return false }
        let out = run(hdc, ["-t", serial, "fport", "tcp:\(port)", "tcp:\(port)"])
        return out.localizedCaseInsensitiveContains("OK") || out.isEmpty
    }

    static func killFport(serial: String, port: UInt16) {
        guard let hdc = path() else { return }
        _ = run(hdc, ["-t", serial, "fport", "rm", "tcp:\(port)", "tcp:\(port)"])
    }

    // MARK: - Process helper

    private static func run(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
