import AVFoundation
import Foundation

/// A track under the video: one of the library that comes with the app (CC0
/// or public domain, so it can go anywhere with no credit and no conditions;
/// `Resources/Music/library.json`), or a file of your own.
public struct Song: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    /// Seconds.
    public var duration: Double
    public var genres: [String]
    public var license: String          // "cc0", "by", "pdm"
    public var licenseVersion: String?
    public var licenseURL: String?
    public var audioURL: String
    public var artworkURL: String?
    public var pageURL: String?
    public var attribution: String?
    public var bpm: Int?
    /// The composer's own one-line description.
    public var about: String?
    public var instruments: String?
    /// "calm", "steady" or "upbeat" (the library's own reading).
    public var tempo: String?
    /// 0...1: how much drive it has (the library's own reading).
    public var energy: Double?
    /// Its beat, read once when the library was made.
    public var grid: MusicGrid?
    /// Seconds into the song where it's best to begin (past any silence).
    public var start: Double?
    /// A small waveform for the list, 0...1.
    public var peaks: [Double]?

    public init(id: String, title: String, artist: String, album: String? = nil, duration: Double, genres: [String],
                license: String, licenseVersion: String? = nil, licenseURL: String? = nil, audioURL: String,
                artworkURL: String? = nil, pageURL: String? = nil, attribution: String? = nil,
                bpm: Int? = nil, about: String? = nil, instruments: String? = nil, tempo: String? = nil,
                energy: Double? = nil, grid: MusicGrid? = nil, start: Double? = nil, peaks: [Double]? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.genres = genres; self.license = license; self.licenseVersion = licenseVersion; self.licenseURL = licenseURL
        self.audioURL = audioURL; self.artworkURL = artworkURL; self.pageURL = pageURL; self.attribution = attribution
        self.bpm = bpm; self.about = about; self.instruments = instruments
        self.tempo = tempo; self.energy = energy; self.grid = grid; self.start = start; self.peaks = peaks
    }

    public var licenseLabel: String {
        switch license {
        case "cc0": "CC0"
        case "pdm": "Public domain"
        case "own": "Your file"
        default: "CC \(license.uppercased())\(licenseVersion.map { " \($0)" } ?? "")"
        }
    }

    /// True when the licence asks for a credit wherever the music is used.
    public var needsCredit: Bool { !["cc0", "pdm", "own"].contains(license) }
}

/// The music under a recording: the downloaded file (inside the .reel
/// folder, so exports work offline) and how it sits under the video.
public struct MusicChoice: Codable, Equatable, Sendable {
    public var track: Song
    /// File name inside the .reel folder.
    public var file: String
    /// Where in the song the video's first frame falls (seconds into the song).
    public var offset: Double = 0
    /// 0...1.
    public var volume: Double = 0.8
    public var fadeIn = true
    public var fadeOut = true

    public init(track: Song, file: String) {
        self.track = track
        self.file = file
    }
}

/// Moods for browsing: each is one of the composer's own "feel" tags.
public struct MusicMood: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let feel: String
    /// Tile colour (sRGB hex), muted to sit in the charcoal UI.
    public let tint: UInt32

    public static let all: [MusicMood] = [
        MusicMood(id: "dreamy", name: "Dreamy", feel: "dreamy", tint: 0x6A5B8A),
        MusicMood(id: "grooving", name: "Grooving", feel: "grooving", tint: 0xC96F4A),
        MusicMood(id: "sunny", name: "Sunny", feel: "sunny", tint: 0xB89B4A),
        MusicMood(id: "mellow", name: "Mellow", feel: "mellow", tint: 0x5F7A73),
        MusicMood(id: "punchy", name: "Punchy", feel: "punchy", tint: 0xA0505E),
        MusicMood(id: "classical", name: "Classical", feel: "classical", tint: 0x5A6F88),
    ]
}

public struct MusicPage: Codable, Sendable {
    public var tracks: [Song]
    public var page: Int
    public var pageCount: Int
}

public enum MusicError: Error, CustomStringConvertible {
    case busy
    case http(Int)
    case download
    public var description: String {
        switch self {
        case .busy: "The music library is busy. Try again in a minute."
        case .http(let c): "The music library answered \(c)."
        case .download: "Couldn't download that track."
        }
    }
}

/// The music that comes with the app: CC0 and public-domain tracks, each
/// levelled to the same loudness, listed in `Music/library.json` beside them.
/// Search and moods run over it locally; it works offline.
public enum MusicCatalog {
    static let agent = "MonetShot/0.1 (macOS screen recorder)"   // no personal details

    /// The app's Music folder (or the repo's, when run from source).
    public static let folder: URL? = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Music")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Music")
        return [bundled, repo].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("library.json").path) }
    }()

    nonisolated(unsafe) private static var loaded: [Song]?
    private static let lock = NSLock()

    /// The whole library, in its listed order.
    public static func all() async throws -> [Song] { try allNow() }

    /// The whole library, read once (a local file: no waiting).
    public static func allNow() throws -> [Song] {
        if let l = lock.withLock({ loaded }) { return l }
        guard let folder else { throw MusicError.download }
        let songs = try parse(Data(contentsOf: folder.appendingPathComponent("library.json")), folder: folder)
        lock.withLock { loaded = songs }
        return songs
    }

    /// Search words (all must match title, artist, description or mood)
    /// or a mood; nothing = everything.
    public static func search(_ query: String, mood: MusicMood? = nil) async throws -> [Song] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return try await all().filter { s in
            if !words.isEmpty {
                let hay = [s.title, s.artist, s.about ?? "", s.genres.joined(separator: " "), s.instruments ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            if let mood { return s.genres.contains { $0.lowercased() == mood.feel } }
            return true
        }
    }

    /// library.json (a list of songs whose audioURL is a file name) to songs
    /// with file URLs in `folder`; skips anything whose file is missing.
    public static func parse(_ data: Data, folder: URL) throws -> [Song] {
        try JSONDecoder().decode([Song].self, from: data).compactMap { song in
            let file = folder.appendingPathComponent(song.audioURL)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            var s = song
            s.audioURL = file.absoluteString
            return s
        }
    }

    /// A file of your own (music you've licensed elsewhere), as a song.
    public static func ownFile(_ url: URL) async -> Song {
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return Song(id: "own-\(url.lastPathComponent)", title: url.deletingPathExtension().lastPathComponent,
                    artist: "Your music", duration: seconds, genres: [], license: "own", audioURL: url.absoluteString)
    }

    /// A short, stable id for a file name (Swift's hashValue changes every run).
    static func stableID(_ s: String) -> String {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt32(b) }
        return String(h, radix: 36)
    }

    /// Downloads a track into `folder` and returns the file name.
    public static func download(_ track: Song, into folder: URL) async throws -> String {
        guard let url = URL(string: track.audioURL) else { throw MusicError.download }
        if url.isFileURL {
            // A file on this Mac (yours, or one of the app's own): copy it in, keeping its type.
            let kind = track.license == "own" ? "music-own" : "music"
            let name = "\(kind)-\(stableID(track.id)).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased())"
            let dest = folder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            return name
        }
        var req = URLRequest(url: url)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.download }
        let name = "music-\(stableID(track.id)).mp3"
        let dest = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        // Make sure it's really audio before keeping it.
        let tracks = try await AVURLAsset(url: dest).loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { try? FileManager.default.removeItem(at: dest); throw MusicError.download }
        return name
    }

    /// Peak levels (0...1) of an audio file in `buckets` slices, for drawing
    /// the waveform the snippet window slides over. Read locally; no network.
    public static func waveform(_ url: URL, buckets: Int = 240) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds, duration > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000,
        ])
        reader.add(out)
        guard reader.startReading() else { return [] }
        let total = Int(duration * 8000)
        let per = max(1, total / buckets)
        var peaks = [Float](repeating: 0, count: buckets)
        var index = 0
        while let buffer = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) { s in
                for i in 0..<(length / 2) {
                    let b = min(buckets - 1, index / per)
                    peaks[b] = max(peaks[b], Float(abs(Int(s[i]))) / 32768)
                    index += 1
                }
            }
        }
        let top = max(peaks.max() ?? 1, 0.01)
        return peaks.map { $0 / top }
    }
}
