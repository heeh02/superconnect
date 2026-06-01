import Foundation

/// Thin wrapper around the HarmonyOS `hdc` CLI: locate it, list connected (wired)
/// devices, and open a USB port-forward for a specific device. Used by `WiredDiscovery`
/// (enumeration) and `HdcFportTunnel` (per-device tunnel).
enum HdcTool {
    /// Resolve the hdc binary. On Apple Silicon, prefer the copy bundled inside the app (so the user
    /// needs NO DevEco install). The bundled hdc is arm64 (from the Apple-Silicon HarmonyOS SDK) — on
    /// an Intel Mac an arm64 binary CANNOT run (Rosetta only translates x86→arm, not arm→x86), so on
    /// x86_64 we skip the bundle and fall back to a system hdc (DevEco Studio / HarmonyOS Command Line
    /// Tools, which are x86_64 on Intel). NOTE: if a UNIVERSAL hdc is ever bundled, drop the arch guard.
    static func path() -> String? {
        let fm = FileManager.default
        #if arch(arm64)
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("hdc/hdc").path
            if fm.isExecutableFile(atPath: bundled) {
                dequarantineBundledIfNeeded(res.appendingPathComponent("hdc").path)
                return bundled
            }
        }
        #endif
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
        let out = run(hdc, ["list", "targets"]).output
        return out
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && $0 != "Empty" }
    }

    /// Forward `tcp:<local>` on this Mac to `tcp:<remote>` on the given device. The LOCAL port must be
    /// unique per device (so several tablets don't collide on one Mac, #51); the REMOTE port is the
    /// tablet's fixed listen port inside its own process (same value on every tablet is fine).
    @discardableResult
    static func fport(serial: String, local: UInt16, remote: UInt16) -> Bool {
        guard let hdc = path() else { return false }
        let r = run(hdc, ["-t", serial, "fport", "tcp:\(local)", "tcp:\(remote)"])
        // Trust the exit code, and reject explicit failure text — do NOT treat empty stdout as
        // success (on Intel's system hdc a silent failure would otherwise look like a live tunnel,
        // sending us into a connect-retry loop instead of a clear error). (review P3)
        guard r.exit == 0 else { return false }
        let o = r.output.lowercased()
        return !(o.contains("fail") || o.contains("error") || o.contains("cannot") || o.contains("unable"))
    }

    static func killFport(serial: String, local: UInt16, remote: UInt16) {
        guard let hdc = path() else { return }
        _ = run(hdc, ["-t", serial, "fport", "rm", "tcp:\(local)", "tcp:\(remote)"])
    }

    // MARK: - Process helper

    /// Run a CLI and return its combined stdout+stderr and exit status. (Output is small for hdc, so
    /// reading the pipes after the process closes them won't deadlock.)
    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> (output: String, exit: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return ("", -1) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
        return (out, p.terminationStatus)
    }
}
