import AVFoundation
import Foundation

/// A track under the video: one of Kevin MacLeod's (incompetech.com, about
/// 1,400 pieces under CC BY 4.0, which asks for a credit line that MonetShot keeps
/// and writes beside every export), or a file of your own.
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

    public init(id: String, title: String, artist: String, album: String? = nil, duration: Double, genres: [String],
                license: String, licenseVersion: String? = nil, licenseURL: String? = nil, audioURL: String,
                artworkURL: String? = nil, pageURL: String? = nil, attribution: String? = nil,
                bpm: Int? = nil, about: String? = nil, instruments: String? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.duration = duration
        self.genres = genres; self.license = license; self.licenseVersion = licenseVersion; self.licenseURL = licenseURL
        self.audioURL = audioURL; self.artworkURL = artworkURL; self.pageURL = pageURL; self.attribution = attribution
        self.bpm = bpm; self.about = about; self.instruments = instruments
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
        MusicMood(id: "bright", name: "Bright", feel: "bright", tint: 0xB89B4A),
        MusicMood(id: "uplifting", name: "Uplifting", feel: "uplifting", tint: 0xC96F4A),
        MusicMood(id: "relaxed", name: "Relaxed", feel: "relaxed", tint: 0x5F7A73),
        MusicMood(id: "calming", name: "Calming", feel: "calming", tint: 0x6E8088),
        MusicMood(id: "grooving", name: "Grooving", feel: "grooving", tint: 0x6A5B8A),
        MusicMood(id: "bouncy", name: "Bouncy", feel: "bouncy", tint: 0x9B7B4F),
        MusicMood(id: "driving", name: "Driving", feel: "driving", tint: 0x4A5A78),
        MusicMood(id: "epic", name: "Epic", feel: "epic", tint: 0x8C5A4A),
        MusicMood(id: "mysterious", name: "Mysterious", feel: "mysterious", tint: 0x5A5F78),
        MusicMood(id: "humorous", name: "Playful", feel: "humorous", tint: 0x8A7A68),
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

/// Kevin MacLeod's catalogue (incompetech.com), fetched once as a single
/// JSON list and cached for a week; search and moods run over it locally.
public enum MusicCatalog {
    static let listURL = URL(string: "https://incompetech.com/music/royalty-free/pieces.json")!
    static let fileBase = "https://incompetech.com/music/royalty-free/mp3-royaltyfree/"
    static let agent = "MonetShot/0.1 (macOS screen recorder)"   // no personal details
    /// Longer tracks are rarely what a demo wants and are slow to download.
    static let maxSeconds: Double = 8 * 60

    public static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MonetShot/music", isDirectory: true)
    }

    nonisolated(unsafe) private static var loaded: [Song]?
    private static let lock = NSLock()

    /// The whole catalogue, newest first.
    public static func all() async throws -> [Song] {
        if let l = lock.withLock({ loaded }) { return l }
        let cached = cacheDir.appendingPathComponent("incompetech.json")
        var data: Data?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86_400 {
            data = try? Data(contentsOf: cached)
        }
        if data == nil {
            var req = URLRequest(url: listURL)
            req.setValue(agent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 30
            do {
                let (fresh, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MusicError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
                data = fresh
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? fresh.write(to: cached, options: .atomic)
            } catch {
                // Offline: an old copy is better than nothing.
                data = try? Data(contentsOf: cached)
                if data == nil { throw error }
            }
        }
        let songs = try parse(data!)
        lock.withLock { loaded = songs }
        return songs
    }

    /// Search words (all must match title, description, feel or
    /// instruments) or a mood; nothing = everything, newest first.
    public static func search(_ query: String, mood: MusicMood? = nil) async throws -> [Song] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return try await all().filter { s in
            if !words.isEmpty {
                let hay = [s.title, s.about ?? "", s.genres.joined(separator: " "), s.instruments ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            if let mood { return s.genres.contains { $0.lowercased() == mood.feel } }
            return true
        }
    }

    /// incompetech's pieces.json to songs; skips anything without a file or too long.
    public static func parse(_ data: Data) throws -> [Song] {
        struct Piece: Decodable {
            let title: String?
            let filename: String?
            let length: String?
            let instruments: String?
            let bpm: String?
            let description: String?
            let feel: String?
            let uploaded: String?
        }
        let pieces = try JSONDecoder().decode([Piece].self, from: data)
        return pieces.compactMap { p -> (Song, String)? in
            guard let file = p.filename, !file.isEmpty, let title = p.title,
                  let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            let parts = (p.length ?? "").split(separator: ":").compactMap { Double($0) }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            guard seconds > 5, seconds <= maxSeconds else { return nil }
            let feels = (p.feel ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let credit = "\"\(title)\" Kevin MacLeod (incompetech.com). Licensed under Creative Commons: By Attribution 4.0 License, http://creativecommons.org/licenses/by/4.0/"
            let song = Song(id: file, title: title, artist: "Kevin MacLeod", duration: seconds, genres: feels,
                            license: "by", licenseVersion: "4.0", licenseURL: "https://creativecommons.org/licenses/by/4.0/",
                            audioURL: fileBase + encoded, pageURL: "https://incompetech.com/music/royalty-free/music.html",
                            attribution: credit, bpm: p.bpm.flatMap { Int($0) }, about: p.description,
                            instruments: p.instruments)
            return (song, p.uploaded ?? "")
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
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
            // Your own file: copy it in, keeping its type.
            let name = "music-own-\(stableID(track.id)).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased())"
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
