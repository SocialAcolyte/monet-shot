import Foundation

/// A recording on disk is a folder, `<name>.reel/`:
///   screen.mov    the first take, recorded WITHOUT the system cursor
///   cursor.json   where the pointer was and when it clicked (CursorTrack)
///   meta.json     pixel size, scale, duration (RecordingMeta)
///   edit.json     everything chosen in the editor (EditDoc)
///   take-2/ …     further takes (recorded later or imported), each with
///                 its own video, cursor.json and meta.json
/// The videos are never modified; every edit is re-rendered from these files.

/// Pointer positions are normalised to the captured content: (0,0) is the
/// top-left corner of the video frame, (1,1) the bottom-right.
public struct CursorSample: Codable, Equatable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    public init(t: Double, x: Double, y: Double) { self.t = t; self.x = x; self.y = y }
}

public struct CursorTrack: Codable, Equatable, Sendable {
    public var samples: [CursorSample]
    /// Mouse-down moments, same coordinates as `samples`.
    public var clicks: [CursorSample]
    public init(samples: [CursorSample] = [], clicks: [CursorSample] = []) {
        self.samples = samples
        self.clicks = clicks
    }
}

public struct RecordingMeta: Codable, Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Backing scale of the captured content (2 on a Retina display).
    public var pointScale: Double
    public var duration: Double
    public var createdAt: Date
    /// "display", "window", or "import" (a video file brought in).
    public var source: String
    /// The take's video file name, inside its folder.
    public var video: String = "screen.mov"
    /// You on camera, recorded with this take (file name), and the take time
    /// at which that file starts.
    public var camera: String?
    public var cameraOffset: Double = 0
    /// The file holding your voice for this take (`voice.m4a` from the
    /// microphone alone, or the camera file when the camera heard you), and
    /// the take time at which it starts. Written only when there is one.
    public var voice: String?
    public var voiceOffset: Double?

    public init(pixelWidth: Int, pixelHeight: Int, pointScale: Double, duration: Double, createdAt: Date = Date(),
                source: String, video: String = "screen.mov") {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointScale = pointScale
        self.duration = duration
        // Whole seconds: the ISO 8601 files store no fractions.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.source = source
        self.video = video
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        pointScale = try c.decode(Double.self, forKey: .pointScale)
        duration = try c.decode(Double.self, forKey: .duration)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        source = try c.decode(String.self, forKey: .source)
        video = try c.decodeIfPresent(String.self, forKey: .video) ?? "screen.mov"
        camera = try c.decodeIfPresent(String.self, forKey: .camera)
        cameraOffset = try c.decodeIfPresent(Double.self, forKey: .cameraOffset) ?? 0
        voice = try c.decodeIfPresent(String.self, forKey: .voice)
        voiceOffset = try c.decodeIfPresent(Double.self, forKey: .voiceOffset)
    }

    public var aspect: Double { Double(pixelWidth) / Double(max(pixelHeight, 1)) }
}

/// One zoom on the timeline. Between `start` and `end` the camera eases in to
/// `scale`, holds, and eases back out. `focus` nil means the camera follows
/// the (smoothed) cursor; otherwise it holds on that normalised point.
public struct ZoomSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var focusX: Double?
    public var focusY: Double?
    /// Made by auto-zoom (true) or by hand; auto ones are replaced when
    /// auto-zoom is re-run, hand-made ones never are.
    public var auto: Bool
    /// The take it belongs to; its times are that take's own. A zoom lives
    /// on the footage, so it moves wherever that footage's clip goes.
    public var take: Int

    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double = 2,
                focusX: Double? = nil, focusY: Double? = nil, auto: Bool = false, take: Int = 0) {
        self.id = id
        self.start = start
        self.end = end
        self.scale = scale
        self.focusX = focusX
        self.focusY = focusY
        self.auto = auto
        self.take = take
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        scale = try c.decode(Double.self, forKey: .scale)
        focusX = try c.decodeIfPresent(Double.self, forKey: .focusX)
        focusY = try c.decodeIfPresent(Double.self, forKey: .focusY)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
        take = try c.decodeIfPresent(Int.self, forKey: .take) ?? 0
    }

    public var duration: Double { end - start }
    public var followsCursor: Bool { focusX == nil || focusY == nil }
}

/// The surface the recording sits on.
public enum Backdrop: String, Codable, CaseIterable, Sendable {
    /// Warm paper with a fine grain.
    case paper
    /// Insomnia's soft charcoal.
    case charcoal
    /// A warm dusk gradient: clay into deep umber.
    case dusk
    /// Cool slate blue-grey, Insomnia's accent darkened.
    case slate
    /// No frame: the recording fills the canvas edge to edge.
    case none
    /// A picture of your choosing (`EditDoc.backdropImage`), filling the canvas.
    case image

    public var label: String {
        switch self {
        case .paper: "Paper"
        case .charcoal: "Charcoal"
        case .dusk: "Dusk"
        case .slate: "Slate"
        case .none: "None"
        case .image: "Image"
        }
    }
}

/// One piece of footage in the video: a stretch of one take, in that
/// take's own time. The video is the clips played in list order.
public struct Clip: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var take: Int
    /// How fast the footage plays: 2 is twice as fast (the clip lasts half
    /// as long in the video), 0.5 is slow motion.
    public var speed: Double = 1
    /// Seconds over which the clip fades up from the backdrop at its start,
    /// and back down at its end (output time). 0 = a straight cut.
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0

    public static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
    public static let speedRange: ClosedRange<Double> = 0.25...4

    public init(start: Double, end: Double, take: Int = 0, speed: Double = 1) {
        self.start = start; self.end = end; self.take = take; self.speed = speed
    }
    /// Length of footage, in take time.
    public var duration: Double { end - start }
    /// The speed actually used (kept inside `speedRange`).
    public var rate: Double { speed.isFinite ? min(max(speed, Clip.speedRange.lowerBound), Clip.speedRange.upperBound) : 1 }
    /// How long the clip lasts in the video.
    public var outputDuration: Double { duration / rate }

    enum CodingKeys: String, CodingKey { case start, end, take, speed, fadeIn, fadeOut }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        take = try c.decodeIfPresent(Int.self, forKey: .take) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
    }

    /// Speed and fades are written only when set, so an edit that uses
    /// neither is byte-for-byte what it was before they existed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(take, forKey: .take)
        if speed != 1 { try c.encode(speed, forKey: .speed) }
        if fadeIn != 0 { try c.encode(fadeIn, forKey: .fadeIn) }
        if fadeOut != 0 { try c.encode(fadeOut, forKey: .fadeOut) }
    }
}

/// A stretch of the recording left out of the finished video.
public struct Cut: Codable, Equatable, Sendable, Identifiable {
    public var start: Double
    public var end: Double
    public var id: Double { start }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Everything the editor chooses. Defaults are the look that ships.
public struct EditDoc: Codable, Equatable, Sendable {
    public var segments: [ZoomSegment] = []
    public var backdrop: Backdrop = .paper
    /// Space around the recording, as a fraction of the canvas's shorter side.
    public var padding: Double = 0.07
    /// Corner radius of the framed recording, as a fraction of its shorter side.
    public var cornerRadius: Double = 0.018
    public var shadow = true
    public var cursorVisible = true
    /// Cursor size relative to the real one at 1x zoom.
    public var cursorScale: Double = 1.5
    /// 0 = raw pointer path, 1 = very smooth glide.
    public var cursorSmoothing: Double = 0.6
    public var clickRipple = true
    public var cursorStyle: CursorStyle = .classic
    public var cursorTint: CursorTint = .clay
    /// The name on the `.tag` cursor.
    public var cursorLabel: String = ""
    /// You on camera, recorded over the video in the editor.
    public var cameraClips: [CameraClip] = []
    public var cameraLook = CameraLook()
    /// Width of the exported video in pixels; height follows the canvas aspect.
    public var outputWidth = 2560
    /// Canvas aspect (width / height). 16:9 by default; 0 means match the recording.
    public var canvasAspect: Double = 16.0 / 9.0
    public var trimStart: Double = 0
    /// nil = to the end of the recording.
    public var trimEnd: Double?
    /// Stretches left out of the video, in recording time: every pause while
    /// recording becomes one. Kept sorted and non-overlapping.
    public var cuts: [Cut] = []
    /// The kept pieces, once the editor has touched them. nil = derive from
    /// the trim and the cuts (which is what a fresh recording carries).
    public var clips: [Clip]?
    /// Music under the video, if any.
    public var music: MusicChoice?
    /// File name, inside the .reel folder, of the `.image` backdrop.
    public var backdropImage: String?
    /// 0 = the picture sharp, 1 = softly out of focus.
    public var backdropBlur: Double = 0
    /// Parts of the recording hidden in the video (a chat, an inbox).
    public var blurs: [BlurRegion] = []
    /// Per take, the part of the frame kept (the rest is cut away).
    public var crops: [TakeCrop] = []
    /// Words on the video (nil until the first is added, so older edits
    /// stay byte-for-byte as they were).
    public var texts: [TextOverlay]?
    /// The format last applied (`EditFormat.id`), for the picker to show; the
    /// edit itself carries everything the format set.
    public var format: String?
    /// What was said, shown as captions (nil until switched, so older edits
    /// stay as they were).
    public var captions: Bool?

    public init() {}

    /// The texts, in drawing order (later ones on top).
    public var overlays: [TextOverlay] { texts ?? [] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditDoc()
        segments = try c.decodeIfPresent([ZoomSegment].self, forKey: .segments) ?? d.segments
        backdrop = try c.decodeIfPresent(Backdrop.self, forKey: .backdrop) ?? d.backdrop
        padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? d.padding
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? d.cornerRadius
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? d.shadow
        cursorVisible = try c.decodeIfPresent(Bool.self, forKey: .cursorVisible) ?? d.cursorVisible
        cursorScale = try c.decodeIfPresent(Double.self, forKey: .cursorScale) ?? d.cursorScale
        cursorSmoothing = try c.decodeIfPresent(Double.self, forKey: .cursorSmoothing) ?? d.cursorSmoothing
        clickRipple = try c.decodeIfPresent(Bool.self, forKey: .clickRipple) ?? d.clickRipple
        cursorStyle = try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? d.cursorStyle
        cursorTint = try c.decodeIfPresent(CursorTint.self, forKey: .cursorTint) ?? d.cursorTint
        cursorLabel = try c.decodeIfPresent(String.self, forKey: .cursorLabel) ?? d.cursorLabel
        cameraClips = try c.decodeIfPresent([CameraClip].self, forKey: .cameraClips) ?? d.cameraClips
        cameraLook = try c.decodeIfPresent(CameraLook.self, forKey: .cameraLook) ?? d.cameraLook
        outputWidth = try c.decodeIfPresent(Int.self, forKey: .outputWidth) ?? d.outputWidth
        canvasAspect = try c.decodeIfPresent(Double.self, forKey: .canvasAspect) ?? d.canvasAspect
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? d.trimStart
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd)
        cuts = try c.decodeIfPresent([Cut].self, forKey: .cuts) ?? d.cuts
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips)
        music = try c.decodeIfPresent(MusicChoice.self, forKey: .music)
        backdropImage = try c.decodeIfPresent(String.self, forKey: .backdropImage)
        backdropBlur = try c.decodeIfPresent(Double.self, forKey: .backdropBlur) ?? d.backdropBlur
        blurs = try c.decodeIfPresent([BlurRegion].self, forKey: .blurs) ?? d.blurs
        crops = try c.decodeIfPresent([TakeCrop].self, forKey: .crops) ?? d.crops
        texts = try c.decodeIfPresent([TextOverlay].self, forKey: .texts)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        captions = try c.decodeIfPresent(Bool.self, forKey: .captions)
    }

    /// The clips that make the video: the explicit list, or (for a recording
    /// not yet edited) the first take's trim with its pause cuts taken out.
    public func keptClips(duration: Double) -> [Clip] {
        if let clips { return clips }
        let lo = min(max(0, trimStart), duration)
        let hi = min(max(lo, trimEnd ?? duration), duration)
        var out: [Clip] = []
        var cursor = lo
        for c in cuts.sorted(by: { $0.start < $1.start }) where c.end > cursor && c.start < hi {
            if c.start > cursor { out.append(Clip(start: cursor, end: c.start)) }
            cursor = max(cursor, c.end)
        }
        if hi > cursor { out.append(Clip(start: cursor, end: hi)) }
        return out.filter { $0.duration > 1e-3 }
    }

    /// Canvas size in pixels for a recording of the given aspect.
    public func canvasSize(recordingAspect: Double) -> (width: Int, height: Int) {
        let aspect = canvasAspect > 0 ? canvasAspect : recordingAspect
        let w = max(2, outputWidth)
        // Video encoders want even dimensions.
        let h = Int((Double(w) / aspect / 2).rounded()) * 2
        return (w, max(2, h))
    }
}

/// One recorded (or imported) video with its pointer log.
public struct Take: Sendable {
    /// Its folder: the project folder for the first take, `take-N/` after.
    public let folder: URL
    public var meta: RecordingMeta
    public var cursor: CursorTrack
    /// What was said in it (`transcript.json`), if transcribed.
    public var transcript: Transcript?

    public init(folder: URL, meta: RecordingMeta, cursor: CursorTrack) {
        self.folder = folder
        self.meta = meta
        self.cursor = cursor
    }

    public var videoURL: URL { folder.appendingPathComponent(meta.video) }
    public var cameraURL: URL? { meta.camera.map { folder.appendingPathComponent($0) } }
    public var voiceURL: URL? { meta.voice.map { folder.appendingPathComponent($0) } }
    /// Imported videos carry no pointer log, so MonetShot draws no cursor on them.
    public var hasCursor: Bool { !cursor.samples.isEmpty }

    static func load(_ folder: URL) throws -> Take {
        func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw Project.LoadError.missing(name) }
            return try JSONDecoder.app.decode(T.self, from: data)
        }
        let meta = try read(RecordingMeta.self, "meta.json")
        let cursor = (try? read(CursorTrack.self, "cursor.json")) ?? CursorTrack()
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(meta.video).path) else {
            throw Project.LoadError.missing(meta.video)
        }
        var take = Take(folder: folder, meta: meta, cursor: cursor)
        take.transcript = Transcript.load(folder)
        return take
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.app.encode(meta).write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        try JSONEncoder.app.encode(cursor).write(to: folder.appendingPathComponent("cursor.json"), options: .atomic)
    }
}

/// A recording folder: its takes and the edit.
public struct Project: Sendable {
    public let folder: URL
    public var takes: [Take]
    public var edit: EditDoc

    /// The first take, which sets the canvas and the name.
    public var meta: RecordingMeta {
        get { takes[0].meta }
        set { takes[0].meta = newValue }
    }
    public var cursor: CursorTrack {
        get { takes[0].cursor }
        set { takes[0].cursor = newValue }
    }
    public var videoURL: URL { takes[0].videoURL }
    public var name: String { folder.deletingPathExtension().lastPathComponent }

    /// The clips in play order.
    public var clips: [Clip] { edit.keptClips(duration: meta.duration) }

    public func duration(ofTake i: Int) -> Double { takes.indices.contains(i) ? takes[i].meta.duration : 0 }

    public init(folder: URL, meta: RecordingMeta, cursor: CursorTrack, edit: EditDoc) {
        self.folder = folder
        takes = [Take(folder: folder, meta: meta, cursor: cursor)]
        self.edit = edit
    }

    public enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self { case .missing(let f): "recording is missing \(f)" }
        }
    }

    public static func load(_ folder: URL) throws -> Project {
        let first = try Take.load(folder)
        let edit = (try? JSONDecoder.app.decode(EditDoc.self, from: Data(contentsOf: folder.appendingPathComponent("edit.json")))) ?? EditDoc()
        var p = Project(folder: folder, meta: first.meta, cursor: first.cursor, edit: edit)
        for dir in takeFolders(in: folder) {
            if let t = try? Take.load(dir) { p.takes.append(t) }
        }
        return p
    }

    /// `take-2`, `take-3`, … in number order.
    static func takeFolders(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { n -> (Int, URL)? in
            guard n.hasPrefix("take-"), let k = Int(n.dropFirst(5)) else { return nil }
            return (k, folder.appendingPathComponent(n, isDirectory: true))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
    }

    /// A fresh folder for the next take.
    public func nextTakeFolder() -> URL {
        let used = Project.takeFolders(in: folder).compactMap { Int($0.lastPathComponent.dropFirst(5)) }
        return folder.appendingPathComponent("take-\((used.max() ?? 1) + 1)", isDirectory: true)
    }

    public func saveEdit() throws { try write(edit, "edit.json") }
    public func saveMeta() throws { try write(meta, "meta.json") }
    public func saveCursor() throws { try write(cursor, "cursor.json") }

    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.app.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Where new recordings go: ~/Movies/MonetShot (MONETSHOT_HOME overrides, for tests).
    public static var libraryDir: URL {
        if let override = ProcessInfo.processInfo.environment["MONETSHOT_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("recordings")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/MonetShot")
    }

    /// A fresh, unique folder name like "2026-10-18 14.02.11.reel".
    public static func newFolder(in dir: URL = libraryDir, now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var url = dir.appendingPathComponent("\(f.string(from: now)).reel")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(f.string(from: now)) \(n).reel")
            n += 1
        }
        return url
    }
}
