import AVFoundation
import CoreImage
import Foundation

/// Wires a `Renderer` into AVFoundation through `MonetShotCompositor`. The same
/// video composition drives the editor's player, still frames and the export.
/// (`AVMutableVideoComposition` is deprecated in macOS 26; it still works.)
public enum Composer {
    public static let fps: Int32 = 60

    /// The clips back to back, each from its own take's video.
    public static func edited(_ project: Project, map: TimeMap) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .video, preferredTrackID: TrackID.screen)
        else { throw ExportError.noVideo }
        var sources: [Int: AVAssetTrack] = [:]
        var at = CMTime.zero
        for s in map.spans {
            guard project.takes.indices.contains(s.take) else { continue }
            if sources[s.take] == nil {
                sources[s.take] = try await SourceAssets.asset(project.takes[s.take].videoURL).loadTracks(withMediaType: .video).first
            }
            guard let source = sources[s.take] else { throw ExportError.noVideo }
            let range = CMTimeRange(start: CMTime(seconds: s.start, preferredTimescale: 6000),
                                    end: CMTime(seconds: s.end, preferredTimescale: 6000))
            try track.insertTimeRange(range, of: source, at: at)
            // A clip at another speed: its footage stretched or squeezed to its length.
            let length = abs(s.speed - 1) > 1e-6 ? CMTime(seconds: s.length, preferredTimescale: 6000) : range.duration
            if length != range.duration {
                track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: length)
            }
            at = at + length
        }
        try await addCamera(project, map: map, to: comp)
        try await addVoice(project, map: map, to: comp)
        return comp
    }

    /// You on camera: clips recorded in the editor on one track, each take's
    /// own camera (following its clips) on another, their sound beside them.
    static func addCamera(_ project: Project, map: TimeMap, to comp: AVMutableComposition) async throws {
        let ts: CMTimeScale = 6000
        func place(_ source: AVAssetTrack, from: Double, to: Double, at: Double, speed: Double = 1, in track: AVMutableCompositionTrack) throws {
            let end = track.timeRange.end
            let start = CMTime(seconds: at, preferredTimescale: ts)
            if start > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: start)) }
            let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: ts), end: CMTime(seconds: to, preferredTimescale: ts))
            let slot = max(start, track.timeRange.end)
            try track.insertTimeRange(range, of: source, at: slot)
            if abs(speed - 1) > 1e-6 {
                track.scaleTimeRange(CMTimeRange(start: slot, duration: range.duration),
                                     toDuration: CMTime(seconds: (to - from) / speed, preferredTimescale: ts))
            }
        }
        func tracks(_ v: CMPersistentTrackID, _ a: CMPersistentTrackID) -> (AVMutableCompositionTrack, AVMutableCompositionTrack)? {
            guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: v),
                  let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: a) else { return nil }
            return (vt, at)
        }
        guard let (overlayV, overlayA) = tracks(TrackID.overlay, TrackID.overlayAudio),
              let (takeV, takeA) = tracks(TrackID.takeCamera, TrackID.takeCameraAudio) else { return }

        for c in project.edit.cameraClips.sorted(by: { $0.at < $1.at }) {
            let asset = SourceAssets.asset(project.folder.appendingPathComponent(c.file))
            guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                  let length = try? await asset.load(.duration).seconds else { continue }
            let to = min(c.duration, length, map.duration - c.at)
            guard to > 0.05 else { continue }
            try place(v, from: 0, to: to, at: c.at, in: overlayV)
            if let a = try? await asset.loadTracks(withMediaType: .audio).first { try place(a, from: 0, to: to, at: c.at, in: overlayA) }
        }
        for s in map.spans {
            guard project.takes.indices.contains(s.take), let url = project.takes[s.take].cameraURL else { continue }
            let asset = SourceAssets.asset(url)
            let off = project.takes[s.take].meta.cameraOffset
            guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                  let length = try? await asset.load(.duration).seconds else { continue }
            let from = max(0, s.start - off), to = min(length, s.end - off)
            guard to - from > 0.05 else { continue }
            let at = s.at + (from - (s.start - off)) / s.speed
            try place(v, from: from, to: to, at: at, speed: s.speed, in: takeV)
            if let a = try? await asset.loadTracks(withMediaType: .audio).first { try place(a, from: from, to: to, at: at, speed: s.speed, in: takeA) }
        }
        for t in [overlayV, overlayA, takeV, takeA] where t.segments.isEmpty { comp.removeTrack(t) }
    }

    /// Where someone is talking (camera sound), in output time.
    static func voice(in comp: AVComposition) -> [ClosedRange<Double>] {
        comp.tracks(withMediaType: .audio)
            .filter { [TrackID.overlayAudio, TrackID.takeCameraAudio, TrackID.takeVoice].contains($0.trackID) }
            .flatMap(\.segments)
            .filter { !$0.isEmpty }
            .map { $0.timeMapping.target.start.seconds...$0.timeMapping.target.end.seconds }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// A video composition that runs every frame of the edited asset through
    /// `renderer`, translating output time back to recording time.
    public static func videoComposition(asset: AVAsset, renderer: Renderer) async throws -> AVMutableVideoComposition {
        let ids = try await asset.loadTracks(withMediaType: .video).map(\.trackID)
        let length = try await asset.load(.duration)
        let comp = AVMutableVideoComposition()
        comp.customVideoCompositorClass = MonetShotCompositor.self
        comp.instructions = [MonetShotInstruction(timeRange: CMTimeRange(start: .zero, duration: length), renderer: renderer,
                                             cameras: [TrackID.overlay, TrackID.takeCamera].filter(ids.contains))]
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        comp.renderSize = renderer.canvas
        comp.frameDuration = CMTime(value: 1, timescale: fps)
        return comp
    }

    /// The edited asset and its rendering, ready for a player item, an image
    /// generator or an export session.
    public static func prepare(_ project: Project, renderer: Renderer? = nil) async throws -> (asset: AVAsset, video: AVMutableVideoComposition, renderer: Renderer, audio: AVAudioMix?) {
        let r = renderer ?? Renderer(project: project)
        let asset = try await edited(project, map: r.map)
        let mix = try await addMusic(project, to: asset, length: r.map.duration)
        return (asset, try await videoComposition(asset: asset, renderer: r), r, mix)
    }

    /// Lays the chosen music under the edited video, starting `offset` into
    /// the song (and from the top again if the song runs out), and returns
    /// the mix that sets its level and fades.
    public static func addMusic(_ project: Project, to comp: AVMutableComposition, length: Double) async throws -> AVAudioMix? {
        guard let m = project.edit.music, length > 0 else { return nil }
        let song = AVURLAsset(url: project.folder.appendingPathComponent(m.file))
        guard let source = try? await song.loadTracks(withMediaType: .audio).first,
              let songLength = try? await song.load(.duration).seconds, songLength > 0.5,
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let ts: CMTimeScale = 44_100
        var at = 0.0
        var from = min(max(0, m.offset), songLength - 0.5)
        while at < length - 0.01 {
            let take = min(songLength - from, length - at)
            let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: ts), duration: CMTime(seconds: take, preferredTimescale: ts))
            try track.insertTimeRange(range, of: source, at: CMTime(seconds: at, preferredTimescale: ts))
            at += take
            from = 0
        }
        let p = AVMutableAudioMixInputParameters(track: track)
        let v = Float(min(max(m.volume, 0), 1))
        // The level, sampled every 0.1 s: fades, and ducks under your voice.
        let voice = project.edit.cameraLook.duckMusic ? Self.voice(in: comp) : []
        func gain(_ t: Double) -> Float {
            v * Float(MusicEnvelope.gain(at: t, length: length, fadeIn: m.fadeIn, fadeOut: m.fadeOut, voice: voice))
        }
        let step = 0.1
        var t = 0.0
        var ramping = true
        while t < length - 0.001 {
            let next = min(length, t + step)
            let a = gain(t), b = gain(next)
            let range = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: ts), end: CMTime(seconds: next, preferredTimescale: ts))
            if abs(a - b) > 0.0005 {
                p.setVolumeRamp(fromStartVolume: a, toEndVolume: b, timeRange: range)
                ramping = true
            } else if ramping {
                p.setVolume(a, at: range.start)
                ramping = false
            }
            t = next
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [p]
        return mix
    }

    /// One finished frame at output time `time`, exactly as the export will draw it.
    public static func frame(_ project: Project, at time: Double) async throws -> CGImage {
        let p = try await prepare(project)
        let gen = AVAssetImageGenerator(asset: p.asset)
        gen.videoComposition = p.video
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let t = min(max(0, time), max(0, p.renderer.map.duration - 0.02))
        return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    public enum ExportError: Error, CustomStringConvertible {
        case noSession, noVideo
        public var description: String {
            switch self {
            case .noSession: "could not create an export session"
            case .noVideo: "the recording has no video track"
            }
        }
    }

    /// Renders the edit to an .mp4 at `url` (replacing it), reporting 0...1.
    public static func export(_ project: Project, to url: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let (asset, comp, renderer, audio) = try await prepare(project)
        // HEVC above 4K-ish widths, H.264 otherwise (plays everywhere).
        let preset = renderer.canvas.width > 3000 ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { throw ExportError.noSession }
        session.videoComposition = comp
        session.audioMix = audio
        // Sped-up or slowed voices keep their pitch.
        session.audioTimePitchAlgorithm = .spectral
        try? FileManager.default.removeItem(at: url)
        // The session isn't Sendable; this task only reads its state stream.
        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.1) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
        // CC BY music asks for a credit wherever the video goes: keep it beside the file.
        let credit = url.deletingPathExtension().appendingPathExtension("credits.txt")
        if let m = project.edit.music, m.track.needsCredit {
            let text = "Music: \(m.track.attribution ?? "\"\(m.track.title)\" by \(m.track.artist), \(m.track.licenseLabel)")\n\(m.track.pageURL ?? "")\n"
            try? text.write(to: credit, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: credit)
        }
        progress(1)
    }
}

/// The take videos, opened once and kept open. A composition reads from its
/// source assets lazily and does not keep them alive itself: a source asset
/// that is released fails every later read (AVFoundation error -12780).
enum SourceAssets {
    nonisolated(unsafe) private static var open: [URL: AVURLAsset] = [:]
    private static let lock = NSLock()

    static func asset(_ url: URL) -> AVURLAsset {
        lock.lock(); defer { lock.unlock() }
        if let a = open[url] { return a }
        let a = AVURLAsset(url: url)
        open[url] = a
        return a
    }
}
