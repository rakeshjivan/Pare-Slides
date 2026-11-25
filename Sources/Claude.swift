// Claude, through your Claude subscription: Pare Slides runs the official Claude Code tool
// ("claude -p") that you sign in to once (Google sign-in works). No API key, no extra cost.
// (Same approach as Pare Guide.)

import Foundation
import AppKit

enum ClaudeCLI {
    private static let lock = NSLock()
    private static var cached: String??

    /// Where the `claude` tool is installed, if it is.
    static func find() -> String? {
        if let c = lock.withLock({ cached }) { return c }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude",
                          "\(home)/.volta/bin/claude"]
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // Ask a login shell, which knows the user's PATH.
            let r = run("/bin/zsh", ["-lc", "command -v claude"], cwd: nil, env: nil, timeout: 10)
            let p = r.out.trimmed
            if r.status == 0, !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { found = p }
        }
        lock.withLock { cached = .some(found) }
        return found
    }

    /// Look again next time (after installing Claude Code).
    static func forgetLocation() { lock.withLock { cached = nil } }

    /// Environment for claude: the user's normal one, minus anything that would switch it to paid API billing.
    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK",
                  "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] { e[k] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        e["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                     "/usr/bin", "/bin", "/usr/sbin", "/sbin", e["PATH"] ?? ""].joined(separator: ":")
        return e
    }

    /// Quick check from Settings: is it installed and signed in?
    static func test() async -> String {
        forgetLocation()
        guard find() != nil else { return "Claude Code isn't installed." }
        do {
            let reply = try await ask("Reply with just the word OK.")
            return reply.uppercased().contains("OK") ? "Working. Steps will use your Claude subscription." : "Claude Code replied: \(reply.prefix(80))"
        } catch { return error.localizedDescription }
    }

    /// A text-only question.
    static func ask(_ prompt: String) async throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pareguide-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await call(prompt, in: dir, allowRead: false)
    }

    private static func call(_ prompt: String, in dir: URL, allowRead: Bool) async throws -> String {
        guard let exe = find() else { throw PGError("Claude Code isn't installed.") }
        var args = ["-p", prompt, "--output-format", "text", "--model", "sonnet"]
        if allowRead { args += ["--allowedTools", "Read"] }
        let environment = env
        let r = await Task.detached(priority: .userInitiated) {
            run(exe, args, cwd: dir, env: environment, timeout: 300)
        }.value
        if r.timedOut { throw PGError("Claude Code took too long to answer.") }
        let text = r.out.trimmed
        guard r.status == 0, !text.isEmpty else {
            let detail = r.err.trimmed.isEmpty ? text : r.err.trimmed
            let lower = detail.lowercased()
            if lower.contains("login") || lower.contains("log in") || lower.contains("authenticat") || lower.contains("api key") {
                throw PGError("Claude isn't connected yet. Click Connect Claude in Pare Slides.")
            }
            if lower.contains("limit") || lower.contains("credit") || lower.contains("quota") || lower.contains("usage") {
                throw PGError("Your Claude allowance is used up for now. \(detail.prefix(160))")
            }
            throw PGError("Claude Code: \(detail.isEmpty ? "no answer" : String(detail.prefix(200)))")
        }
        return text
    }

    struct Result { var status: Int32; var out: String; var err: String; var timedOut: Bool }

    static func run(_ exe: String, _ args: [String], cwd: URL?, env: [String: String]?, timeout: TimeInterval) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if let env { p.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription, timedOut: false) }
        // Read both pipes while it runs so a long reply can't block it.
        let box = PipeBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { box.set(out: outPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter()
        DispatchQueue.global().async { box.set(err: errPipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = group.wait(timeout: .now() + 5)
        }
        p.waitUntilExit()
        let (o, e) = box.get()
        return Result(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self),
                      err: String(decoding: e, as: UTF8.self), timedOut: timedOut)
    }
}

// MARK: - Connect Claude (install + sign in, no Terminal)

extension ClaudeCLI {
    /// Installs Claude Code with Anthropic's official installer.
    static func install() async throws {
        let environment = env
        let r = await Task.detached {
            run("/bin/bash", ["-c", "curl -fsSL https://claude.ai/install.sh | bash"], cwd: nil, env: environment, timeout: 600)
        }.value
        forgetLocation()
        guard find() != nil else {
            let tail = (r.err.trimmed.isEmpty ? r.out : r.err).trimmed.suffix(200)
            throw PGError("Installing Claude Code didn't work. \(tail)")
        }
    }

    /// Whether Claude Code is signed in, and as whom.
    static func authStatus() async -> (loggedIn: Bool, who: String) {
        guard let exe = find() else { return (false, "") }
        let environment = env
        let r = await Task.detached { run(exe, ["auth", "status"], cwd: nil, env: environment, timeout: 20) }.value
        let text = r.out + "\n" + r.err
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
        let loggedIn = r.status == 0 && !lower.contains("notloggedin") && !lower.contains("\"loggedin\":false")
        var who = ""
        if let re = try? NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: .caseInsensitive),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range, in: text) {
            who = String(text[range])
        }
        return (loggedIn, who)
    }
}

@MainActor
final class ClaudeConnect: ObservableObject {
    static let shared = ClaudeConnect()

    enum Phase: Equatable { case unknown, notConnected, installing, signingIn, connected(String), failed(String) }

    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var signInURL: URL?

    private var process: Process?
    private var stdin: Pipe?
    private var output = ""
    private var triedWithoutFlag = false

    func refresh() async {
        guard ClaudeCLI.find() != nil else { phase = .notConnected; return }
        let s = await ClaudeCLI.authStatus()
        phase = s.loggedIn ? .connected(s.who) : .notConnected
    }

    func connect() {
        guard phase != .installing, phase != .signingIn else { return }
        Task {
            if ClaudeCLI.find() == nil {
                phase = .installing
                do { try await ClaudeCLI.install() } catch {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
            let s = await ClaudeCLI.authStatus()
            if s.loggedIn { phase = .connected(s.who); return }
            triedWithoutFlag = false
            startLogin(withFlag: true)
        }
    }

    private func startLogin(withFlag: Bool) {
        guard let exe = ClaudeCLI.find() else { phase = .failed("Claude Code isn't installed."); return }
        phase = .signingIn
        signInURL = nil
        output = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        // --claudeai picks "Claude account with subscription" rather than paid API (Console) billing.
        p.arguments = withFlag ? ["auth", "login", "--claudeai"] : ["auth", "login"]
        p.environment = ClaudeCLI.env
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let chunk = String(decoding: d, as: UTF8.self)
            Task { @MainActor in ClaudeConnect.shared.received(chunk) }
        }
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in ClaudeConnect.shared.finished(code, usedFlag: withFlag) }
        }
        do { try p.run() } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        process = p
        stdin = input
    }

    private func received(_ chunk: String) {
        output += chunk
        if signInURL == nil,
           let re = try? NSRegularExpression(pattern: #"https://[^\s"'<>]+"#),
           let m = re.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let r = Range(m.range, in: output) {
            signInURL = URL(string: String(output[r]))
        }
    }

    private func finished(_ code: Int32, usedFlag: Bool) {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdin = nil
        let lower = output.lowercased()
        if code != 0, usedFlag, !triedWithoutFlag,
           lower.contains("unknown option") || lower.contains("unknown argument") || lower.contains("unexpected argument") {
            triedWithoutFlag = true
            startLogin(withFlag: false)
            return
        }
        Task {
            let s = await ClaudeCLI.authStatus()
            if s.loggedIn {
                phase = .connected(s.who)
            } else if case .signingIn = phase {
                let tail = output.trimmed.split(separator: "\n").suffix(2).joined(separator: " ")
                phase = .failed(tail.isEmpty ? "Sign-in didn't finish. Try again." : "Sign-in didn't finish: \(tail.prefix(200))")
            }
        }
    }

    /// For when the browser shows a code to paste back instead of returning by itself.
    func submitCode(_ code: String) {
        stdin?.fileHandleForWriting.write(Data((code.trimmed + "\n").utf8))
    }

    func cancel() {
        process?.terminate()
        phase = .notConnected
    }
}

private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func set(out d: Data) { lock.withLock { out = d } }
    func set(err d: Data) { lock.withLock { err = d } }
    func get() -> (Data, Data) { lock.withLock { (out, err) } }
}

