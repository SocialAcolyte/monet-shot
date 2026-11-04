import AVFoundation
import UniformTypeIdentifiers
import MonetShotKit
import SwiftUI

/// The editor: preview over transport on the left, inspector on the right,
/// timeline along the bottom. Flat charcoal surfaces; colour only in the
/// recording itself and the blue-grey of whatever is selected.
struct EditorView: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewArea(model: model)
                        .padding(.horizontal, 28)
                        .padding(.top, 40)
                        .padding(.bottom, 14)
                    Group {
                        if model.cameraPhase != .off {
                            CameraBar(model: model)
                        } else if model.framing {
                            FrameBar(model: model)
                        } else {
                            TransportBar(model: model)
                        }
                    }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Palette.line.opacity(0.6)).frame(width: 1)
                InspectorView(model: model)
                    .frame(width: 284)
            }
            Rectangle().fill(Palette.line.opacity(0.6)).frame(height: 1)
            MonetShotTimeline(model: model)
                .frame(height: MonetShotTimeline.height(camera: !model.doc.cameraClips.isEmpty, textRows: Set(MonetShotTimeline.textRows(model.doc.overlays).values).count))
        }
        .background(Palette.charcoal)
        .foregroundStyle(Palette.moonWhite)
        .overlay {
            if model.showingMusic {
                MusicBrowserView(model: model.musicBrowser, close: model.closeMusic)
                    .transition(.opacity.animation(Motion.base()))
            }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()   // run under the transparent title bar
    }
}

/// The live render, letterboxed in the charcoal. Clicking it while a zoom
/// with a fixed focus is selected moves that focus to the clicked point.
struct PreviewArea: View {
    let model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let c = model.renderer.canvas
            let k = min(geo.size.width / c.width, geo.size.height / c.height)
            let shown = CGSize(width: c.width * k, height: c.height * k)
            Group {
                if let still = model.stillFrame {
                    Image(decorative: still, scale: 1).resizable()
                } else {
                    PlayerSurface(player: model.player) { p in
                // p is in the surface's own (shown) coordinates.
                guard let sel = model.selected, !sel.followsCursor,
                      let q = model.contentPoint(at: p, in: shown) else { return }
                model.setFocus(q)
                    }
                }
            }
            .frame(width: shown.width, height: shown.height)
            .overlay {
                if model.cameraPhase != .off {
                    CameraOverlay(model: model, scale: k)
                        .transition(.opacity.animation(Motion.base()))
                } else if model.framing {
                    FrameOverlay(model: model, shown: shown)
                        .transition(.opacity.animation(Motion.base()))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Drop a picture anywhere on the preview to make it the background.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else { return false }
            model.setBackdropImage(url)
            return true
        }
    }
}

struct TransportBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.togglePlay) {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PillButtonStyle())
            .help("Play / Pause (Space)")

            // Times in the finished video: trims and cuts already taken out.
            Text("\(Self.stamp(model.time)) / \(Self.stamp(model.duration))")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)

            Spacer()

            Button(action: model.reAuto) {
                Image(systemName: "sparkle.magnifyingglass")
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel("Auto zoom")
            .help("Zoom in on every cluster of clicks (keeps zooms you made by hand)")

            Menu {
                Button("Record a new take", systemImage: "record.circle", action: model.recordTake)
                Button("Add a video or recording…", systemImage: "film.stack", action: model.addFootage)
            } label: {
                Label("Add clip", systemImage: "plus.rectangle.on.rectangle")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.moonWhite)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.midnight))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add footage at the end: record another take, or bring in a video")

            Button(action: model.openCamera) {
                Label("Camera", systemImage: "person.crop.circle")
            }
            .buttonStyle(PillButtonStyle())
            .help("Record yourself, over the video or on your own (C)")

            Button(action: model.openMusic) {
                Label("Music", systemImage: "music.note")
            }
            .buttonStyle(PillButtonStyle())
            .help("Add music (M)")

            Button { model.openFraming() } label: {
                Label("Hide", systemImage: "eye.slash")
            }
            .buttonStyle(PillButtonStyle())
            .help("Blur parts of the screen, or crop it (B)")

            Button { model.split() } label: {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(PillButtonStyle())
            .help("Split the clip at the playhead (S)")

            Button { model.addZoom() } label: {
                Label("Zoom", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle())
            .help("Add a zoom at the playhead (Z)")
        }
        .labelStyle(.titleAndIcon)
    }

    /// "0:03.2"
    static func stamp(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// Flat charcoal pill buttons, pressed state a touch lighter.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(prominent ? Palette.charcoal : Palette.moonWhite)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Palette.moonWhite : Palette.midnight)
                    .brightness(configuration.isPressed ? 0.06 : 0)
            )
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.97 : 1)
            .animation(Motion.snappy(), value: configuration.isPressed)
    }
}

/// An AVPlayerLayer in a plain NSView, reporting clicks in top-left coordinates.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.player = player
        v.onClick = onClick
        return v
    }

    func updateNSView(_ v: PlayerNSView, context: Context) {
        v.onClick = onClick
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onClick: (CGPoint) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick(convert(event.locationInWindow, from: nil))
    }
}
