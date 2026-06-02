import Foundation

/// Thin wrapper around the HarmonyOS `hdc` CLI: locate it, list connected (wired)
/// devices, and open a USB port-forward for a specific device. Used by `WiredDiscovery`
/// (enumeration) and `HdcFportTunnel` (per-device tunnel).
enum HdcTool {
    /// Resolve the hdc binary. Prefer the copy bundled inside the app (so the user needs NO DevEco
    /// install). Bundled hdc uses a PER-ARCH layout — `hdc/arm64/hdc` and `hdc/x86_64/hdc` — and each
    /// slice of the universal app binary looks in its OWN arch dir (`#if arch`), because an arm64 hdc
    /// cannot run on Intel (Rosetta is x86→arm only) and vice-versa. Falls back to the legacy flat
    /// `hdc/hdc` layout, then to a system hdc (DevEco / HarmonyOS Command Line Tools). If the matching
    /// arch dir is empty (e.g. no x86_64 hdc bundled yet on an Intel Mac), the system hdc is used.
    static func path() -> String? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            #if arch(arm64)
            let archDir = "hdc/arm64"
            #else
            let archDir = "hdc/x86_64"
            #endif
            for rel in ["\(archDir)/hdc", "hdc/hdc"] {   // per-arch first, then legacy flat layout
                let bundled = res.appendingPathComponent(rel).path
                if fm.isExecutableFile(atPath: bundled) {
                    dequarantineBundledIfNeeded(res.appendingPathComponent("hdc").path)   // whole tree (incl. libusb)
                    return bundled
                }
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
        let out = run(hdc, ["list", "targets"]).output
        return out
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && $0 != "Empty" }
    }

    /// The device's friendly market name (e.g. "HUAWEI MatePad Pro") via `param get const.product.name`,
    /// so the wired card shows the real name in the list — not just the hdc serial. nil if unavailable.
    static func deviceName(serial: String) -> String? {
        guard let hdc = path() else { return nil }
        let r = run(hdc, ["-t", serial, "shell", "param", "get", "const.product.name"])
        guard r.exit == 0 else { return nil }
        let name = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()
        guard !name.isEmpty, !lower.contains("fail"), !lower.contains("error") else { return nil }
        return name
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
