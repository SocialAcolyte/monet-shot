import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Observation
import MonetShotKit

/// The music browser's state: what's listed (suggestions for this video,
/// favourites, a mood, or a search), the tempo filter and your favourites.
/// Clicking a track plays it under your own video: the editor does that
/// (`EditorModel.toggleAudition`), this only asks.
@MainActor
@Observable
final class MusicBrowserModel {
    enum Shelf: Hashable {
        case suggested, favourites
        case mood(String)
    }

    private(set) var query = ""
    private(set) var shelf: Shelf = .suggested
    private(set) var tempo: MusicTempo?
    private(set) var tracks: [Song] = []
    private(set) var problem: String?
    /// The track being copied into the recording.
    private(set) var adding: String?
    private(set) var favourites: Set<String> = MusicBrowserModel.loadFavourites()

    /// The editor whose video the tracks play under.
    @ObservationIgnored weak var editor: EditorModel?
    /// Called with the chosen track; returns when it's in the recording (or failed).
    @ObservationIgnored var onUse: (Song) async -> Bool = { _ in false }

    @ObservationIgnored private var library: [Song] = []
    @ObservationIgnored private var video = (length: 0.0, vertical: false, mood: String?.none)
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// The video the suggestions are for.
    func setVideo(length: Double, vertical: Bool, mood: String?) {
        video = (length, vertical, mood)
        reload()
    }

    func start() {
        if tracks.isEmpty { reload() }
    }

    func stop() {
        searchTask?.cancel()
    }

    // MARK: what's listed

    func setQuery(_ q: String) {
        query = q
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))   // wait for typing to pause
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func show(_ s: Shelf) {
        shelf = s
        query = ""
        reload()
    }

    func choose(_ m: MusicMood) { show(.mood(m.id)) }

    func setTempo(_ t: MusicTempo?) {
        tempo = tempo == t ? nil : t
        reload()
    }

    /// The heading over the list.
    var heading: String {
        if !query.isEmpty { return "Results" }
        switch shelf {
        case .suggested: return "For this video"
        case .favourites: return "Favourites"
        case .mood(let id): return MusicMood.all.first { $0.id == id }?.name ?? "Music"
        }
    }

    /// A line under the heading.
    var subheading: String? {
        guard query.isEmpty else { return nil }
        switch shelf {
        case .suggested:
            let len = MusicTime.clock(video.length)
            return video.vertical ? "Punchier picks for a \(len) vertical video" : "Picked for a \(len) video"
        case .favourites: return favourites.isEmpty ? "Tap the heart on a track to keep it here" : nil
        case .mood: return nil
        }
    }

    func reload() {
        problem = nil
        do {
            if library.isEmpty { library = try MusicCatalog.allNow() }
        } catch {
            problem = "The music library isn't here. Reinstall Monet Shot to get it back."
            Log.error("music: \(error)")
            tracks = []
            return
        }
        let pool = library.filter { tempo == nil || MusicTempo.of($0) == tempo }
        if !query.isEmpty {
            let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            tracks = pool.filter { s in
                let hay = [s.title, s.artist, s.about ?? "", s.genres.joined(separator: " "), s.instruments ?? "",
                           MusicTempo.of(s)?.rawValue ?? ""].joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            return
        }
        switch shelf {
        case .suggested:
            tracks = MusicSuggest.rank(pool, length: video.length, mood: video.mood, vertical: video.vertical,
                                       favourites: favourites, count: 8)
        case .favourites:
            tracks = pool.filter { favourites.contains($0.id) }
        case .mood(let id):
            tracks = pool.filter { $0.genres.contains(id) }
        }
    }

    // MARK: favourites, remembered between launches

    private static let favouritesKey = "musicFavourites"

    private static func loadFavourites() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: favouritesKey) ?? [])
    }

    func isFavourite(_ s: Song) -> Bool { favourites.contains(s.id) }

    func toggleFavourite(_ s: Song) {
        if favourites.contains(s.id) { favourites.remove(s.id) } else { favourites.insert(s.id) }
        UserDefaults.standard.set(favourites.sorted(), forKey: Self.favouritesKey)
        if shelf == .favourites { reload() }
    }

    // MARK: hearing and using

    var auditioning: Song? { editor?.audition?.track }
    var playing: Bool { editor?.playing ?? false }

    /// Where the audition is in its song, 0...1 of the track.
    var auditionFraction: Double? {
        guard let a = editor?.audition, let t = editor?.auditionSongTime, a.track.duration > 0 else { return nil }
        return min(1, t / a.track.duration)
    }

    /// The stretch of a track that plays under this video, as fractions of it.
    func window(for s: Song) -> ClosedRange<Double>? {
        guard s.duration > 0, video.length > 0 else { return nil }
        let start: Double
        if let a = editor?.audition, a.track.id == s.id { start = a.offset } else {
            start = MusicFit.place(grid: s.grid, songDuration: s.duration, length: video.length, from: s.start, punchy: video.vertical).offset
        }
        return min(1, start / s.duration)...min(1, (start + video.length) / s.duration)
    }

    func toggleAudition(_ s: Song) { editor?.toggleAudition(s) }

    /// Music you've licensed elsewhere (a file on this Mac).
    func chooseOwnFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a music file you have the rights to use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { use(await MusicCatalog.ownFile(url)) }
    }

    func use(_ t: Song) {
        guard adding == nil else { return }
        adding = t.id
        Task {
            let ok = await onUse(t)
            adding = nil
            if !ok { problem = MusicError.download.description }
        }
    }
}
