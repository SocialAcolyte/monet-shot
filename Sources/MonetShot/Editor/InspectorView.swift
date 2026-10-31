import MonetShotKit
import SwiftUI

/// The right-hand column: the selected zoom, the frame, the cursor, the
/// output, and Export at the foot. Every control writes straight to the
/// edit, which re-renders the preview at once.
struct InspectorView: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let i = model.selectedClip, model.clips.indices.contains(i) { clipSection(i) }
                    zoomSection
                    privacySection
                    musicSection
                    frameSection
                    cursorSection
                    cameraSection
                    outputSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 42)
                .padding(.bottom, 20)
            }
            // Snapshot aid: MONETSHOT_SNAPSHOT_SCROLL=bottom shows the last sections.
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["MONETSHOT_SNAPSHOT_SCROLL"] == "bottom" ? .bottom : .top)
            .scrollIndicators(.never)
            Rectangle().fill(Palette.line.opacity(0.6)).frame(height: 1)
            ExportBar(model: model)
                .padding(16)
        }
        .background(Palette.panel)
        .tint(Palette.violet)
    }

    // MARK: sections

    @ViewBuilder private var zoomSection: some View {
        Section("Zoom") {
            if let seg = model.selected {
                SliderRow("Depth", value: Binding(get: { seg.scale }, set: { v in model.setSelected { $0.scale = v } }),
                          range: 1.2...4, format: { String(format: "%.1f×", $0) })
                Picker("", selection: Binding(
                    get: { seg.followsCursor },
                    set: { follow in
                        if follow { model.setFocus(nil) } else {
                            model.setFocus(model.cameraCentre(at: max(seg.start, min(model.time, seg.end))))
                        }
                    })) {
                    Text("Follow cursor").tag(true)
                    Text("Hold still").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if !seg.followsCursor {
                    Hint("Click the preview to choose where it looks.")
                }
                Button(role: .destructive) { model.deleteSelected() } label: {
                    Label("Remove zoom", systemImage: "trash")
                }
                .buttonStyle(PillButtonStyle())
            } else {
                Hint(model.doc.segments.isEmpty
                     ? "No zooms yet. Auto zoom finds your clicks; Z adds one at the playhead."
                     : "Select a zoom on the timeline to change it.")
            }
        }
    }

    @ViewBuilder private var privacySection: some View {
        Section("Hide & crop") {
            if let b = model.selectedBlur {
                Picker("", selection: Binding(get: { b.style }, set: { v in model.setBlur(b.id) { $0.style = v } })) {
                    ForEach(BlurStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if b.style != .solid {
                    SliderRow("Strength", value: Binding(get: { b.strength }, set: { v in model.setBlur(b.id) { $0.strength = v } }),
                              range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
                }
                Hint(b.always
                     ? "Hidden for the whole take. Move the playhead and set a start or end to hide it only for a while."
                     : "Hidden from \(b.start.map(TransportBar.stamp) ?? "the start") to \(b.end.map(TransportBar.stamp) ?? "the end") of the take.")
                HStack(spacing: 8) {
                    Button("Start here", action: model.setBlurStart)
                        .buttonStyle(PillButtonStyle())
                        .help("Hide it from the playhead on")
                    Button("End here", action: model.setBlurEnd)
                        .buttonStyle(PillButtonStyle())
                        .help("Stop hiding it at the playhead")
                    if !b.always {
                        Button("Always", action: model.blurAlways)
                            .buttonStyle(PillButtonStyle())
                            .help("Hide it for the whole take")
                    }
                }
                Button(role: .destructive) { model.deleteBlur(b.id) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(PillButtonStyle())
            } else {
                let n = model.doc.blurs.count
                let cropped = !model.doc.crops.isEmpty
                Hint(n == 0 && !cropped
                     ? "Blur a chat or an inbox out of the video, or crop the screen down to what matters."
                     : [n > 0 ? "\(n) part\(n == 1 ? "" : "s") hidden" : nil, cropped ? "cropped" : nil]
                        .compactMap { $0 }.joined(separator: ", ") + (model.framing ? ". Select a box to change it." : "."))
                if !model.framing {
                    HStack(spacing: 8) {
                        Button { model.openFraming(.blur) } label: { Label("Hide…", systemImage: "eye.slash") }
                            .buttonStyle(PillButtonStyle())
                            .help("Draw boxes over what shouldn't be seen (B)")
                        Button { model.openFraming(.crop) } label: { Label("Crop…", systemImage: "crop") }
                            .buttonStyle(PillButtonStyle())
                            .help("Keep only part of the screen")
                    }
                }
            }
        }
    }

    private func clipSection(_ i: Int) -> some View {
        let c = model.clips[i]
        return Section("Clip \(i + 1) of \(model.clips.count)") {
            Hint("\(model.project.takes.count > 1 ? "Take \(c.take + 1), " : "")\(TransportBar.stamp(c.start)) to \(TransportBar.stamp(c.end)), \(String(format: "%.1f", c.duration)) s. Drag its ends to trim it, or its middle to move it. ⌘Z undoes.")
            HStack(spacing: 8) {
                Button { model.split() } label: { Label("Split", systemImage: "scissors") }
                    .buttonStyle(PillButtonStyle())
                    .help("Split at the playhead (S)")
                Button(role: .destructive) { model.deleteClip(i) } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.clips.count < 2)
                    .help("Leave this clip out (Delete)")
            }
        }
    }

    @ViewBuilder private var musicSection: some View {
        Section("Music") {
            if let m = model.doc.music {
                HStack(spacing: 10) {
                    Artwork(song: m.track, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.track.title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text("\(m.track.artist) · \(m.track.licenseLabel)")
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(Palette.dim).lineLimit(1)
                    }
                }
                SnippetPicker(model: model, music: m)
                SliderRow("Volume", value: Binding(get: { m.volume }, set: { v in model.setMusic { $0.volume = v } }),
                          range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
                ToggleRow("Fade in", isOn: Binding(get: { m.fadeIn }, set: { v in model.setMusic { $0.fadeIn = v } }))
                ToggleRow("Fade out", isOn: Binding(get: { m.fadeOut }, set: { v in model.setMusic { $0.fadeOut = v } }))
                if m.track.needsCredit {
                    Button(action: model.copyCredit) {
                        Label("Copy credit", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.violet)
                    .help("This licence asks for a credit; it's also saved beside every export")
                }
                HStack(spacing: 8) {
                    Button(action: model.openMusic) { Label("Change", systemImage: "music.note.list") }
                        .buttonStyle(PillButtonStyle())
                    Button(role: .destructive, action: model.removeMusic) { Label("Remove", systemImage: "trash") }
                        .buttonStyle(PillButtonStyle())
                }
            } else {
                Button(action: model.openMusic) {
                    Label("Add music", systemImage: "music.note").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }

    private var frameSection: some View {
        Section("Frame") {
            HStack(spacing: 8) {
                ForEach(Backdrop.allCases.filter { $0 != .image }, id: \.self) { b in
                    Swatch(backdrop: b, selected: model.doc.backdrop == b)
                        .onTapGesture { model.update { $0.backdrop = b } }
                        .help(b.label)
                }
                ImageSwatch(url: model.backdropImageURL, selected: model.doc.backdrop == .image)
                    .onTapGesture {
                        if model.doc.backdropImage != nil {
                            model.update { $0.backdrop = .image }
                        } else if let first = BackdropGallery.paintings.first {
                            model.setBackdropImage(first.url, as: first.copyName)
                        } else {
                            model.chooseBackdropImage()
                        }
                    }
                    .help(model.doc.backdropImage == nil ? "Use a painting, or a picture of your own" : "Picture")
            }
            if model.doc.backdrop == .image {
                if !BackdropGallery.paintings.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                        ForEach(BackdropGallery.paintings) { p in
                            PaintingTile(painting: p, selected: model.doc.backdropImage == p.copyName)
                                .onTapGesture { model.setBackdropImage(p.url, as: p.copyName) }
                                .help("\(p.title), \(p.artist)")
                        }
                    }
                }
                SliderRow("Blur", value: bind(\.backdropBlur), range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
                Button { model.chooseBackdropImage() } label: {
                    Label("Your own picture…", systemImage: "photo")
                }
                .buttonStyle(PillButtonStyle())
            }
            if model.doc.backdrop != .none {
                SliderRow("Padding", value: bind(\.padding), range: 0...0.16, format: { "\(Int(($0 * 100).rounded()))" })
                SliderRow("Corners", value: bind(\.cornerRadius), range: 0...0.05, format: { "\(Int(($0 * 1000).rounded()))" })
                ToggleRow("Shadow", isOn: bind(\.shadow))
            }
        }
    }

    private var cursorSection: some View {
        Section("Cursor") {
            ToggleRow("Show cursor", isOn: bind(\.cursorVisible))
            if model.doc.cursorVisible {
                HStack(spacing: 6) {
                    ForEach(CursorStyle.allCases, id: \.self) { style in
                        CursorTile(style: style, tint: model.doc.cursorTint, selected: model.doc.cursorStyle == style)
                            .onTapGesture { model.update { $0.cursorStyle = style } }
                            .help(style.label)
                    }
                }
                if model.doc.cursorStyle.tinted {
                    HStack(spacing: 8) {
                        ForEach(CursorTint.allCases, id: \.self) { tint in
                            Circle().fill(Color(hex: tint.hex))
                                .frame(width: 16, height: 16)
                                .padding(3)
                                .overlay(Circle().strokeBorder(Palette.violet, lineWidth: 1.6).opacity(model.doc.cursorTint == tint ? 1 : 0))
                                .contentShape(Circle())
                                .onTapGesture { model.update { $0.cursorTint = tint } }
                                .help(tint.rawValue.capitalized)
                        }
                    }
                }
                if model.doc.cursorStyle == .tag {
                    TextField("Your name", text: bind(\.cursorLabel))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .rounded))
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.midnight))
                }
                SliderRow("Size", value: bind(\.cursorScale), range: 0.8...3, format: { String(format: "%.1f×", $0) })
                SliderRow("Smoothing", value: bind(\.cursorSmoothing), range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
                ToggleRow("Click ripples", isOn: bind(\.clickRipple))
            }
        }
    }

    @ViewBuilder private var cameraSection: some View {
        Section("Camera") {
            if model.hasCamera {
                ToggleRow("Show camera", isOn: bind(\.cameraLook.visible))
                if model.doc.cameraLook.visible {
                    HStack(spacing: 8) {
                        Picker("", selection: bind(\.cameraLook.shape)) {
                            ForEach(CameraShape.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        CornerPicker(corner: bind(\.cameraLook.corner))
                    }
                    SliderRow("Size", value: bind(\.cameraLook.size), range: 0.14...0.5, format: { "\(Int(($0 * 100).rounded()))%" })
                    ToggleRow("Mirror", isOn: bind(\.cameraLook.mirror))
                    if model.doc.music != nil { ToggleRow("Lower music while you talk", isOn: bind(\.cameraLook.duckMusic)) }
                }
                ForEach(model.doc.cameraClips) { c in
                    HStack(spacing: 8) {
                        Image(systemName: c.full ? "rectangle.inset.filled" : "person.crop.circle")
                            .foregroundStyle(Palette.violet)
                        Text("\(TransportBar.stamp(c.at)) – \(TransportBar.stamp(c.end))")
                            .font(.system(size: 12, design: .rounded)).monospacedDigit()
                            .onTapGesture { model.seek(to: c.at + 0.05) }
                        Spacer()
                        Button(c.full ? "Full" : "Bubble") { model.setCameraClip(c.id) { $0.full.toggle() } }
                            .buttonStyle(PillButtonStyle())
                            .help("Fill the frame with you, or sit in the bubble")
                        Button { model.deleteCameraClip(c.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(PillButtonStyle())
                            .help("Delete this camera clip")
                    }
                }
            } else {
                Hint("Talk over the video as it plays, or record a clip of just you.")
            }
            Button(action: model.openCamera) {
                Label("Record yourself", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    private var outputSection: some View {
        Section("Output") {
            Picker("", selection: bind(\.outputWidth)) {
                Text("1080p").tag(1920)
                Text("1440p").tag(2560)
                Text("4K").tag(3840)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: Binding(
                get: { model.doc.canvasAspect == 0 ? 0 : (abs(model.doc.canvasAspect - 1) < 0.01 ? 1 : 16.0 / 9.0) },
                set: { v in model.update { $0.canvasAspect = v } })) {
                Text("16:9").tag(16.0 / 9.0)
                Text("Square").tag(1.0)
                Text("As recorded").tag(0.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let size = model.doc.canvasSize(recordingAspect: model.project.meta.aspect)
            Hint("\(size.width) × \(size.height), 60 fps")
        }
    }

    private func bind<T>(_ key: WritableKeyPath<EditDoc, T>) -> Binding<T> {
        Binding(get: { model.doc[keyPath: key] }, set: { v in model.update { $0[keyPath: key] = v } })
    }
}

// MARK: parts

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(Palette.faint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(Palette.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SliderRow: View {
    let label: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let format: (Double) -> String
    init(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.label = label
        self.value = value
        self.range = range
        self.format = format
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.moonWhite)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.dim)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }
}

private struct ToggleRow: View {
    let label: String
    let isOn: Binding<Bool>
    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self.isOn = isOn
    }
    var body: some View {
        Toggle(isOn: isOn) {
            Text(label).font(.system(size: 12, design: .rounded)).foregroundStyle(Palette.moonWhite)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Four dots in a little square: which corner the camera bubble sits in.
private struct CornerPicker: View {
    let corner: Binding<CameraCorner>

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { dot(.topLeft); dot(.topRight) }
            GridRow { dot(.bottomLeft); dot(.bottomRight) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.midnight))
        .help("Corner")
    }

    private func dot(_ c: CameraCorner) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(corner.wrappedValue == c ? Palette.violet : Palette.faint.opacity(0.5))
            .frame(width: 12, height: 8)
            .contentShape(Rectangle())
            .onTapGesture { corner.wrappedValue = c }
    }
}

/// One cursor style, drawn by the same code the export uses.
private struct CursorTile: View {
    let style: CursorStyle
    let tint: CursorTint
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0xE9E6DF))
            if let art = CursorArt.image(style: style, tint: tint, label: "Hi", pixelHeight: 40) {
                Image(decorative: art.image, scale: 2)
                    .offset(x: style == .tag ? 3 : 0)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(2.5)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.violet, lineWidth: 1.6).opacity(selected ? 1 : 0))
        .scaleEffect(selected && !Motion.reduceMotion ? 1.04 : 1)
        .animation(Motion.snappy(), value: selected)
        .contentShape(Rectangle())
    }
}

/// A small disc showing each backdrop as it renders.
private struct Swatch: View {
    let backdrop: Backdrop
    let selected: Bool

    private var fill: AnyShapeStyle {
        switch backdrop {
        case .paper: AnyShapeStyle(Color(hex: 0xF3F0E8))
        case .charcoal: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x303336), Color(hex: 0x17191B)], startPoint: .top, endPoint: .bottom))
        case .dusk: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xB8694A), Color(hex: 0x2B211C)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .slate: AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x6E8088), Color(hex: 0x252C30)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .none: AnyShapeStyle(Color.black)
        case .image: AnyShapeStyle(Palette.midnight)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            if backdrop == .none {
                Image(systemName: "rectangle.slash").font(.system(size: 9)).foregroundStyle(Palette.dim)
            }
        }
        .frame(width: 24, height: 24)
        .padding(3)
        .overlay(Circle().strokeBorder(Palette.violet, lineWidth: 1.6).opacity(selected ? 1 : 0))
        .scaleEffect(selected && !Motion.reduceMotion ? 1.04 : 1)
        .animation(Motion.snappy(), value: selected)
        .contentShape(Circle())
    }
}

/// Export at the foot of the inspector: a pill that fills as it renders,
/// then offers the file.
struct ExportBar: View {
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = model.exportProgress {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.midnight)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Palette.violet.opacity(0.45))
                            .frame(width: max(18, g.size.width * p))
                            .animation(Motion.base(), value: p)
                    }
                    Text("Exporting \(Int((p * 100).rounded()))%")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .padding(.leading, 12)
                }
                .frame(height: 34)
            } else {
                Button(action: model.export) {
                    Text("Export MP4").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut("e", modifiers: .command)
                .help("Render the video next to the recording (⌘E)")
            }
            if let url = model.exportedURL, model.exportProgress == nil {
                Button(action: model.revealExport) {
                    Label(url.lastPathComponent, systemImage: "checkmark")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.violet)
                .help("Show in Finder")
                .transition(.opacity)
            }
            if let err = model.exportError {
                Text(err).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Palette.clay)
            }
        }
        .animation(Motion.base(), value: model.exportProgress == nil)
    }
}

/// The picture backdrop's swatch: the chosen picture in a disc, or a "+".
private struct ImageSwatch: View {
    let url: URL?
    let selected: Bool

    var body: some View {
        ZStack {
            if let url, let ns = NSImage(contentsOf: url) {
                Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle().fill(Palette.midnight)
                Image(systemName: "photo.badge.plus").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .padding(3)
        .overlay(Circle().strokeBorder(Palette.violet, lineWidth: 1.6).opacity(selected ? 1 : 0))
        .scaleEffect(selected && !Motion.reduceMotion ? 1.04 : 1)
        .animation(Motion.snappy(), value: selected)
        .contentShape(Circle())
    }
}

/// One of the gallery's paintings, as a small card.
private struct PaintingTile: View {
    let painting: BackdropGallery.Painting
    let selected: Bool

    var body: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let ns = BackdropGallery.thumb(painting) {
                    Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Palette.midnight
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.violet, lineWidth: 1.6).opacity(selected ? 1 : 0))
            .animation(Motion.snappy(), value: selected)
            .contentShape(Rectangle())
    }
}

/// The song as a waveform with a bright window the length of the video:
/// slide the window to choose which part of the song plays (as when you
/// pick the part of a song for a story).
private struct SnippetPicker: View {
    let model: EditorModel
    let music: MusicChoice

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let song = max(music.track.duration, 0.1)
            let video = model.renderer.map.duration
            let winW = max(12, min(w, CGFloat(video / song) * w))
            let winX = CGFloat(music.offset / song) * w
            ZStack(alignment: .leading) {
                Canvas { ctx, size in
                    let bars = model.musicWave.isEmpty ? Array(repeating: Float(0.3), count: 120) : model.musicWave
                    let step = size.width / CGFloat(bars.count)
                    for (i, v) in bars.enumerated() {
                        let h = max(2, CGFloat(v) * size.height * 0.9)
                        let x = CGFloat(i) * step
                        let inside = x >= winX && x <= winX + winW
                        ctx.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: max(1, step - 1), height: h), cornerRadius: 1),
                                 with: .color(inside ? Palette.moonWhite : Palette.faint.opacity(0.6)))
                    }
                }
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.violet, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.violet.opacity(0.12)))
                    .frame(width: winW)
                    .offset(x: winX)
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                model.beginMusicDragIfNeeded()
                                model.dragMusic(bySeconds: Double(v.translation.width / w) * song)
                            }
                            .onEnded { _ in model.endMusicDrag() }
                    )
            }
        }
        .frame(height: 44)
        .help("Drag to choose which part of the song plays")
        Text("Plays \(MusicTime.clock(music.offset))–\(MusicTime.clock(min(music.track.duration, music.offset + model.renderer.map.duration))) of \(MusicTime.clock(music.track.duration))")
            .font(.system(size: 11, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.dim)
    }
}
