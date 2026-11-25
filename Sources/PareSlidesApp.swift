// Pare Slides — put slides on screen at the right moments in a recorded talk.
// Drop in the recording and the slides, click Match, check the change points, and export
// a Camtasia project (or an MP4).

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct PareSlidesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Pare Slides") {
            MainView()
                .frame(minWidth: 1080, minHeight: 700)
                .task { await Updater.shared.checkNow() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.install(relaunch: false) }
    }
}

// MARK: - Playback

@MainActor
final class Player: ObservableObject {
    static let shared = Player()
    @Published var time: Double = 0
    @Published var playing = false
    private var player: AVPlayer?
    private var observer: Any?
    private var loaded: URL?

    func load(_ url: URL?) {
        guard url != loaded else { return }
        if let o = observer { player?.removeTimeObserver(o) }
        loaded = url
        player = url.map { AVPlayer(url: $0) }
        playing = false
        time = 0
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.time = t.seconds
                self?.playing = (self?.player?.rate ?? 0) > 0
            }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.rate > 0 { p.pause() } else { p.play() }
        playing = p.rate > 0
    }

    func play(from t: Double) {
        seek(t)
        player?.play()
        playing = true
    }

    func seek(_ t: Double) {
        player?.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = t
    }
}

// MARK: - Main window

struct MainView: View {
    @ObservedObject private var s = Session.shared
    @ObservedObject private var connect = ClaudeConnect.shared
    @State private var showConnect = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.angled").font(.title2).foregroundStyle(Color.accentColor)
                Text("Pare Slides").font(.title2.weight(.semibold))
                Spacer()
                UpdateButton(busy: s.busy)
                Button { showConnect.toggle() } label: {
                    if case .connected = connect.phase {
                        Label("Claude connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Connect Claude", systemImage: "link")
                    }
                }
                .popover(isPresented: $showConnect) { ClaudeConnectView().padding(16).frame(width: 380) }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            UpdateBanner(busy: s.busy).padding(.horizontal, 18)
            Divider()
            if s.hasResult { EditorView() } else { SetupView() }
        }
        .task { await connect.refresh() }
    }
}

// MARK: - Step 1: choose files

struct SetupView: View {
    @ObservedObject private var s = Session.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Put the slides on screen at the right moments in recorded talks.")
                    .font(.title3).foregroundStyle(.secondary)
                HStack(spacing: 20) {
                    DropCard(title: "1. Recordings", icon: "waveform",
                             hint: "Drop one or more videos or audio files here (MP4, MOV, M4A, MP3, WAV)",
                             detail: s.jobs.isEmpty ? nil : (s.jobs.count == 1 ? "1 recording" : "\(s.jobs.count) recordings") + " · drop more to add",
                             types: [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio],
                             multiple: true) { urls in
                        s.addRecordings(urls)
                    }
                    DropCard(title: "2. Slide deck", icon: "rectangle.stack",
                             hint: "Drop the deck: a zip or folder of slide images, or a PDF. One deck can serve all the recordings.",
                             detail: s.slides.isEmpty ? nil : "\(s.slides.count) slides",
                             types: [.zip, .folder, .pdf, .image], multiple: true) { urls in
                        s.setSlides(urls)
                    }
                }
                if !s.slides.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(s.slides) { sl in
                                VStack(spacing: 3) {
                                    thumb(sl).frame(width: 96, height: 54)
                                    Text("\(sl.number)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 76)
                }
                if !s.jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Recordings").font(.headline)
                            Spacer()
                            Text("Slide range is optional: fill it in if a recording only uses part of the deck.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(s.jobs) { job in
                                RecordingRow(job: job)
                                if job.id != s.jobs.last?.id { Divider() }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                    }
                }
                HStack(spacing: 12) {
                    if s.waitingCount > 0 || !s.anyDone {
                        Button {
                            s.processAll()
                        } label: {
                            Label(matchTitle, systemImage: "wand.and.stars")
                                .font(.title3.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!s.ready || s.busy)
                    }
                    if s.anyDone {
                        Button {
                            if s.current?.isDone != true { s.selected = s.jobs.first { $0.isDone }?.id }
                            s.showResults = true
                        } label: {
                            Label("Check & Export", systemImage: "checklist").padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .controlSize(.large)
                    }
                }
                StatusLine()
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
    }

    private var matchTitle: String {
        let n = s.anyDone ? s.waitingCount : s.jobs.count
        if s.anyDone { return n == 1 ? "3. Match the New Recording" : "3. Match the \(n) New Recordings" }
        return n <= 1 ? "3. Match Slides to Recording" : "3. Match All \(n) Recordings"
    }

    @ViewBuilder func thumb(_ sl: Slide) -> some View {
        if let t = sl.thumb {
            Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
        }
    }
}

struct JobStateView: View {
    let state: Job.State
    var body: some View {
        switch state {
        case .waiting: Label("Waiting", systemImage: "clock").foregroundStyle(.secondary)
        case .working(let what): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(what) }
        case .done: Label("Matched", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let why): Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
        }
    }
}

struct RecordingRow: View {
    let job: Job
    @ObservedObject private var s = Session.shared
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ["m4a", "mp3", "wav", "aif", "aiff", "aac", "caf"].contains(job.recording.pathExtension.lowercased())
                  ? "waveform" : "film")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recording.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(job.duration > 0 ? clock(job.duration) : " ").font(.caption).foregroundStyle(.secondary)
            }
            .frame(minWidth: 200, alignment: .leading)
            Spacer()
            JobStateView(state: job.state).font(.callout).frame(maxWidth: 300, alignment: .trailing)
            HStack(spacing: 4) {
                Text("Slides").font(.callout).foregroundStyle(.secondary)
                TextField("first", text: $from).frame(width: 46).multilineTextAlignment(.center).onSubmit(apply)
                Text("to").font(.callout).foregroundStyle(.secondary)
                TextField("last", text: $to).frame(width: 46).multilineTextAlignment(.center).onSubmit(apply)
            }
            .disabled(s.busy || s.slides.isEmpty)
            .help("Optional. If this recording only uses part of the deck, enter its first and last slide numbers.")
            Button { s.removeJob(job.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).disabled(s.busy).help("Remove this recording")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onAppear { from = job.from.map(String.init) ?? ""; to = job.to.map(String.init) ?? "" }
        .onChange(of: from) { _, _ in apply() }
        .onChange(of: to) { _, _ in apply() }
    }

    private func apply() {
        s.setRange(job.id, from: Int(from.trimmed), to: Int(to.trimmed))
    }
}

struct StatusLine: View {
    @ObservedObject private var s = Session.shared
    var body: some View {
        VStack(spacing: 6) {
            if let st = s.status { HStack { ProgressView().controlSize(.small); Text(st) } }
            if let p = s.problem { Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if let n = s.note, s.status == nil { Text(n).font(.callout).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
    }
}

struct DropCard: View {
    let title: String
    let icon: String
    let hint: String
    let detail: String?
    let types: [UTType]
    var multiple = false
    let onFiles: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: detail == nil ? icon : "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(detail == nil ? Color.secondary : Color.green)
            Text(title).font(.headline)
            Text(detail ?? hint).font(.callout).foregroundStyle(detail == nil ? .secondary : .primary)
                .multilineTextAlignment(.center).lineLimit(3)
            Button(detail == nil ? "Choose…" : "Change…") { choose() }
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .dropDestination(for: URL.self) { urls, _ in
            onFiles(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.canChooseDirectories = types.contains(.folder)
        panel.allowsMultipleSelection = multiple
        if panel.runModal() == .OK { onFiles(panel.urls) }
    }
}

// MARK: - Step 2: check and export

struct EditorView: View {
    @ObservedObject private var s = Session.shared
    @ObservedObject private var player = Player.shared
    @State private var includeVideo = false
    @State private var exporting: String?
    @State private var exportError: String?

    private var current: Int? { s.cueIndex(at: player.time) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let job = s.current, job.isDone {
                HStack(spacing: 0) {
                    cueList.frame(width: 330)
                    Divider()
                    VStack(spacing: 12) {
                        preview
                        transport
                        Divider()
                        exportBar
                    }
                    .padding(16)
                    Divider()
                    transcript.frame(width: 360)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    if let job = s.current { JobStateView(state: job.state).font(.title3) }
                    Text("This recording isn't matched yet. Pick another from the menu, or wait for it to finish.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: s.audioWAV) { player.load(s.current?.isDone == true ? s.audioWAV : nil) }
        .onChange(of: s.current?.isDone) { _, done in if done == true { player.load(s.audioWAV) } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { player.load(nil); s.showResults = false } label: { Label("Files", systemImage: "chevron.left") }
            if s.jobs.count > 1 {
                Picker("Recording", selection: $s.selected) {
                    ForEach(s.jobs) { j in
                        Text(j.name + (j.isDone ? "" : "  (not matched yet)")).tag(Optional(j.id))
                    }
                }
                .frame(maxWidth: 420)
                Text("\(s.jobs.filter(\.isDone).count) of \(s.jobs.count) matched").font(.callout).foregroundStyle(.secondary)
            } else if let j = s.current {
                Text(j.recording.lastPathComponent).font(.headline)
            }
            if let st = s.status, s.busy { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(st).foregroundStyle(.secondary) } }
            Spacer()
            if s.jobs.count > 1 {
                Button { exportAll() } label: { Label("Export All Camtasia Projects…", systemImage: "square.and.arrow.up.on.square") }
                    .disabled(!s.anyDone || exporting != nil)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // Slides with their start times
    private var cueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Slide changes").font(.headline)
                Spacer()
                Menu {
                    ForEach(s.slides.indices, id: \.self) { i in
                        Button("Slide \(s.slides[i].number)") { s.insert(slide: i, at: player.time) }
                    }
                } label: { Label("Add at \(clock(player.time))", systemImage: "plus") }
                    .fixedSize()
            }
            .padding(12)
            List {
                ForEach(s.cues) { c in
                    CueRow(cue: c, isCurrent: s.cues.firstIndex(of: c) == current)
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Match Again") { if let id = s.selected { s.rematch(id) } }.disabled(s.busy)
                    .help("Throw away these change points and match this recording again")
            }
            .padding(12)
        }
    }

    private var preview: some View {
        Group {
            if let i = current, i < s.cues.count, let img = s.slides[s.cues[i].slide].thumb {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(radius: 6, y: 2)
                    .overlay(alignment: .topLeading) {
                        Text("Slide \(s.slides[s.cues[i].slide].number)")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.ultraThinMaterial)).padding(8)
                    }
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 22) }
                .keyboardShortcut(.space, modifiers: [])
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(1, s.duration))
            Text("\(clock(player.time)) / \(clock(s.duration))").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var exportBar: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Also put the original video in the Media Bin", isOn: $includeVideo)
                    .disabled(!["mp4", "mov", "m4v"].contains(s.recording?.pathExtension.lowercased() ?? ""))
                Spacer()
                Button { export(mp4: true) } label: { Label("Export MP4…", systemImage: "film") }
                    .disabled(exporting != nil)
                Button { export(mp4: false) } label: {
                    Label("Export Camtasia Project…", systemImage: "square.and.arrow.up").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(exporting != nil)
            }
            if let e = exporting { HStack { ProgressView().controlSize(.small); Text(e) } }
            if let e = exportError { Text(e).foregroundStyle(.orange) }
            if let n = s.current?.note { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's said").font(.headline).padding(12)
            ScrollViewReader { proxy in
                List(s.lines) { line in
                    LineRow(line: line, isNow: player.time >= line.start && player.time < line.end)
                        .id(line.id)
                }
                .listStyle(.inset)
                .onChange(of: player.time) { _, t in
                    if player.playing, let l = s.lines.last(where: { $0.start <= t }) { proxy.scrollTo(l.id, anchor: .center) }
                }
            }
        }
    }

    private func export(mp4: Bool) {
        guard let job = s.current, let plan = s.plan(for: job, includeRecording: includeVideo) else { return }
        let base = job.name
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = base + (mp4 ? " with slides.mp4" : ".cmproj")
        if mp4 { panel.allowedContentTypes = [.mpeg4Movie] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportError = nil
        exporting = mp4 ? "Making the video…" : "Making the Camtasia project…"
        Task {
            do {
                if mp4 {
                    try await Export.mp4(plan, to: url) { f in
                        Task { @MainActor in exporting = "Making the video… \(Int(f * 100))%" }
                    }
                } else {
                    try await Task.detached { try Export.camtasia(plan, to: url) }.value
                }
                let shown = mp4 || url.pathExtension.lowercased() == "cmproj" ? url : url.appendingPathExtension("cmproj")
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            } catch {
                exportError = "Export failed: \(error.localizedDescription)"
            }
            exporting = nil
        }
    }
}

extension EditorView {
    func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder. Each matched recording becomes its own Camtasia project."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let plans = s.jobs.compactMap { s.plan(for: $0, includeRecording: includeVideo) }
        let skipped = s.jobs.count - plans.count
        exportError = nil
        Task {
            var made: [URL] = []
            var failed: [String] = []
            for (i, plan) in plans.enumerated() {
                exporting = "Making Camtasia project \(i + 1) of \(plans.count)…"
                var url = folder.appendingPathComponent(plan.title + ".cmproj")
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = folder.appendingPathComponent("\(plan.title) \(n).cmproj"); n += 1
                }
                let target = url
                do {
                    try await Task.detached { try Export.camtasia(plan, to: target) }.value
                    made.append(target)
                } catch { failed.append(plan.title) }
            }
            exporting = nil
            var msg: [String] = []
            if !failed.isEmpty { msg.append("Couldn't export: " + failed.joined(separator: ", ")) }
            if skipped > 0 { msg.append("\(skipped) recording\(skipped == 1 ? " isn't" : "s aren't") matched yet, so \(skipped == 1 ? "it was" : "they were") left out.") }
            exportError = msg.isEmpty ? nil : msg.joined(separator: " ")
            if !made.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(made) }
        }
    }
}

struct CueRow: View {
    let cue: Cue
    let isCurrent: Bool
    @ObservedObject private var s = Session.shared
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if cue.slide < s.slides.count, let t = s.slides[cue.slide].thumb {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                } else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                    lineWidth: isCurrent ? 2.5 : 1))
            VStack(alignment: .leading, spacing: 4) {
                Menu("Slide \(cue.slide < s.slides.count ? s.slides[cue.slide].number : 0)") {
                    ForEach(s.slides.indices, id: \.self) { i in
                        Button("Slide \(s.slides[i].number)") {
                            if let k = s.cues.firstIndex(where: { $0.id == cue.id }) { s.cues[k].slide = i }
                        }
                    }
                }
                .fixedSize()
                HStack(spacing: 4) {
                    Button { s.setStart(cue.id, cue.start - 0.5) } label: { Image(systemName: "minus") }
                        .help("Half a second earlier")
                    TextField("0:00.0", text: $text)
                        .frame(width: 64)
                        .multilineTextAlignment(.center)
                        .onSubmit { if let t = parseClock(text) { s.setStart(cue.id, t) } else { text = clock(cue.start) } }
                    Button { s.setStart(cue.id, cue.start + 0.5) } label: { Image(systemName: "plus") }
                        .help("Half a second later")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
            VStack(spacing: 6) {
                Button { Player.shared.play(from: max(0, cue.start - 1.5)) } label: { Image(systemName: "play.circle") }
                    .help("Play from just before this change")
                Button { s.remove(cue.id) } label: { Image(systemName: "trash") }
                    .help("Remove this slide change")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .onAppear { text = clock(cue.start) }
        .onChange(of: cue.start) { _, v in text = clock(v) }
    }
}

struct LineRow: View {
    let line: Line
    let isNow: Bool
    @ObservedObject private var s = Session.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(clock(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
            Text(line.text).font(.callout).fontWeight(isNow ? .semibold : .regular)
            Spacer(minLength: 0)
            Menu {
                ForEach(s.slides.indices, id: \.self) { i in
                    Button("Slide \(s.slides[i].number)") { s.insert(slide: i, at: line.start) }
                }
            } label: { Image(systemName: "rectangle.badge.plus") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change to a slide here")
        }
        .contentShape(Rectangle())
        .onTapGesture { Player.shared.play(from: line.start) }
        .listRowBackground(isNow ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

struct ClaudeConnectView: View {
    @ObservedObject private var connect = ClaudeConnect.shared
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch connect.phase {
            case .unknown:
                ProgressView().controlSize(.small)
            case .connected(let who):
                Label(who.isEmpty ? "Connected to your Claude account" : "Connected as \(who)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .installing:
                HStack { ProgressView().controlSize(.small); Text("Installing Claude Code (about a minute)…") }
            case .signingIn:
                HStack { ProgressView().controlSize(.small); Text("Finish in your browser: **Continue with Google**, then **Authorize**.") }
                if let url = connect.signInURL {
                    Link("Browser didn't open? Click here to sign in", destination: url).font(.callout)
                }
                HStack {
                    TextField("If the page shows a code, paste it here", text: $code)
                    Button("Submit") { connect.submitCode(code); code = "" }.disabled(code.trimmed.isEmpty)
                }
                Button("Cancel") { connect.cancel() }.controlSize(.small)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { connect.connect() }
            case .notConnected:
                Button {
                    connect.connect()
                } label: {
                    Label("Connect Claude", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                Text("Installs Claude Code if needed, then opens claude.ai in your browser so you can sign in (Google works). One time per Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await connect.refresh() }
    }
}
