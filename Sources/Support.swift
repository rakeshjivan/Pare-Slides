// Small shared helpers.

import Foundation

struct PGError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum Tools {
    @discardableResult
    static func runQuick(_ path: String, _ args: [String], cwd: URL? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func download(_ url: String, to dest: URL) async throws {
        guard let u = URL(string: url) else { throw PGError("Bad address") }
        let (tmp, resp) = try await URLSession.shared.download(from: u)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PGError("Download failed") }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// "1:05.3"
func clock(_ s: Double) -> String {
    let t = max(0, s)
    let m = Int(t) / 60
    let rest = t - Double(m * 60)
    return String(format: "%d:%04.1f", m, rest)
}

/// Reads "1:05.3", "65.3" or "1:05".
func parseClock(_ s: String) -> Double? {
    let parts = s.trimmed.split(separator: ":").map(String.init)
    if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) { return m * 60 + sec }
    if parts.count == 1, let sec = Double(parts[0]) { return sec }
    return nil
}
