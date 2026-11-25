// Engine — loads the recording and slides, pulls out the sound, transcribes it on this Mac,
// reads each slide, and works out when each slide should appear.

import Foundation
import AppKit
import AVFoundation
import PDFKit
import Speech
import Vision

struct Slide: Identifiable {
    let id = UUID()
    let number: Int
    let url: URL
    var text = ""
    var size = CGSize(width: 1920, height: 1080)
    var thumb: NSImage?
}

/// One line of what was said, with its time in the recording.
struct Line: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

/// "Show slide N from this time."
struct Cue: Identifiable, Equatable {
    var id = UUID()
    var slide: Int        // index into slides
    var start: Double
}

@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published var recording: URL?
    @Published var duration: Double = 0
    @Published var slides: [Slide] = []
    @Published var slidesSource: URL?
    @Published var lines: [Line] = []
    @Published var cues: [Cue] = []
    @Published var status: String?
    @Published var problem: String?
    @Published var note: String?
    @Published var busy = false

    let work: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("PareSlides-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    /// The extracted sound: 44.1 kHz 16-bit stereo WAV (what Camtasia likes).
    private(set) var audioWAV: URL?
    private var audioFor: URL?

    var ready: Bool { recording != nil && !slides.isEmpty }
    var hasResult: Bool { !cues.isEmpty }

    // MARK: Inputs

    func setRecording(_ url: URL) {
        recording = url
        audioWAV = nil
        audioFor = nil
        lines = []
        cues = []
        problem = nil
        Task {
            let asset = AVURLAsset(url: url)
            duration = (try? await asset.load(.duration).seconds) ?? 0
            if duration.isNaN { duration = 0 }
        }
    }

    func setSlides(_ urls: [URL]) {
        problem = nil
        busy = true
        status = "Reading the slides…"
        let work = self.work
        Task {
            do {
                let files = try await Task.detached { try SlideLoader.load(urls, work: work) }.value
                guard !files.isEmpty else { throw PGError("No slide images found. Use a zip or folder of JPG/PNG images, or a PDF.") }
                var list: [Slide] = []
                for (i, f) in files.enumerated() {
                    var s = Slide(number: i + 1, url: f)
                    if let img = NSImage(contentsOf: f) {
                        if let rep = img.representations.first, rep.pixelsWide > 0 {
                            s.size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                        }
                        s.thumb = img
                    }
                    list.append(s)
                }
                slides = list
                slidesSource = urls.first
                cues = []
            } catch { problem = error.localizedDescription }
            busy = false
            status = nil
        }
    }

    // MARK: Processing

    func process() {
        guard let rec = recording, !slides.isEmpty, !busy else { return }
        busy = true
        problem = nil
        note = nil
        let work = self.work
        let slideFiles = slides.map(\.url)
        Task {
            defer { busy = false; status = nil }
            do {
                // 1. Sound
                if audioWAV == nil || audioFor != rec {
                    status = "Taking the sound out of the recording…"
                    audioWAV = try await Audio.extract(rec, work: work)
                    audioFor = rec
                }
                guard let wav = audioWAV else { return }
                if duration <= 0, let f = try? AVAudioFile(forReading: wav) {
                    duration = Double(f.length) / f.processingFormat.sampleRate
                }
                // 2. Words, with times
                if lines.isEmpty {
                    status = "Listening to the recording (on this Mac)… this takes a little while for long videos."
                    lines = try await Transcriber.transcribe(wav)
                    guard !lines.isEmpty else { throw PGError("No speech was found in the recording.") }
                }
                // 3. Slide text
                if slides.contains(where: { $0.text.isEmpty }) {
                    status = "Reading the text on each slide…"
                    let texts = await Task.detached { slideFiles.map(SlideReader.text) }.value
                    for i in slides.indices where i < texts.count { slides[i].text = texts[i] }
                }
                // 4. Match
                status = ClaudeCLI.find() != nil ? "Claude is matching the slides to what's said…" : "Matching the slides to what's said…"
                let ls = lines, sl = slides, dur = duration
                var result: [Cue] = []
                if ClaudeCLI.find() != nil {
                    do { result = try await Matcher.claude(lines: ls, slides: sl) }
                    catch { note = "Claude couldn't do the matching (\(error.localizedDescription.prefix(120))), so Pare Slides matched by itself. Check the change points." }
                } else {
                    note = "Matched without Claude. For better matching, click Connect Claude."
                }
                if result.isEmpty {
                    result = await Task.detached { Matcher.local(lines: ls, slides: sl, duration: dur) }.value
                }
                cues = Matcher.tidy(result, slideCount: sl.count, duration: dur)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The slide on screen at a given time.
    func cueIndex(at t: Double) -> Int? {
        cues.lastIndex { $0.start <= t + 0.001 } ?? (cues.isEmpty ? nil : 0)
    }

    func end(of i: Int) -> Double { i + 1 < cues.count ? cues[i + 1].start : duration }

    func setStart(_ id: UUID, _ t: Double) {
        guard let i = cues.firstIndex(where: { $0.id == id }) else { return }
        cues[i].start = min(max(0, t), max(0, duration - 0.1))
        cues.sort { $0.start < $1.start }
    }

    func insert(slide: Int, at t: Double) {
        cues.append(Cue(slide: slide, start: min(max(0, t), duration)))
        cues.sort { $0.start < $1.start }
    }

    func remove(_ id: UUID) { cues.removeAll { $0.id == id } }
}

// MARK: - Slides from a zip, folder, PDF or images

enum SlideLoader {
    static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "webp"]

    static func load(_ urls: [URL], work: URL) throws -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for u in urls {
            let ext = u.pathExtension.lowercased()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                found += images(in: u)
            } else if ext == "zip" {
                let dest = work.appendingPathComponent("slides-\(UUID().uuidString.prefix(6))")
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                guard Tools.runQuick("/usr/bin/ditto", ["-x", "-k", u.path, dest.path]) == 0 else {
                    throw PGError("Couldn't open \(u.lastPathComponent).")
                }
                found += images(in: dest)
            } else if ext == "pdf" {
                found += try pdfPages(u, work: work)
            } else if imageTypes.contains(ext) {
                found.append(u)
            }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func images(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let f as URL in en {
            if f.path.contains("__MACOSX") { continue }
            if imageTypes.contains(f.pathExtension.lowercased()) { out.append(f) }
        }
        return out
    }

    /// Each PDF page as a 1920-pixel-wide PNG.
    static func pdfPages(_ url: URL, work: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: url) else { throw PGError("Couldn't open \(url.lastPathComponent).") }
        let dir = work.appendingPathComponent("pdf-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let w: CGFloat = 1920, h = (w * box.height / max(1, box.width)).rounded()
            guard let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: w / box.width, y: h / box.height)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            guard let img = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { continue }
            let f = dir.appendingPathComponent(String(format: "Slide %03d.png", i + 1))
            try png.write(to: f)
            out.append(f)
        }
        return out
    }
}

enum SlideReader {
    /// The words on a slide (Apple's on-device text recognition).
    static func text(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

// MARK: - Sound

enum Audio {
    /// Takes the sound out of a video or audio file as 44.1 kHz 16-bit stereo WAV.
    static func extract(_ url: URL, work: URL) async throws -> URL {
        let fm = FileManager.default
        let m4a = work.appendingPathComponent("voice-\(UUID().uuidString.prefix(6)).m4a")
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw PGError("That file has no sound.")
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw PGError("Couldn't read the sound.")
        }
        export.outputURL = m4a
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { throw export.error ?? PGError("Couldn't read the sound.") }
        let wav = work.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " voice.wav")
        try? fm.removeItem(at: wav)
        let status = await Task.detached {
            Tools.runQuick("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@44100", "-c", "2", m4a.path, wav.path])
        }.value
        try? fm.removeItem(at: m4a)
        guard status == 0 else { throw PGError("Couldn't convert the sound.") }
        return wav
    }
}

// MARK: - Speech to text (on this Mac)

enum Transcriber {
    static func transcribe(_ url: URL) async throws -> [Line] {
        if #available(macOS 26.0, *) {
            do {
                let l = try await modern(url)
                if !l.isEmpty { return l }
            } catch {
                // fall back to the older engine below
            }
        }
        return try await legacy(url)
    }

    /// macOS 26's speech engine: handles long recordings well.
    @available(macOS 26.0, *)
    static func modern(_ url: URL) async throws -> [Line] {
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-AU"))
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) }
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale else { throw PGError("English speech recognition isn't available on this Mac.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collect = Task { () -> [Line] in
            var words: [(String, Double, Double)] = []
            var out: [Line] = []
            for try await r in transcriber.results {
                // Word timings where available, so long results can be split into short lines.
                var got = false
                for run in r.text.runs {
                    guard let tr = run.audioTimeRange else { continue }
                    let w = String(r.text[run.range].characters)
                    if w.trimmed.isEmpty { continue }
                    words.append((w, tr.start.seconds, tr.end.seconds))
                    got = true
                }
                if !got {
                    let t = String(r.text.characters).trimmed
                    if !t.isEmpty { out.append(Line(start: r.range.start.seconds, end: r.range.end.seconds, text: t)) }
                }
            }
            return out + Transcriber.group(words)
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.sorted { $0.start < $1.start }
    }

    /// The older engine (macOS 14–15), on-device where possible.
    static func legacy(_ url: URL) async throws -> [Line] {
        let auth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard auth == .authorized else {
            throw PGError("Pare Slides needs Speech Recognition permission: System Settings › Privacy & Security › Speech Recognition.")
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-AU")) ?? SFSpeechRecognizer(), rec.isAvailable else {
            throw PGError("Speech recognition isn't available right now.")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let once = Once()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Line], Error>) in
            rec.recognitionTask(with: req) { result, error in
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.timestamp + $0.duration) }
                    if once.claim() { c.resume(returning: Transcriber.group(words)) }
                } else if let error {
                    if once.claim() { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Words → short lines (about 12 words, or a new line after a pause or a full stop).
    static func group(_ words: [(String, Double, Double)]) -> [Line] {
        var out: [Line] = []
        var cur: [String] = []
        var s = 0.0, e = 0.0
        for (w, ws, we) in words.sorted(by: { $0.1 < $1.1 }) {
            let pause = !cur.isEmpty && ws - e > 0.8
            if pause || cur.count >= 12 {
                out.append(Line(start: s, end: e, text: cur.joined(separator: " ")))
                cur = []
            }
            if cur.isEmpty { s = ws }
            cur.append(w.trimmed)
            e = we
            if let last = w.trimmed.last, ".?!".contains(last), cur.count >= 4 {
                out.append(Line(start: s, end: e, text: cur.joined(separator: " ")))
                cur = []
            }
        }
        if !cur.isEmpty { out.append(Line(start: s, end: e, text: cur.joined(separator: " "))) }
        return out
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: - Matching what's said to the slides

enum Matcher {
    /// Claude reads the transcript and the slides and decides when each slide starts.
    static func claude(lines: [Line], slides: [Slide]) async throws -> [Cue] {
        let transcript = lines.map { String(format: "[%.1f] ", $0.start) + $0.text }.joined(separator: "\n")
        let deck = slides.map { "Slide \($0.number): \($0.text.isEmpty ? "(picture only, no text)" : String($0.text.prefix(700)))" }
            .joined(separator: "\n")
        let prompt = """
        You are syncing a slide deck to a recording of the presenter talking through it. Below are the \
        transcript lines with their start times in seconds, and the text on each slide.
        Decide when each slide should appear on screen.
        Rules:
        - Slides almost always go in order. A slide the presenter never talks about may be skipped.
        - The first slide shown starts at 0.
        - Put each change at the start time of the transcript line where the presenter starts talking about \
        that slide's content (or says things like "next", "moving on", "let's look at").
        - A slide with no text (a picture) usually sits between the slides around it; include it if the talk moves through it.
        - Use only start times that appear in the transcript (or 0).
        Reply with ONLY a JSON array in time order, like [{"slide":1,"start":0},{"slide":3,"start":34.3}]. No other text.

        SLIDES
        \(deck)

        TRANSCRIPT
        \(transcript)
        """
        let reply = try await ClaudeCLI.ask(prompt)
        guard let a = reply.firstIndex(of: "["), let b = reply.lastIndex(of: "]"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PGError("Claude's answer wasn't in the expected format.")
        }
        var cues: [Cue] = []
        for item in arr {
            guard let n = (item["slide"] as? NSNumber)?.intValue,
                  let t = (item["start"] as? NSNumber)?.doubleValue, n >= 1, n <= slides.count else { continue }
            cues.append(Cue(slide: n - 1, start: t))
        }
        guard !cues.isEmpty else { throw PGError("Claude didn't place any slides.") }
        return cues
    }

    /// Without Claude: match words in each line to words on the slides, keeping the slides in order.
    static func local(lines: [Line], slides: [Slide], duration: Double) -> [Cue] {
        guard !lines.isEmpty, !slides.isEmpty else { return [Cue(slide: 0, start: 0)] }
        let stop: Set<String> = Set("""
        the a an and or of to in on for with is are be that this it i you your we our my me so as at by from have has was were \
        will can not but do just there what how they their them about also very really lots some here then than when which who
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) }
        }
        let slideWords = slides.map { Set(words($0.text)) }
        var df: [String: Int] = [:]
        for s in slideWords { for w in s { df[w, default: 0] += 1 } }
        let n = Double(slides.count)
        func idf(_ w: String) -> Double { log((n + 1) / (Double(df[w] ?? 0) + 0.5)) }
        // Score of every line against every slide.
        let S: [[Double]] = lines.map { l in
            let ws = words(l.text)
            return slideWords.map { sw in
                ws.filter { sw.contains($0) }.reduce(0) { $0 + idf($1) } / sqrt(Double(1 + ws.count))
            }
        }
        // Best path that only moves forward through the slides, with a small cost for each change
        // and for each slide skipped.
        let change = 0.8, skip = 0.5
        let L = lines.count, K = slides.count
        var best = Array(repeating: Array(repeating: -Double.infinity, count: K), count: L)
        var back = Array(repeating: Array(repeating: 0, count: K), count: L)
        for k in 0..<K { best[0][k] = S[0][k] - Double(k) * skip }
        for i in 1..<L {
            for k in 0..<K {
                var bestPrev = best[i - 1][k], arg = k
                for j in 0..<k {
                    let v = best[i - 1][j] - change - Double(k - j - 1) * skip
                    if v > bestPrev { bestPrev = v; arg = j }
                }
                best[i][k] = bestPrev + S[i][k]
                back[i][k] = arg
            }
        }
        var k = (0..<K).max { best[L - 1][$0] < best[L - 1][$1] } ?? 0
        var path = [Int](repeating: 0, count: L)
        for i in stride(from: L - 1, through: 0, by: -1) {
            path[i] = k
            if i > 0 { k = back[i][k] }
        }
        var cues: [Cue] = []
        for (i, k) in path.enumerated() where cues.last?.slide != k {
            cues.append(Cue(slide: k, start: i == 0 ? 0 : lines[i].start))
        }
        return cues
    }

    /// Sorted, starting at 0, no two cues on top of each other.
    static func tidy(_ cues: [Cue], slideCount: Int, duration: Double) -> [Cue] {
        var c = cues.filter { $0.slide >= 0 && $0.slide < slideCount }.sorted { $0.start < $1.start }
        guard !c.isEmpty else { return [Cue(slide: 0, start: 0)] }
        c[0].start = 0
        var out: [Cue] = []
        for cue in c {
            if let last = out.last, cue.start - last.start < 0.5 { out[out.count - 1] = Cue(slide: cue.slide, start: last.start); continue }
            if duration > 0, cue.start >= duration { continue }
            out.append(cue)
        }
        return out
    }
}
