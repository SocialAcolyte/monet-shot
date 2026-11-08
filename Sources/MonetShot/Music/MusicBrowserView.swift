import MonetShotKit
import SwiftUI

/// The music browser: a tall charcoal panel docked over the inspector, so
/// your video stays in view. Click a track and it plays under the video
/// itself, from where it would start; the waveform shows the part you hear.
/// Shelves up top (for this video, favourites, the moods), tempo beside.
struct MusicBrowserView: View {
    let model: MusicBrowserModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.heading).font(.system(size: 17, weight: .bold, design: .rounded))
                        if let sub = model.subheading {
                            Text(sub).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.dim)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                    trackList
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            if let t = model.auditioning {
                NowPlayingBar(model: model, track: t)
                    .transition(.move(edge: .bottom).combined(with: .opacity).animation(Motion.base()))
            }
        }
        .frame(width: 452)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, x: -6, y: 10)
        .padding(.vertical, 12)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .foregroundStyle(Palette.moonWhite)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Music").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Free to use anywhere: no credit, no conditions")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Palette.faint)
                }
                Spacer()
                Button(action: model.chooseOwnFile) {
                    Label("Your own", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle())
                .help("Music you've licensed elsewhere (Artlist, Epidemic, your own)")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Palette.midnight))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.dim)
                TextField("Songs, artists, moods", text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, design: .rounded))
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Capsule().fill(Palette.midnight))
            shelves
            HStack(spacing: 6) {
                Text("Tempo").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Palette.faint)
                    .padding(.trailing, 4)
                ForEach(MusicTempo.allCases) { t in
                    Chip(title: t.name, tint: nil, on: model.tempo == t) { model.setTempo(t) }
                }
            }
        }
    }

    private var shelves: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                Chip(title: "For this video", systemImage: "sparkles", tint: nil,
                     on: model.query.isEmpty && model.shelf == .suggested) { model.show(.suggested) }
                Chip(title: "Favourites", systemImage: "heart", tint: nil,
                     on: model.query.isEmpty && model.shelf == .favourites) { model.show(.favourites) }
                ForEach(MusicMood.all) { m in
                    Chip(title: m.name, tint: Color(hex: m.tint), on: model.query.isEmpty && model.shelf == .mood(m.id)) { model.choose(m) }
                }
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private var trackList: some View {
        if let p = model.problem, model.tracks.isEmpty {
            Text(p).font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.dim).padding(.vertical, 30).padding(.horizontal, 6)
        } else if model.tracks.isEmpty && model.shelf != .favourites {
            Text("Nothing here. Try another word or tempo.").font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.dim)
                .padding(.vertical, 30).padding(.horizontal, 6)
        }
        LazyVStack(spacing: 2) {
            ForEach(model.tracks) { t in
                TrackRow(model: model, track: t)
            }
        }
    }
}

/// A shelf or tempo chip: a quiet capsule, filled when chosen.
private struct Chip: View {
    let title: String
    var systemImage: String?
    let tint: Color?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let tint { Circle().fill(tint).frame(width: 7, height: 7) }
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(on ? Palette.charcoal : Palette.moonWhite.opacity(0.85))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(on ? Palette.moonWhite : Palette.midnight))
        }
        .buttonStyle(.plain)
        .animation(Motion.snappy(), value: on)
    }
}

/// One track: cover (with play), title, artist, mood and tempo, a heart and
/// Use; under it the waveform, the part that plays under the video lit.
private struct TrackRow: View {
    let model: MusicBrowserModel
    let track: Song

    private var current: Bool { model.auditioning?.id == track.id }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 12) {
                ZStack {
                    Artwork(song: track, size: 42)
                    if current {
                        RoundedRectangle(cornerRadius: 42 * 0.14, style: .continuous).fill(Color.black.opacity(0.45))
                        if model.playing { Equalizer() } else { Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)) }
                    }
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(current ? Palette.violet : Palette.moonWhite)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(MusicTime.clock(track.duration))
                    .font(.system(size: 11.5, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Palette.faint)
                Button { model.toggleFavourite(track) } label: {
                    Image(systemName: model.isFavourite(track) ? "heart.fill" : "heart")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.isFavourite(track) ? Palette.clay : Palette.faint)
                        .frame(width: 24, height: 24)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(model.isFavourite(track) ? "Remove from favourites" : "Keep in favourites")
                Button { model.use(track) } label: {
                    if model.adding == track.id { ProgressView().controlSize(.small).frame(width: 30) } else { Text("Use") }
                }
                .buttonStyle(PillButtonStyle(prominent: current))
                .disabled(model.adding != nil)
            }
            TrackWave(peaks: track.peaks ?? [], window: model.window(for: track),
                      at: current ? model.auditionFraction : nil, lit: current)
                .frame(height: 20)
                .padding(.leading, 54)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(current ? Palette.midnight : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.toggleAudition(track) }
        .help(track.about ?? "")
        .animation(Motion.snappy(), value: current)
    }

    private var detail: String {
        [track.artist, track.genres.first?.capitalized ?? "", MusicTempo.of(track)?.name ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A track's waveform: thin bars, the stretch under the video brighter, and
/// while it plays, a line where it is.
struct TrackWave: View {
    let peaks: [Double]
    let window: ClosedRange<Double>?
    let at: Double?
    let lit: Bool

    var body: some View {
        Canvas { ctx, size in
            let bars = peaks.isEmpty ? Array(repeating: 0.25, count: 64) : peaks
            let step = size.width / CGFloat(bars.count)
            for (i, p) in bars.enumerated() {
                let x = CGFloat(i) * step
                let f = (Double(i) + 0.5) / Double(bars.count)
                let inside = window.map { $0.contains(f) } ?? false
                let h = max(2, CGFloat(p) * size.height)
                let r = CGRect(x: x + step * 0.18, y: (size.height - h) / 2, width: max(1, step * 0.64), height: h)
                let colour = inside ? (lit ? Palette.violet : Palette.moonWhite.opacity(0.62)) : Palette.moonWhite.opacity(0.16)
                ctx.fill(Path(roundedRect: r, cornerRadius: r.width / 2), with: .color(colour))
            }
            if let at {
                let x = CGFloat(at) * size.width
                ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Palette.moonWhite))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The bar along the foot while a track plays under the video.
private struct NowPlayingBar: View {
    let model: MusicBrowserModel
    let track: Song

    var body: some View {
        HStack(spacing: 12) {
            Button { model.toggleAudition(track) } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.moonWhite))
                    .foregroundStyle(Palette.charcoal)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
                Text("Playing under your video").font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.dim).lineLimit(1)
            }
            Spacer()
            Button { model.use(track) } label: {
                if model.adding == track.id {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Adding") }
                } else {
                    Text("Use this track")
                }
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(model.adding != nil)
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(Palette.charcoal)
    }
}

/// Album art from the catalogue, or a quiet placeholder.
struct Artwork: View {
    let song: Song
    let size: CGFloat

    var body: some View {
        Group {
            if let url = song.artworkURL.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) } else { GeneratedCover(song: song, size: size) }
                }
            } else {
                GeneratedCover(song: song, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
    }
}

/// A cover for tracks that come without one: a warm gradient keyed to the
/// track's feel, faint record grooves in the corner, and its initial.
struct GeneratedCover: View {
    let song: Song
    let size: CGFloat

    private var tints: (Color, Color) {
        let feel = song.genres.first?.lowercased() ?? ""
        let base = MusicMood.all.first { $0.feel == feel }?.tint
            ?? MusicMood.all[Int(Self.hash(song.title) % UInt32(MusicMood.all.count))].tint
        return (Color(hex: base), Color(hex: base).opacity(0.45))
    }

    static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt32(b) }
        return h
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [tints.0, tints.1], startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(Palette.charcoal)
            ForEach(0..<4, id: \.self) { k in
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: max(0.6, size / 70))
                    .frame(width: size * (0.5 + CGFloat(k) * 0.28), height: size * (0.5 + CGFloat(k) * 0.28))
                    .position(x: size * 0.95, y: size * 0.1)
            }
            Text(String(song.title.prefix(1)).uppercased())
                .font(.system(size: size * 0.44, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .padding(.leading, size * 0.12)
                .padding(.bottom, size * 0.04)
        }
        .frame(width: size, height: size)
    }
}

/// Three bars dancing while a preview plays.
private struct Equalizer: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: Motion.reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(Palette.violet)
                        .frame(width: 3, height: 5 + 9 * abs(sin(t * (5.1 + Double(i) * 1.7) + Double(i))))
                }
            }
            .frame(height: 14, alignment: .bottom)
        }
    }
}

enum MusicTime {
    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
