import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Observation
import MonetShotKit

/// Everything the editor window shows and does. Views read it and call its
/// methods; nothing else changes it. Every edit rebuilds the renderer, swaps
/// the player's video composition (so the preview is the real render) and
/// saves edit.json shortly after.
///
/// Times here are output times (the finished video's clock) unless a name
/// says take time: the video is clips from one or more takes, in order.
@MainActor
@Observable
final class EditorModel {
    private(set) var project: Project
    private(set) var renderer: Renderer
    private(set) var time: Double = 0
    private(set) var playing = false
    /// Filmstrip frames per take, `thumbStep` seconds apart.
    private(set) var thumbnails: [Int: [CGImage]] = [:]
    static let thumbStep: Double = 0.5
    var selectedID: UUID?
    /// nil when idle; 0...1 while exporting.
    private(set) var exportProgress: Double?
    private(set) var exportedURL: URL?
    private(set) var exportError: String?
    /// Snapshot mode only: a rendered still shown instead of the live player
    /// (an offscreen window can't capture an AVPlayerLayer).
    var stillFrame: CGImage?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    /// The segment as it was when a drag began, so a drag is always relative
    /// to where it started (no drift from accumulating small moves).
    @ObservationIgnored private var dragOrigin: ZoomSegment?
    /// The text being edited in the inspector, and one being dragged on the timeline.
    var selectedTextID: UUID?
    @ObservationIgnored var textOrigin: TextOverlay?

    /// The music browser, shown over the editor.
    let musicBrowser = MusicBrowserModel()
    var showingMusic = false
    /// Peaks of the chosen song, for the snippet picker.
    private(set) var musicWave: [Float] = []
    /// The chosen song's beat and lifts, so the snippet window snaps to bar lines
    /// and can land a lift on a zoom (nil until read, or if it has no steady beat).
    private(set) var musicGrid: MusicGrid?
    @ObservationIgnored private var musicOrigin: Double?

    init(project: Project) {
        self.project = project
        renderer = EditorModel.renderer(for: project, framing: false)
        player.actionAtItemEnd = .pause
        musicBrowser.onUse = { [weak self] track in await self?.useMusic(track) ?? false }
        musicBrowser.editor = self
    }

    // Captions (the rest is in EditorCaptions.swift).
    /// 0...1 while transcribing.
    var transcribing: Double?
    var transcribeError: String?
    @ObservationIgnored var transcribeTask: Task<Void, Never>?
    /// The transcript word being fixed (its place in `captionWords`), and the spelling so far.
    var editingWord: Int?
    var wordDraft = ""
    /// The languages on-device speech knows (filled when the section first shows).
    var speechLanguages: [Locale] = []
    var language = Transcriber.language { didSet { Transcriber.language = language } }
    var autoTranscribeOn = Transcriber.automatic { didSet { Transcriber.automatic = autoTranscribeOn } }
    var subtitlesOn = EditorModel.writeSubtitles { didSet { EditorModel.writeSubtitles = subtitlesOn } }

    /// Take `k`'s transcript changed: the captions follow at once.
    func setTranscript(_ t: Transcript?, take k: Int) {
        guard project.takes.indices.contains(k) else { return }
        project.takes[k].transcript = t
        renderer = makeRenderer()
        scheduleRebuild()
    }

    var doc: EditDoc { project.edit }
    /// Length of the finished video.
    var duration: Double { renderer.map.duration }
    /// The clips, in play order.
    var clips: [Clip] { project.clips }
    func takeDuration(_ take: Int) -> Double { project.duration(ofTake: take) }
    var selected: ZoomSegment? { doc.segments.first { $0.id == selectedID } }
    var title: String { Library.title(for: project.folder) }

    // MARK: lifecycle

    func load() async {
        await rebuildComposition()
        seek(to: 0)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let ended = ObjectIdentifier(n.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let item = self.item, ObjectIdentifier(item) == ended else { return }
                self.playing = false
                if case .recording = self.cameraPhase { Task { await self.stopCamera() } }
            }
        }
        autoTranscribe()
        for i in project.takes.indices { await makeThumbnails(take: i) }
        await loadMusicWave()
        Log.info("editor loaded \(project.name): \(project.takes.count) take(s), \(clips.count) clip(s), \(String(format: "%.1f", duration))s")
    }

    func close() {
        if cameraPhase != .off { closeCamera() }
        transcribeTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        saveTask?.cancel()
        try? project.saveEdit()
    }

    private func tick(_ t: Double) {
        guard t.isFinite, !seeking else { return }
        time = t
    }

    /// While a seek is in flight the time observer reports the old position.
    @ObservationIgnored private var seeking = false

    // MARK: transport

    func togglePlay() {
        if playing {
            player.pause()
            playing = false
        } else {
            if time >= duration - 0.05 { seek(to: 0) }
            player.play()
            playing = true
        }
    }

    func seek(to t: Double) {
        let clamped = min(max(0, t), duration)
        time = clamped
        let out = min(clamped, max(0, duration - 0.001))
        seeking = true
        player.seek(to: CMTime(seconds: out, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
    }

    func step(frames: Int) {
        if playing { togglePlay() }
        seek(to: time + Double(frames) / Double(Composer.fps))
    }

    // MARK: edits

    func update(_ edit: (inout EditDoc) -> Void) {
        var next = project.edit
        edit(&next)
        guard next != project.edit else { return }
        checkpoint()
        apply(next)
    }

    private func apply(_ next: EditDoc) {
        project.edit = next
        renderer = makeRenderer()
        scheduleRebuild()
        scheduleSave()
    }

    // MARK: undo

    @ObservationIgnored private var undoStack: [EditDoc] = []
    @ObservationIgnored private var redoStack: [EditDoc] = []
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Saves the edit as it is before a change. A burst of changes (a drag,
    /// a slider) is one step: only the first in each 0.6 s is kept.
    private func checkpoint() {
        let now = Date()
        defer { lastCheckpoint = now }
        guard now.timeIntervalSince(lastCheckpoint) > 0.6 else { return }
        undoStack.append(project.edit)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project.edit)
        lastCheckpoint = .distantPast
        apply(prev)
        canUndo = !undoStack.isEmpty
        canRedo = true
        clampSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project.edit)
        lastCheckpoint = .distantPast
        apply(next)
        canUndo = true
        canRedo = !redoStack.isEmpty
        clampSelection()
    }

    private func clampSelection() {
        if let i = selectedClip, !clips.indices.contains(i) { selectedClip = nil }
        if let id = selectedID, !doc.segments.contains(where: { $0.id == id }) { selectedID = nil }
        if let id = selectedBlurID, !doc.blurs.contains(where: { $0.id == id }) { selectedBlurID = nil }
        if time > duration { seek(to: duration) }
    }

    func select(_ id: UUID?) {
        selectedID = id
        if id != nil { selectedClip = nil; selectedBlurID = nil; selectedTextID = nil }
    }

    /// Adds a zoom at output time `t` (default: the playhead), on the footage there.
    func addZoom(at t: Double? = nil) {
        let p = renderer.map.locate(t ?? time)
        guard let seg = SegmentEdits.insert(at: p.time, into: doc.segments, duration: takeDuration(p.take), take: p.take) else { return }
        update { $0.segments.append(seg); $0.segments.sort { $0.start < $1.start } }
        selectedID = seg.id
    }

    func deleteSelected() {
        if let id = selectedBlurID { deleteBlur(id); return }
        if let id = selectedTextID { deleteText(id); return }
        if selectedID == nil, let i = selectedClip { deleteClip(i); return }
        guard let id = selectedID else { return }
        update { $0.segments.removeAll { $0.id == id } }
        selectedID = nil
    }

    /// Re-runs auto zoom on every take, from the clicks that are in the video.
    func reAuto() {
        let map = renderer.map
        update { d in
            for (i, take) in project.takes.enumerated() {
                d.segments = SegmentEdits.reAuto(d.segments, clicks: take.cursor.clicks.filter { map.keeps(take: i, time: $0.t) },
                                                 duration: take.meta.duration, take: i)
            }
        }
    }

    /// Where each zoom shows on the timeline: every part of it that some clip
    /// plays, in output time.
    struct ZoomPlacement: Identifiable {
        let segment: ZoomSegment
        let start: Double
        let end: Double
        let clip: Int
        var id: String { "\(segment.id)-\(clip)" }
    }

    var zoomPlacements: [ZoomPlacement] {
        var out: [ZoomPlacement] = []
        for (i, span) in renderer.map.spans.enumerated() {
            for seg in doc.segments where seg.take == span.take && seg.end > span.start && seg.start < span.end {
                let a = max(seg.start, span.start), b = min(seg.end, span.end)
                out.append(ZoomPlacement(segment: seg, start: span.at + (a - span.start) / span.speed,
                                         end: span.at + (b - span.start) / span.speed, clip: i))
            }
        }
        return out
    }

    // MARK: clips

    private(set) var selectedClip: Int?

    private func setClips(_ c: [Clip]) {
        update { d in
            d.clips = c
            d.cuts = []
            d.trimStart = 0
            d.trimEnd = nil
        }
    }

    func selectClip(_ i: Int?) {
        selectedClip = i
        if i != nil { selectedID = nil; selectedBlurID = nil; selectedTextID = nil }
    }

    /// Selects the clip playing at output time `t`.
    func selectClip(at t: Double) {
        guard !clips.isEmpty else { return }
        selectClip(renderer.map.locate(t).index)
    }

    /// Splits the clip under the playhead (S).
    func split() {
        let at = time
        guard let next = ClipEdits.split(clips, atOutput: at) else { return }
        let index = renderer.map.locate(at).index
        setClips(next)
        selectClip(index + 1)
        Log.info(String(format: "split at %.2fs", at))
    }

    func deleteClip(_ i: Int) {
        let next = ClipEdits.delete(clips, at: i)
        guard next != clips else { return }
        setClips(next)
        selectedClip = nil
        seek(to: min(time, duration))
    }

    /// Sets clip `i`'s speed, keeping the playhead on the same footage.
    func setSpeed(_ speed: Double, clip i: Int) {
        guard clips.indices.contains(i) else { return }
        let here = renderer.map.locate(time)
        setClips(ClipEdits.setSpeed(clips, at: i, to: speed))
        seek(to: renderer.map.output(take: here.take, time: here.time) ?? ClipEdits.starts(clips)[i])
        Log.info(String(format: "clip %d speed %.2fx", i, clips[i].rate))
    }

    /// Plays every clip at `speed`.
    func setSpeedForAll(_ speed: Double) {
        let here = renderer.map.locate(time)
        setClips(clips.indices.reduce(clips) { ClipEdits.setSpeed($0, at: $1, to: speed) })
        seek(to: renderer.map.output(take: here.take, time: here.time) ?? 0)
    }

    /// Sets clip `i`'s fade in and out (output seconds).
    func setFades(clip i: Int, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard clips.indices.contains(i) else { return }
        var next = clips
        if let fadeIn { next[i].fadeIn = max(0, fadeIn) }
        if let fadeOut { next[i].fadeOut = max(0, fadeOut) }
        setClips(next)
    }

    // Edge drags (shorten / lengthen).

    @ObservationIgnored private var clipOrigin: (index: Int, leading: Bool, clips: [Clip])?

    func isDraggingClip(_ i: Int, leading: Bool) -> Bool { clipOrigin?.index == i && clipOrigin?.leading == leading }

    func beginClipDrag(_ i: Int, leading: Bool) {
        clipOrigin = (i, leading, clips)
        selectClip(i)
    }

    /// Drags clip `i`'s edge by `seconds`; the preview follows the edge so
    /// you see the frame you're cutting on.
    func dragClip(by seconds: Double) {
        guard let o = clipOrigin, o.clips.indices.contains(o.index) else { return }
        let c0 = o.clips[o.index]
        let edge = o.leading ? c0.start : c0.end
        // The drag is in output seconds; the edge moves in take time.
        let next = ClipEdits.resize(o.clips, at: o.index, leading: o.leading, to: edge + seconds * c0.rate, takeDuration: takeDuration(c0.take))
        setClips(next)
        let st = ClipEdits.starts(next)
        seek(to: o.leading ? st[o.index] : st[o.index] + next[o.index].outputDuration - 0.02)
    }

    func endClipDrag() { clipOrigin = nil }

    // Body drags (reorder).

    /// The clip being moved and how far (output seconds) it has been dragged.
    private(set) var moving: (index: Int, offset: Double)?

    func beginMove(_ i: Int) {
        moving = (i, 0)
        selectClip(i)
    }

    func move(by seconds: Double) {
        guard let m = moving else { return }
        moving = (m.index, seconds)
    }

    func endMove() {
        guard let m = moving, clips.indices.contains(m.index) else { moving = nil; return }
        moving = nil
        let st = ClipEdits.starts(clips)
        let centre = st[m.index] + clips[m.index].outputDuration / 2 + m.offset
        let to = ClipEdits.dropIndex(clips, dragging: m.index, centreAt: centre)
        guard to != m.index else { return }
        setClips(ClipEdits.move(clips, from: m.index, to: to))
        selectClip(to)
        seek(to: ClipEdits.starts(clips)[to])
    }

    // MARK: takes

    /// Starts recording a new take for this video (the app runs the recording).
    @ObservationIgnored var onRecordTake: (URL) -> Void = { _ in }

    func recordTake() {
        if playing { togglePlay() }
        try? project.saveEdit()
        onRecordTake(project.folder)
    }

    /// A take recorded into this project finished: load it and add its
    /// clips (pauses already left out) at the end, with auto zooms on its clicks.
    func takeRecorded(clips takeClips: [Clip]) {
        guard let fresh = try? Project.load(project.folder), fresh.takes.count > project.takes.count else { return }
        let added = Array(project.takes.count..<fresh.takes.count)
        project.takes = fresh.takes
        appendTakes(added, zooms: true, clips: added.count == 1 ? takeClips : nil)
    }

    /// Adds videos or other MonetShot recordings as new clips at the end.
    func addFootage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, UTType("com.connorhood.monetshot.recording") ?? .package]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = Project.libraryDir
        panel.message = "Add a video or a Monet Shot recording to the end of this one"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addFootage(urls) }
    }

    func addFootage(_ urls: [URL]) async {
        var p = project
        var added: [Int] = []
        var importedEdit = false
        for url in urls where url.standardizedFileURL != project.folder.standardizedFileURL {
            do {
                if url.pathExtension == "reel", let other = try? Project.load(url) {
                    checkpoint()
                    _ = try Imports.recording(other, into: &p)
                    importedEdit = true
                } else {
                    added.append(try await Imports.video(url, into: &p))
                }
                Log.info("added footage: \(url.lastPathComponent)")
            } catch {
                Log.error("add footage \(url.lastPathComponent): \(error)")
            }
        }
        project.takes = p.takes
        if importedEdit { update { $0 = p.edit } }
        appendTakes(added, zooms: false)
        for i in project.takes.indices where thumbnails[i] == nil { await makeThumbnails(take: i) }
    }

    private func appendTakes(_ indices: [Int], zooms: Bool, clips given: [Clip]? = nil) {
        guard !indices.isEmpty else {
            renderer = makeRenderer()
            scheduleRebuild()
            return
        }
        var c = clips
        if let given, let only = indices.first, !given.isEmpty {
            c += given.map { Clip(start: $0.start, end: $0.end, take: only) }
        } else {
            c += indices.map { Clip(start: 0, end: project.duration(ofTake: $0), take: $0) }
        }
        let firstNew = clips.count
        update { d in
            d.clips = c
            d.cuts = []
            d.trimStart = 0
            d.trimEnd = nil
            if zooms {
                for i in indices {
                    let t = project.takes[i]
                    d.segments += CameraMath.autoZooms(clicks: t.cursor.clicks, duration: t.meta.duration, take: i)
                }
            }
        }
        selectClip(firstNew)
        seek(to: ClipEdits.starts(clips)[min(firstNew, clips.count - 1)])
        Task { for i in indices { await makeThumbnails(take: i) } }
    }

    /// A filmstrip frame for take `take` near its time `time`.
    func thumbnail(take: Int, time: Double) -> CGImage? {
        guard let frames = thumbnails[take], !frames.isEmpty else { return nil }
        return frames[min(frames.count - 1, max(0, Int(time / Self.thumbStep)))]
    }

    // MARK: camera

    enum CameraPhase: Equatable {
        case off, ready, countdown(Int), recording(since: Date), saving
    }

    /// Recording yourself: off, or the live camera over the preview.
    private(set) var cameraPhase: CameraPhase = .off
    /// Record a clip of just you (added at the end) instead of over the video.
    var cameraAlone = false
    @ObservationIgnored private var cameraTask: Task<Void, Never>?
    @ObservationIgnored private var cameraTake: (file: String, at: Double)?

    var hasCamera: Bool { !doc.cameraClips.isEmpty || project.takes.contains { $0.meta.camera != nil } }

    func openCamera() {
        if playing { togglePlay() }
        guard cameraPhase == .off else { return }
        cameraPhase = .ready
        Task {
            guard await CameraRecorder.shared.acquire() else {
                cameraPhase = .off
                let alert = NSAlert()
                alert.messageText = "Monet Shot can't use the camera"
                alert.informativeText = "Allow Monet Shot in System Settings › Privacy & Security › Camera (and Microphone), then try again."
                alert.addButton(withTitle: "Open Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn,
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
        }
    }

    func closeCamera() {
        cameraTask?.cancel()
        if case .recording = cameraPhase {
            Task { await stopCamera(); CameraRecorder.shared.release() }
            return
        }
        guard cameraPhase != .off else { return }
        cameraPhase = .off
        CameraRecorder.shared.release()
    }

    /// Space in camera mode: count in, or stop.
    func toggleCameraRecording() {
        switch cameraPhase {
        case .ready: startCamera()
        case .countdown: cameraTask?.cancel(); cameraPhase = .ready
        case .recording: Task { await stopCamera() }
        default: break
        }
    }

    /// 3, 2, 1, then the camera records while the video plays (muted, so the
    /// microphone hears only you) from the playhead.
    func startCamera() {
        guard cameraPhase == .ready else { return }
        cameraTask = Task {
            for n in [3, 2, 1] {
                cameraPhase = .countdown(n)
                try? await Task.sleep(for: .seconds(0.8))
                if Task.isCancelled { return }
            }
            let file = "camera-\(Int(Date().timeIntervalSince1970)).mov"
            let alone = cameraAlone
            if !alone, time >= duration - 0.3 { seek(to: 0) }
            let at = time
            guard await CameraRecorder.shared.record(to: project.folder.appendingPathComponent(file)) != nil else {
                cameraPhase = .ready
                Log.error("camera: could not start recording")
                return
            }
            cameraTake = (file, at)
            cameraPhase = .recording(since: Date())
            if !alone {
                player.isMuted = true
                player.play()
                playing = true
            }
        }
    }

    func stopCamera() async {
        guard case .recording = cameraPhase, let take = cameraTake else { return }
        cameraTake = nil
        cameraPhase = .saving
        if playing { player.pause(); playing = false }
        player.isMuted = false
        guard let url = await CameraRecorder.shared.stop() else {
            cameraPhase = .ready
            return
        }
        let length = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        if cameraAlone {
            // A clip of its own: a new take at the end, framed like the rest.
            var p = project
            if let i = try? await Imports.video(url, into: &p) {
                try? FileManager.default.removeItem(at: url)
                project.takes = p.takes
                appendTakes([i], zooms: false)
                Log.info(String(format: "camera clip added: %.1fs", length))
            }
        } else if length > 0.3 {
            let clip = CameraClip(file: take.file, at: take.at, duration: min(length, duration - take.at))
            update { $0.cameraClips = CameraEdits.insert(clip, into: $0.cameraClips) }
            seek(to: take.at)
            Log.info(String(format: "camera over the video: %.1fs at %.1fs", clip.duration, clip.at))
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        cameraPhase = .ready
        closeCamera()
    }

    func setCameraClip(_ id: UUID, _ change: (inout CameraClip) -> Void) {
        update { d in
            guard let i = d.cameraClips.firstIndex(where: { $0.id == id }) else { return }
            change(&d.cameraClips[i])
        }
    }

    func deleteCameraClip(_ id: UUID) {
        update { $0.cameraClips.removeAll { $0.id == id } }
    }

    // MARK: music

    func openMusic() {
        if playing { togglePlay() }
        musicBrowser.setVideo(length: duration, vertical: isVertical, mood: format?.musicMood)
        showingMusic = true
    }

    func closeMusic() {
        stopAudition()
        musicBrowser.stop()
        showingMusic = false
    }

    /// A tall canvas (a phone's): the music browser suggests punchier tracks.
    var isVertical: Bool { renderer.canvas.height > renderer.canvas.width }

    /// A library track playing under the video while you choose (not yet in the edit).
    private(set) var audition: MusicChoice?

    /// Where `track` sits under this video: from a downbeat at its good start
    /// (its first lift for a vertical video), the end fade on a phrase line.
    private func fitted(_ track: Song, file: String, grid: MusicGrid?) -> MusicChoice {
        var c = MusicChoice(track: track, file: file)
        c.offset = MusicFit.place(grid: grid, songDuration: track.duration, length: duration, from: track.start, punchy: isVertical).offset
        if let m = doc.music { c.volume = m.volume; c.fadeIn = m.fadeIn; c.fadeOut = m.fadeOut }
        return c
    }

    /// Plays the edit from the top with `track` under it; again to pause or go on.
    func toggleAudition(_ track: Song) {
        if audition?.track.id == track.id {
            togglePlay()
            return
        }
        guard let url = URL(string: track.audioURL), url.isFileURL else { return }
        audition = fitted(track, file: url.path, grid: track.grid)
        Task {
            await rebuildComposition()
            seek(to: 0)
            player.play()
            playing = true
        }
    }

    /// Back to the edit's own music.
    func stopAudition() {
        guard audition != nil else { return }
        player.pause()
        playing = false
        audition = nil
        Task { await rebuildComposition() }
    }

    /// Where the audition is in its song (seconds), for the browser's waveform.
    var auditionSongTime: Double? { audition.map { $0.offset + time } }

    /// Copies the track into the recording and lays it under the video,
    /// fitted to it, keeping the level and fades of any music it replaces.
    func useMusic(_ track: Song) async -> Bool {
        do {
            let file = try await MusicCatalog.download(track, into: project.folder)
            let old = doc.music
            audition = nil
            if playing { togglePlay() }
            var track = track
            if track.grid == nil {
                // a file of your own: find its beat once, and keep it with the choice
                track.grid = await MusicGrid.analyze(project.folder.appendingPathComponent(file))
            }
            let choice = fitted(track, file: file, grid: track.grid)
            update { $0.music = choice }
            if let old, old.file != file { try? FileManager.default.removeItem(at: project.folder.appendingPathComponent(old.file)) }
            await loadMusicWave()
            closeMusic()
            Log.info("music: \(track.title) by \(track.artist) (\(track.licenseLabel)) from \(String(format: "%.2f", choice.offset)) s")
            return true
        } catch {
            Log.error("music download: \(error)")
            return false
        }
    }

    func removeMusic() {
        guard let m = doc.music else { return }
        update { $0.music = nil }
        try? FileManager.default.removeItem(at: project.folder.appendingPathComponent(m.file))
        musicWave = []
        musicGrid = nil
    }

    func setMusic(_ change: (inout MusicChoice) -> Void) {
        update { d in
            guard var m = d.music else { return }
            change(&m)
            d.music = m
        }
    }

    /// The snippet window: drags slide which part of the song plays.
    func beginMusicDrag() { musicOrigin = doc.music?.offset }
    func beginMusicDragIfNeeded() { if musicOrigin == nil { beginMusicDrag() } }

    /// `free` (Option held) leaves the grid alone.
    func dragMusic(bySeconds s: Double, free: Bool = false) {
        guard let o = musicOrigin, let m = doc.music else { return }
        let room = max(0, m.track.duration - duration)
        var want = min(max(0, o + s), room)
        if !free, let g = musicGrid { want = snapMusic(want, grid: g, room: room) }
        setMusic { $0.offset = want }
    }

    /// Where each zoom begins in the finished video.
    var zoomMoments: [Double] {
        doc.segments.compactMap { renderer.map.output(take: $0.take, time: $0.start) }.sorted()
    }

    /// A lift landing on a zoom wins when it's near; otherwise the video starts on the nearest bar line.
    private func snapMusic(_ want: Double, grid g: MusicGrid, room: Double) -> Double {
        var best: Double?
        var nearest = max(0.6, g.bar * 0.6)
        for lift in g.lifts {
            for z in zoomMoments {
                let at = lift - z
                if at >= 0, at <= room, abs(at - want) < nearest { best = at; nearest = abs(at - want) }
            }
        }
        if let best { return best }
        let line = g.nearestBarLine(want)
        return line <= room ? line : max(0, line - g.bar)
    }

    /// The lift and the zoom that meet at the current offset, if any (song time, video time).
    var musicLanding: (lift: Double, zoom: Double)? {
        guard let m = doc.music, let g = musicGrid else { return nil }
        for lift in g.lifts {
            for z in zoomMoments where abs(lift - m.offset - z) < 0.05 { return (lift, z) }
        }
        return nil
    }

    func endMusicDrag() { musicOrigin = nil }

    func copyCredit() {
        guard let t = doc.music?.track else { return }
        let text = t.attribution ?? "\"\(t.title)\" by \(t.artist), \(t.licenseLabel)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadMusicWave() async {
        guard let m = doc.music else { musicWave = []; musicGrid = nil; return }
        let url = project.folder.appendingPathComponent(m.file)
        musicWave = await MusicCatalog.waveform(url)
        if let g = m.track.grid { musicGrid = g } else { musicGrid = await MusicGrid.analyze(url) }
    }

    // MARK: backdrop picture

    /// Copies the picture into the recording (so it travels with it) and uses it.
    /// `name` is the file name to give the copy (the gallery's paintings keep
    /// theirs, so the gallery can show which is in use).
    func setBackdropImage(_ url: URL, as name: String? = nil) {
        if let name, doc.backdropImage == name {
            update { $0.backdrop = .image }
            return
        }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        let name = name ?? "backdrop-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = project.folder.appendingPathComponent(name)
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            Log.error("backdrop copy: \(error)")
            return
        }
        guard BackdropImages.load(dest) != nil else {
            try? FileManager.default.removeItem(at: dest)
            Log.error("backdrop: not an image \(url.lastPathComponent)")
            return
        }
        let old = doc.backdropImage
        update { $0.backdrop = .image; $0.backdropImage = name }
        if let old, old != name { try? FileManager.default.removeItem(at: project.folder.appendingPathComponent(old)) }
        Log.info("backdrop image set: \(url.lastPathComponent)")
    }

    func chooseBackdropImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the background"
        if panel.runModal() == .OK, let url = panel.url { setBackdropImage(url) }
    }

    var backdropImageURL: URL? { doc.backdropImage.map { project.folder.appendingPathComponent($0) } }

    func setSelected(_ change: (inout ZoomSegment) -> Void) {
        guard let id = selectedID else { return }
        update { doc in
            guard let i = doc.segments.firstIndex(where: { $0.id == id }) else { return }
            change(&doc.segments[i])
            doc.segments[i].auto = false
        }
    }

    /// Fixes the selected zoom on a point clicked in the preview (or lets it
    /// follow the cursor again with `nil`).
    func setFocus(_ p: (x: Double, y: Double)?) {
        setSelected { s in
            s.focusX = p.map { min(max($0.x, 0), 1) }
            s.focusY = p.map { min(max($0.y, 0), 1) }
        }
    }

    /// Maps a point in the preview (top-left origin, in a view of `size` that
    /// aspect-fits the canvas) to the recording's normalised coordinates at the
    /// current time; nil if it falls outside the framed recording.
    func contentPoint(at p: CGPoint, in size: CGSize) -> (x: Double, y: Double)? {
        let c = renderer.canvas
        let k = min(size.width / c.width, size.height / c.height)
        let shown = CGSize(width: c.width * k, height: c.height * k)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        let cx = (p.x - origin.x) / k, cyTop = (p.y - origin.y) / k
        let here = renderer.map.locate(time)
        let f = renderer.frameRect(take: here.take)
        let u = (cx - f.minX) / f.width
        let v = (cyTop - (c.height - f.maxY)) / f.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        let vp = renderer.camera(take: here.take, time: here.time).viewport
        return renderer.crop(take: here.take).global(vp.x + Double(u) * vp.w, vp.y + Double(v) * vp.h)
    }

    /// Where the camera looks at output time `t`, in the whole frame's coordinates.
    func cameraCentre(at t: Double) -> (x: Double, y: Double) {
        let p = renderer.map.locate(t)
        let c = renderer.camera(take: p.take, time: p.time)
        return renderer.crop(take: p.take).global(c.centerX, c.centerY)
    }

    // MARK: timeline drags

    func isDragging(_ id: UUID) -> Bool { dragOrigin?.id == id }

    func beginDrag(_ id: UUID) {
        dragOrigin = doc.segments.first { $0.id == id }
        selectedID = id
    }

    func drag(_ id: UUID, edge: TimelineEdge?, by seconds: Double) {
        guard let o = dragOrigin, o.id == id else { return }
        let length = takeDuration(o.take)
        // The drag is in output seconds; a zoom lives in take time, on footage that may play faster or slower.
        let rate = renderer.map.spans.first { $0.take == o.take && o.start < $0.end && o.end > $0.start }?.speed ?? 1
        let seconds = seconds * rate
        let moved: ZoomSegment
        switch edge {
        case nil: moved = SegmentEdits.move(o, by: seconds, duration: length)
        case .leading: moved = SegmentEdits.resize(o, leading: true, to: o.start + seconds, duration: length)
        case .trailing: moved = SegmentEdits.resize(o, leading: false, to: o.end + seconds, duration: length)
        }
        // Never let a drag push one zoom into another on the same footage.
        let others = doc.segments.filter { $0.id != id && $0.take == o.take }
        guard !others.contains(where: { moved.start < $0.end && $0.start < moved.end }) else { return }
        update { d in
            if let i = d.segments.firstIndex(where: { $0.id == id }) { d.segments[i] = moved }
        }
    }

    func endDrag() {
        dragOrigin = nil
        update { $0.segments.sort { $0.start < $1.start } }
    }


    // MARK: hiding and cropping

    /// Framing mode: the preview shows the take at the playhead whole (no
    /// crop, no zoom, no cursor) so its crop can be dragged and boxes drawn
    /// over whatever should be hidden. The blurs show as they will render.
    private(set) var framing = false
    var frameTool: FrameTool = .blur
    private(set) var selectedBlurID: UUID?

    enum FrameTool: Hashable { case crop, blur }

    /// A box being drawn on the preview (view coordinates), shown until let go.
    var drawingBox: CGRect?
    /// A box as it was when a drag on it began (drags are relative to that).
    @ObservationIgnored var boxOrigin: NormRect?

    var selectedBlur: BlurRegion? { doc.blurs.first { $0.id == selectedBlurID } }
    /// The take being framed: the one at the playhead.
    var framingTake: Int { renderer.map.locate(time).take }
    var hasPrivacyEdits: Bool { !doc.blurs.isEmpty || !doc.crops.isEmpty }

    func openFraming(_ tool: FrameTool = .blur) {
        if cameraPhase != .off { closeCamera() }
        if playing { togglePlay() }
        frameTool = tool
        guard !framing else { return }
        framing = true
        selectedID = nil
        selectedClip = nil
        renderer = makeRenderer()
        scheduleRebuild()
    }

    func closeFraming() {
        guard framing else { return }
        framing = false
        selectedBlurID = nil
        renderer = makeRenderer()
        scheduleRebuild()
    }

    func selectBlur(_ id: UUID?) {
        selectedBlurID = id
        if id != nil { selectedID = nil; selectedClip = nil; selectedTextID = nil }
    }

    /// Hides `rect` of the take at the playhead, for the whole take.
    func addBlur(_ rect: NormRect) {
        let style = selectedBlur?.style ?? doc.blurs.last?.style ?? .blur
        let b = BlurRegion(take: framingTake, rect: rect.clamped(), style: style)
        update { $0.blurs.append(b) }
        selectBlur(b.id)
        Log.info(String(format: "blur added: %.2f,%.2f %.2fx%.2f", b.rect.x, b.rect.y, b.rect.w, b.rect.h))
    }

    func setBlur(_ id: UUID, _ change: (inout BlurRegion) -> Void) {
        update { d in
            guard let i = d.blurs.firstIndex(where: { $0.id == id }) else { return }
            change(&d.blurs[i])
            d.blurs[i].rect = d.blurs[i].rect.clamped()
        }
    }

    func deleteBlur(_ id: UUID) {
        update { $0.blurs.removeAll { $0.id == id } }
        if selectedBlurID == id { selectedBlurID = nil }
    }

    /// The selected blur starts (or ends) at the playhead, if that's on its take.
    func setBlurStart() { setBlurEdge(start: true) }
    func setBlurEnd() { setBlurEdge(start: false) }

    private func setBlurEdge(start: Bool) {
        guard let b = selectedBlur else { return }
        let here = renderer.map.locate(time)
        guard here.take == b.take else { return }
        setBlur(b.id) { r in
            if start {
                r.start = here.time
                if let e = r.end, e <= here.time { r.end = nil }
            } else {
                r.end = here.time
                if let s = r.start, s >= here.time { r.start = nil }
            }
        }
    }

    func blurAlways() {
        guard let id = selectedBlurID else { return }
        setBlur(id) { $0.start = nil; $0.end = nil }
    }

    func setCrop(_ rect: NormRect) {
        let take = framingTake
        update { $0.setCrop(rect, take: take) }
    }

    func resetCrop() { setCrop(.full) }

    /// Where the take at the playhead sits in a preview of `shown` size
    /// (top-left origin), while framing.
    func takeRect(in shown: CGSize) -> CGRect {
        let c = renderer.canvas
        let k = shown.width / max(c.width, 1)
        let f = renderer.frameRect(take: framingTake)
        return CGRect(x: f.minX * k, y: (c.height - f.maxY) * k, width: f.width * k, height: f.height * k)
    }

    /// The recording as the preview shows it: while framing, uncropped,
    /// unzoomed, without the cursor, and whole (a vertical edit's follow
    /// window would hide most of it).
    var shownProject: Project { EditorModel.shown(project, framing: framing) }

    private func makeRenderer() -> Renderer { EditorModel.renderer(for: project, framing: framing) }

    private static func renderer(for project: Project, framing: Bool) -> Renderer {
        Renderer(project: shown(project, framing: framing))
    }

    private static func shown(_ project: Project, framing: Bool) -> Project {
        guard framing else { return project }
        var p = project
        p.edit.crops = []
        p.edit.segments = []
        p.edit.cursorVisible = false
        p.edit.layout = nil
        return p
    }

    // MARK: export

    var exportURL: URL {
        project.folder.deletingLastPathComponent().appendingPathComponent(project.name + ".mp4")
    }

    func export() {
        guard exportProgress == nil else { return }
        if playing { togglePlay() }
        try? project.saveEdit()
        exportProgress = 0
        exportError = nil
        exportedURL = nil
        let project = project, url = exportURL
        Log.info("export started -> \(url.lastPathComponent)")
        Task {
            do {
                try await Composer.export(project, to: url) { p in
                    Task { @MainActor [weak self] in
                        if self?.exportProgress != nil { self?.exportProgress = p }
                    }
                }
                exportProgress = nil
                exportedURL = url
                if EditorModel.writeSubtitles { Subtitles.write(project, beside: url) }
                Log.info("export finished \(url.lastPathComponent)")
            } catch {
                exportProgress = nil
                exportError = "Export failed"
                Log.error("export failed: \(error)")
            }
        }
    }

    func revealExport() {
        if let exportedURL { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) }
    }

    // MARK: rendering plumbing

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await self?.rebuildComposition()
        }
    }

    /// The cut-and-trim layout the current player item was built for.
    @ObservationIgnored private var itemMap: TimeMap?
    @ObservationIgnored private var itemMusic: MusicChoice?
    @ObservationIgnored private var itemCamera: [CameraClip]?
    @ObservationIgnored private var itemDuck: Bool?

    private func rebuildComposition() async {
        let r = renderer
        do {
            let music = audition ?? doc.music
            if let item, itemMap?.sameTiming(r.map) == true, itemMusic == music, itemCamera == doc.cameraClips, itemDuck == doc.cameraLook.duckMusic {
                // Only the look changed: swap the rendering, keep the item.
                item.videoComposition = try await Composer.videoComposition(asset: item.asset, renderer: r)
            } else {
                // Trim or cuts changed: rebuild the edited asset.
                var heard = project
                heard.edit.music = music
                let p = try await Composer.prepare(heard, renderer: r)
                let item = AVPlayerItem(asset: p.asset)
                // Sped-up or slowed voices keep their pitch.
                item.audioTimePitchAlgorithm = .spectral
                item.videoComposition = p.video
                item.audioMix = p.audio
                self.item = item
                itemMap = r.map
                itemMusic = music
                itemCamera = doc.cameraClips
                itemDuck = doc.cameraLook.duckMusic
                let wasPlaying = playing
                player.replaceCurrentItem(with: item)
                if wasPlaying { player.play() }
            }
            // A paused player keeps showing the old frame until it's asked again.
            if !playing { seek(to: time) }
        } catch {
            Log.error("composition: \(error)")
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            do { try project.saveEdit() } catch { Log.error("save edit: \(error)") }
        }
    }

    private func makeThumbnails(take: Int) async {
        guard project.takes.indices.contains(take) else { return }
        let t = project.takes[take]
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: t.videoURL))
        gen.maximumSize = CGSize(width: 240, height: 150)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: Self.thumbStep / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: Self.thumbStep / 2, preferredTimescale: 600)
        let count = min(400, max(1, Int((t.meta.duration / Self.thumbStep).rounded(.up))))
        var out: [CGImage] = []
        for i in 0..<count {
            let at = min(t.meta.duration - 0.01, (Double(i) + 0.5) * Self.thumbStep)
            if let img = try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)).image {
                out.append(img)
            } else if let last = out.last {
                out.append(last)
            }
        }
        thumbnails[take] = out
    }
}

enum TimelineEdge { case leading, trailing }

// MARK: texts

extension EditorModel {
    var selectedText: TextOverlay? { doc.overlays.first { $0.id == selectedTextID } }

    func selectText(_ id: UUID?) {
        selectedTextID = id
        if id != nil { selectedID = nil; selectedClip = nil; selectedBlurID = nil }
    }

    /// Adds a text at the playhead (T adds a title), and selects it for typing.
    func addText(_ style: TextStyle = .title) {
        let words = style == .title ? "Your title" : style == .caption ? "Say what's happening" : "Look here"
        var o = TextEdits.insert(words, style: style, animation: style == .caption ? .words : style == .label ? .pop : .rise,
                                 at: time, videoLength: duration)
        if let f = EditFormat.named(doc.format) { o = f.styled(o) }
        update { $0.texts = ($0.texts ?? []) + [o] }
        selectText(o.id)
        Log.info(String(format: "text (%@) at %.2fs", style.rawValue, o.at))
    }

    func setText(_ id: UUID, _ change: (inout TextOverlay) -> Void) {
        update { d in
            guard var list = d.texts, let i = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[i])
            d.texts = list
        }
    }

    func deleteText(_ id: UUID) {
        update { d in d.texts?.removeAll { $0.id == id } }
        if selectedTextID == id { selectedTextID = nil }
    }

    /// Starts the selected text at the playhead, or ends it there.
    func textStartsHere(_ id: UUID) { setText(id) { $0 = TextEdits.resize($0, leading: true, to: self.time, videoLength: self.duration) } }
    func textEndsHere(_ id: UUID) { setText(id) { $0 = TextEdits.resize($0, leading: false, to: self.time, videoLength: self.duration) } }

    func beginTextDrag(_ id: UUID) {
        textOrigin = doc.overlays.first { $0.id == id }
        selectText(id)
    }

    /// Drags a text (or one end of it) by `seconds` of output time.
    func dragText(_ id: UUID, edge: TimelineEdge?, by seconds: Double) {
        guard let o = textOrigin, o.id == id else { return }
        let moved: TextOverlay
        switch edge {
        case nil: moved = TextEdits.move(o, to: o.at + seconds, videoLength: duration)
        case .leading: moved = TextEdits.resize(o, leading: true, to: o.at + seconds, videoLength: duration)
        case .trailing: moved = TextEdits.resize(o, leading: false, to: o.end + seconds, videoLength: duration)
        }
        setText(id) { $0 = moved }
        seek(to: edge == .trailing ? moved.end - 0.02 : moved.at + 0.02)
    }

    func endTextDrag() { textOrigin = nil }

    // MARK: formats

    var format: EditFormat? { EditFormat.named(doc.format) }

    /// Puts the whole edit in `f`'s pace and look (one undo step), keeping
    /// the playhead on the same footage.
    func applyFormat(_ f: EditFormat) {
        let here = renderer.map.locate(time)
        update { $0 = f.apply(to: $0, duration: project.meta.duration) }
        seek(to: renderer.map.output(take: here.take, time: here.time) ?? 0)
        Log.info("format: \(f.id)")
    }

    /// Opens the music browser on the format's mood.
    func findMusic(for f: EditFormat) {
        if let mood = MusicMood.all.first(where: { $0.id == f.musicMood }) { musicBrowser.choose(mood) }
        openMusic()
    }
}
