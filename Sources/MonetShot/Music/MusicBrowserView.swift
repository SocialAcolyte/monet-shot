import MonetShotKit
import SwiftUI

/// The music browser: a tall charcoal panel over the editor, in the manner
/// of a streaming app. Search and mood tiles up top, a long album-art list
/// that keeps loading as you scroll, and a now-playing bar with Use.
struct MusicBrowserView: View {
    let model: MusicBrowserModel
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        moods
                        Text(model.query.isEmpty ? (model.mood?.name ?? "Instrumental") : "Results")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .padding(.top, 4)
                        trackList
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.never)
                if let t = model.previewing {
                    NowPlayingBar(model: model, track: t)
                        .transition(.move(edge: .bottom).combined(with: .opacity).animation(Motion.base()))
                }
            }
            .frame(width: 760)
            .frame(maxHeight: .infinity)
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
            .padding(.vertical, 44)
        }
        .foregroundStyle(Palette.moonWhite)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Music").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Kevin MacLeod's library, free to use with a credit (MonetShot keeps it for you)")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Palette.faint)
                }
                Spacer()
                Button(action: model.chooseOwnFile) {
                    Label("Use your own", systemImage: "folder")
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
                    .font(.system(size: 14, design: .rounded))
                if model.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Capsule().fill(Palette.midnight))
        }
    }

    private var moods: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
            ForEach(MusicMood.all) { m in
                let on = model.query.isEmpty && model.mood?.id == m.id
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: m.tint), Color(hex: m.tint).opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    // A leaning disc in the corner, as album tiles do.
                    Circle()
                        .fill(Color.black.opacity(0.18))
                        .frame(width: 46, height: 46)
                        .overlay(Circle().fill(Color.white.opacity(0.12)).frame(width: 12, height: 12))
                        .rotationEffect(.degrees(22))
                        .offset(x: 92, y: -18)
                    Text(m.name)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .padding(10)
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.violet, lineWidth: 2).opacity(on ? 1 : 0))
                .contentShape(Rectangle())
                .onTapGesture { model.choose(m) }
                .animation(Motion.snappy(), value: on)
            }
        }
    }

    @ViewBuilder private var trackList: some View {
        if let p = model.problem, model.tracks.isEmpty {
            Text(p).font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.dim).padding(.vertical, 30)
        } else if model.tracks.isEmpty && !model.loading {
            Text("No tracks found. Try another word.").font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.dim).padding(.vertical, 30)
        }
        LazyVStack(spacing: 2) {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(model: model, track: t, number: i + 1)
            }
        }
    }
}

/// One track: number (or a playing equaliser), artwork, title, artist and
/// genre, licence, length. Click to preview; Use to put it under the video.
private struct TrackRow: View {
    let model: MusicBrowserModel
    let track: Song
    let number: Int

    private var current: Bool { model.previewing?.id == track.id }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if current && model.previewPlaying {
                    Equalizer()
                } else {
                    Text("\(number)")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(current ? Palette.violet : Palette.faint)
                }
            }
            .frame(width: 26)
            Artwork(song: track, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(current ? Palette.violet : Palette.moonWhite)
                    .lineLimit(1)
                Text(([track.genres.prefix(2).joined(separator: ", ")] + [track.bpm.map { "\($0) bpm" } ?? ""]).filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(track.licenseLabel)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.dim)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            Text(MusicTime.clock(track.duration))
                .font(.system(size: 12.5, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)
                .frame(width: 40, alignment: .trailing)
            Button { model.use(track) } label: {
                if model.adding == track.id { ProgressView().controlSize(.small).frame(width: 34) } else { Text("Use") }
            }
            .buttonStyle(PillButtonStyle(prominent: current))
            .disabled(model.adding != nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(current ? Palette.midnight : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.togglePreview(track) }
        .help(track.about ?? "")
        .animation(Motion.snappy(), value: current)
    }
}

/// The bar along the foot while something is previewing.
private struct NowPlayingBar: View {
    let model: MusicBrowserModel
    let track: Song

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.line)
                    Rectangle().fill(Palette.violet).frame(width: g.size.width * model.previewProgress)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in model.seekPreview(to: max(0, min(1, v.location.x / g.size.width))) })
            }
            .frame(height: 3)
            HStack(spacing: 14) {
                Artwork(song: track, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                    Text(track.artist).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.dim).lineLimit(1)
                }
                Spacer()
                Button { model.togglePreview(track) } label: {
                    Image(systemName: model.previewPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Palette.moonWhite))
                        .foregroundStyle(Palette.charcoal)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
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
            .padding(.horizontal, 20)
            .frame(height: 70)
        }
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
