import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Observation
import MonetShotKit

/// The music browser's state: search, moods, the paged track list, and a
/// preview player. Views read it and call its methods.
@MainActor
@Observable
final class MusicBrowserModel {
    private(set) var query = ""
    private(set) var mood: MusicMood? = MusicMood.all.first
    private(set) var tracks: [Song] = []
    private(set) var loading = false
    private(set) var problem: String?
    private(set) var previewing: Song?
    private(set) var previewPlaying = false
    private(set) var previewProgress: Double = 0
    /// The track being downloaded into the recording.
    private(set) var adding: String?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?

    /// Called with the chosen track; returns when it's in the recording (or failed).
    @ObservationIgnored var onUse: (Song) async -> Bool = { _ in false }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let d = self.previewing?.duration, d > 0 else { return }
                self.previewProgress = min(1, t.seconds / d)
            }
        }
    }

    func start() {
        if tracks.isEmpty { reload() }
    }

    func stop() {
        player.pause()
        previewPlaying = false
    }

    func setQuery(_ q: String) {
        query = q
        if !q.isEmpty { mood = nil } else if mood == nil { mood = MusicMood.all.first }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))   // wait for typing to pause
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func choose(_ m: MusicMood) {
        mood = m
        query = ""
        reload()
    }

    /// The whole list for the current search or mood; the catalogue is local
    /// once fetched, so this is instant after the first time.
    func reload() {
        generation += 1
        let gen = generation, q = query, m = mood
        loading = true
        problem = nil
        Task {
            do {
                let result = try await MusicCatalog.search(q, mood: q.isEmpty ? m : nil)
                guard gen == generation else { return }
                tracks = result
            } catch {
                if gen == generation { problem = "Couldn't reach the music library. Check your connection." }
                Log.error("music: \(error)")
            }
            if gen == generation { loading = false }
        }
    }

    /// Music you've licensed elsewhere (a file on this Mac).
    func chooseOwnFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a music file you have the rights to use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { use(await MusicCatalog.ownFile(url)) }
    }

    func togglePreview(_ t: Song) {
        if previewing?.id == t.id {
            if previewPlaying { player.pause() } else { player.play() }
            previewPlaying.toggle()
            return
        }
        guard let url = URL(string: t.audioURL) else { return }
        previewing = t
        previewProgress = 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        previewPlaying = true
    }

    func seekPreview(to fraction: Double) {
        guard let d = previewing?.duration else { return }
        player.seek(to: CMTime(seconds: d * fraction, preferredTimescale: 600))
        previewProgress = fraction
    }

    func use(_ t: Song) {
        guard adding == nil else { return }
        adding = t.id
        stop()
        Task {
            let ok = await onUse(t)
            adding = nil
            if !ok { problem = MusicError.download.description }
        }
    }
}
