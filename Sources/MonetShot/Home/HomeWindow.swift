import AppKit
import AVFoundation
import Observation
import MonetShotKit
import SwiftUI
import UniformTypeIdentifiers

/// The recordings, as cards. Opens from the menu bar (Open MonetShot) and when
/// MonetShot is launched, so you can get back to any edit without recording.
@MainActor
@Observable
final class HomeModel {
    struct Item: Identifiable {
        let url: URL
        let title: String
        let duration: Double
        let clips: Int
        let takes: Int
        var id: URL { url }
    }

    private(set) var items: [Item] = []
    private(set) var thumbs: [URL: CGImage] = [:]
    private(set) var importing = false

    @ObservationIgnored var open: (URL) -> Void = { _ in }
    @ObservationIgnored var record: () -> Void = {}

    func refresh() {
        let dir = Project.libraryDir
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "reel" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        items = urls.compactMap { url in
            guard let p = try? Project.load(url) else { return nil }
            return Item(url: url, title: Library.title(for: url), duration: TimeMap(clips: p.clips).duration,
                        clips: p.clips.count, takes: p.takes.count)
        }
        Task { await loadThumbs() }
    }

    /// A small render of each recording (with its backdrop), cached beside
    /// its edit and redrawn when the edit changes.
    private func loadThumbs() async {
        for item in items {
            let file = item.url.appendingPathComponent("thumb.jpg")
            let edit = item.url.appendingPathComponent("edit.json")
            let thumbDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let editDate = (try? edit.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let thumbDate, thumbDate >= editDate {
                if thumbs[item.url] == nil, let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    thumbs[item.url] = img
                }
                continue
            }
            guard let p = try? Project.load(item.url),
                  let full = try? await Composer.frame(p, at: min(1.5, item.duration / 3)),
                  let small = Self.shrink(full, width: 640) else { continue }
            thumbs[item.url] = small
            if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, small, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    static func shrink(_ img: CGImage, width: Int) -> CGImage? {
        let h = Int(Double(img.height) * Double(width) / Double(img.width))
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        return ctx.makeImage()
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a video to edit in MonetShot"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let folder = try await Imports.newProject(fromVideo: url)
                Log.info("imported \(url.lastPathComponent) as \(folder.lastPathComponent)")
                refresh()
                open(folder)
            } catch {
                Log.error("import: \(error)")
            }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// To the Trash (so it can be put back), never deleted outright.
    func trash(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, _ in
            Task { @MainActor in
                self?.thumbs[url] = nil
                self?.refresh()
            }
        }
    }
}

@MainActor
final class HomeWindow: NSObject, NSWindowDelegate {
    let model = HomeModel()
    let window: NSWindow
    var onClose: () -> Void = {}

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "MonetShot"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x17 / 255, green: 0x19 / 255, blue: 0x1B / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 440)
        window.contentViewController = NSHostingController(rootView: HomeView(model: model))
        window.setFrameAutosaveName("MonetShotHome")
        if window.frame.width < 620 { window.center() }
        window.delegate = self
    }

    func show() {
        model.refresh()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

struct HomeView: View {
    let model: HomeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Aperture(recording: false, busy: false)
                    .foregroundStyle(Palette.moonWhite)
                    .frame(width: 24, height: 24)
                Text("MonetShot").font(.system(size: 28, weight: .bold, design: .rounded))
                Spacer()
                Button(action: model.importVideo) {
                    if model.importing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Importing") }
                    } else {
                        Label("Import video", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.importing)
                .help("Edit any video in MonetShot")
                Button(action: model.record) { Label("New recording", systemImage: "record.circle") }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
            .padding(.horizontal, 32)
            .padding(.top, 46)
            .padding(.bottom, 24)

            if model.items.isEmpty {
                VStack(spacing: 14) {
                    Aperture(recording: false, busy: true).frame(width: 54, height: 54)
                    Text("Nothing recorded yet").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("Click the ring in the menu bar, or New recording.")
                        .font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 22)], spacing: 26) {
                        ForEach(model.items) { item in
                            Card(item: item, thumb: model.thumbs[item.url])
                                .onTapGesture { model.open(item.url) }
                                .contextMenu {
                                    Button("Open") { model.open(item.url) }
                                    Button("Show in Finder") { model.reveal(item.url) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { model.trash(item.url) }
                                }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.charcoal)
        .foregroundStyle(Palette.moonWhite)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

private struct Card: View {
    let item: HomeModel.Item
    let thumb: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.panel)
                if let thumb {
                    Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.dim)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts = [MusicTime.clock(item.duration)]
        if item.clips > 1 { parts.append("\(item.clips) clips") }
        if item.takes > 1 { parts.append("\(item.takes) takes") }
        return parts.joined(separator: " · ")
    }
}
