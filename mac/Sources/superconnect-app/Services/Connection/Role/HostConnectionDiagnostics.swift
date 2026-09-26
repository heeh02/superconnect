import Foundation

/// Bounded local diagnostics for the FOSS host connection.
enum HostConnectionDiagnostics {
    /// Append a diagnostic line to /tmp/sc-mac-diag.log (NSLog isn't captured for this app).
    /// Self-bounding: resets the file once it passes ~256 KB so it can never eat disk; /tmp is also
    /// cleared by macOS on reboot.
    static func write(_ s: String) {
        let path = "/tmp/sc-mac-diag.log"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 256 * 1024 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let line = s + "\n"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        }
    }


}
