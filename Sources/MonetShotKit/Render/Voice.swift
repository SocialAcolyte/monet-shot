import AVFoundation
import Foundation

extension Composer {
    /// Your voice recorded with each take (the microphone alone), following
    /// the take's clips at their speeds, on its own track. A voice the
    /// camera heard is already there with the camera's sound.
    static func addVoice(_ project: Project, map: TimeMap, to comp: AVMutableComposition) async throws {
        let ts: CMTimeScale = 6000
        var track: AVMutableCompositionTrack?
        var sources: [Int: (AVAssetTrack, Double)] = [:]
        for s in map.spans {
            guard project.takes.indices.contains(s.take) else { continue }
            let take = project.takes[s.take]
            guard let voice = take.meta.voice, voice != take.meta.camera, let url = take.voiceURL else { continue }
            if sources[s.take] == nil {
                let asset = SourceAssets.asset(url)
                guard let a = try? await asset.loadTracks(withMediaType: .audio).first,
                      let length = try? await asset.load(.duration).seconds else { continue }
                sources[s.take] = (a, length)
            }
            guard let (source, length) = sources[s.take] else { continue }
            let off = take.meta.voiceOffset ?? 0
            let from = max(0, s.start - off), to = min(length, s.end - off)
            guard to - from > 0.05 else { continue }
            if track == nil { track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: TrackID.takeVoice) }
            guard let track else { return }
            let at = s.at + (from - (s.start - off)) / s.speed
            let start = CMTime(seconds: at, preferredTimescale: ts)
            let end = track.segments.isEmpty ? .zero : track.timeRange.end
            let range = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: ts), end: CMTime(seconds: to, preferredTimescale: ts))
            // Media goes in at the track's end, then silence before it pushes it to its place
            // (an empty track drops a leading empty edit inserted first).
            try track.insertTimeRange(range, of: source, at: end)
            if start > end { track.insertEmptyTimeRange(CMTimeRange(start: end, end: start)) }
            let slot = max(start, end)
            if abs(s.speed - 1) > 1e-6 {
                track.scaleTimeRange(CMTimeRange(start: slot, duration: range.duration),
                                     toDuration: CMTime(seconds: (to - from) / s.speed, preferredTimescale: ts))
            }
        }
    }
}

/// Subtitles beside an export: `<name>.srt` from the takes' transcripts,
/// whether or not the captions are shown in the video.
public enum Subtitles {
    /// The captions the edit's transcripts make, on its canvas.
    public static func overlays(_ project: Project) -> [TextOverlay] {
        let size = project.edit.canvasSize(recordingAspect: project.meta.aspect)
        let map = TimeMap(project.edit, duration: project.meta.duration)
        return Captions.overlays(project.takes.map(\.transcript), map: map, width: Double(size.width), height: Double(size.height),
                                 animation: EditFormat.named(project.edit.format)?.captionAnimation ?? .words)
    }

    /// Writes `<video name>.srt` beside `video` when there is anything said
    /// (and removes a stale one when there isn't). Returns the file written.
    @discardableResult
    public static func write(_ project: Project, beside video: URL) -> URL? {
        let url = video.deletingPathExtension().appendingPathExtension("srt")
        let list = overlays(project)
        guard !list.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        do {
            try Captions.srt(list).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.error("subtitles: \(error)")
            return nil
        }
    }

    /// Everything said, as plain text in play order.
    public static func text(_ project: Project) -> String {
        Captions.text(Captions.words(project.takes.map(\.transcript), map: TimeMap(project.edit, duration: project.meta.duration)))
    }
}
