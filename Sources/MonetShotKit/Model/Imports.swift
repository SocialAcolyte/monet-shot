import AVFoundation
import Foundation

/// Bringing more footage into a recording: any video file, or the takes of
/// another MonetShot recording. Files are copied in, so the recording stays whole.
public enum Imports {
    public enum ImportError: Error, CustomStringConvertible {
        case noVideo(String)
        public var description: String {
            switch self { case .noVideo(let n): "\(n) has no video" }
        }
    }

    /// Makes a new recording from a video file, so any screen recording can
    /// be edited in MonetShot. Returns its folder.
    public static func newProject(fromVideo url: URL, in dir: URL = Project.libraryDir) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideo(url.lastPathComponent)
        }
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let duration = try await asset.load(.duration).seconds
        let folder = Project.newFolder(in: dir)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "screen." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        let meta = RecordingMeta(pixelWidth: Int(abs(size.width)), pixelHeight: Int(abs(size.height)), pointScale: 2,
                                 duration: duration, source: "import", video: name)
        let p = Project(folder: folder, meta: meta, cursor: CursorTrack(), edit: EditDoc())
        try p.saveMeta(); try p.saveCursor(); try p.saveEdit()
        return folder
    }

    /// Copies a video file in as a new take (no pointer log, so no cursor
    /// is drawn on it). Returns the new take's index.
    public static func video(_ url: URL, into project: inout Project) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideo(url.lastPathComponent)
        }
        let size = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))
        let duration = try await asset.load(.duration).seconds
        let folder = project.nextTakeFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "screen." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
        // Assume a Retina capture; this only sizes the cursor, which an import doesn't draw.
        let meta = RecordingMeta(pixelWidth: Int(abs(size.width)), pixelHeight: Int(abs(size.height)), pointScale: 2,
                                 duration: duration, source: "import", video: name)
        let take = Take(folder: folder, meta: meta, cursor: CursorTrack())
        try take.save()
        project.takes.append(take)
        return project.takes.count - 1
    }

    /// Copies every take of another recording in, with its clips (appended to
    /// the end) and its zooms. Returns the new takes' indices.
    public static func recording(_ other: Project, into project: inout Project) throws -> [Int] {
        var map: [Int: Int] = [:]
        for (i, t) in other.takes.enumerated() {
            let folder = project.nextTakeFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: t.videoURL, to: folder.appendingPathComponent(t.meta.video))
            let take = Take(folder: folder, meta: t.meta, cursor: t.cursor)
            try take.save()
            project.takes.append(take)
            map[i] = project.takes.count - 1
        }
        var clips = project.clips
        clips += other.clips.compactMap { c in map[c.take].map { Clip(start: c.start, end: c.end, take: $0) } }
        project.edit.clips = clips
        project.edit.cuts = []
        project.edit.trimStart = 0
        project.edit.trimEnd = nil
        project.edit.segments += other.edit.segments.compactMap { s in
            map[s.take].map { var z = s; z.id = UUID(); z.take = $0; return z }
        }
        project.edit.blurs += other.edit.blurs.compactMap { b in
            map[b.take].map { var z = b; z.id = UUID(); z.take = $0; return z }
        }
        project.edit.crops += other.edit.crops.compactMap { c in map[c.take].map { TakeCrop(take: $0, rect: c.rect) } }
        return other.takes.indices.compactMap { map[$0] }
    }
}
