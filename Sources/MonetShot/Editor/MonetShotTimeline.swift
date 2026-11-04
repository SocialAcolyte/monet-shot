import MonetShotKit
import SwiftUI
import UniformTypeIdentifiers

/// The timeline, on the finished video's clock: a ruler to scrub, the clips
/// end to end (each a filmstrip of its own take, with handles to shorten or
/// lengthen it; drag one to reorder), and the zoom track, where zooms ride on
/// the footage they were made on. Drop videos here to add them as clips.
struct MonetShotTimeline: View {
    let model: EditorModel
    private let inset: CGFloat = 20
    private let rulerH: CGFloat = 22
    private let stripY: CGFloat = 30
    private let stripH: CGFloat = 54
    private let trackY: CGFloat = 96
    private let trackH: CGFloat = 32
    static let cameraH: CGFloat = 22
    static let textH: CGFloat = 22
    /// Height for the editor to give the timeline.
    static func height(camera: Bool, textRows: Int = 0) -> CGFloat { 158 + (camera ? 28 : 0) + CGFloat(min(textRows, maxTextRows)) * 28 }
    static let maxTextRows = 3

    /// The lane row of each text: texts that overlap in time stack, each in
    /// the first row free when it starts (at most `maxTextRows`).
    static func textRows(_ texts: [TextOverlay]) -> [UUID: Int] {
        var ends: [Double] = []
        var out: [UUID: Int] = [:]
        for o in texts.sorted(by: { $0.at < $1.at }) {
            let row = ends.firstIndex { $0 <= o.at + 1e-6 } ?? (ends.count < maxTextRows ? ends.count : maxTextRows - 1)
            if row < ends.count { ends[row] = max(ends[row], o.end) } else { ends.append(o.end) }
            out[o.id] = row
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - inset * 2)
            let d = max(model.duration, 0.01)
            let pps = w / CGFloat(d)
            let x: (Double) -> CGFloat = { inset + CGFloat($0) * pps }
            let seconds: (CGFloat) -> Double = { Double(($0 - inset) / pps) }
            let starts = ClipEdits.starts(model.clips)

            ZStack(alignment: .topLeading) {
                ruler(w: w, d: d, x: x)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { v in model.seek(to: seconds(v.location.x)) })

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.panel)
                    .frame(width: w, height: stripH)
                    .offset(x: inset, y: stripY)

                ForEach(Array(model.clips.enumerated()), id: \.offset) { i, c in
                    let lifted = model.moving?.index == i
                    ClipBlock(model: model, index: i, clip: c, width: max(6, CGFloat(c.outputDuration) * pps), height: stripH,
                              pxPerSecond: pps, showTake: model.project.takes.count > 1,
                              seek: { localX in model.seek(to: starts[i] + Double(localX / pps)) })
                        .offset(x: x(starts[i]) + (lifted ? CGFloat(model.moving?.offset ?? 0) * pps : 0), y: stripY)
                        .zIndex(lifted ? 2 : 1)
                }

                // The zoom track: empty space deselects, a double-click adds.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.panel)
                    .frame(width: w, height: trackH)
                    .overlay(alignment: .leading) {
                        if model.doc.segments.isEmpty {
                            Text("Double-click to add a zoom, or press Z")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(Palette.faint)
                                .padding(.leading, 12)
                        }
                    }
                    .offset(x: inset, y: trackY)
                    .onTapGesture(count: 2, coordinateSpace: .named("timeline")) { p in
                        model.addZoom(at: seconds(p.x))
                    }
                    .onTapGesture { model.select(nil) }

                ForEach(model.zoomPlacements) { z in
                    ZoomPill(model: model, seg: z.segment, width: max(8, CGFloat(z.end - z.start) * pps), pxPerSecond: pps)
                        .offset(x: x(z.start), y: trackY)
                        .zIndex(3)
                }

                // You on camera, recorded over the video.
                ForEach(model.doc.cameraClips) { c in
                    CameraPill(model: model, clip: c, width: max(8, CGFloat(min(c.end, d) - c.at) * pps), height: Self.cameraH)
                        .offset(x: x(c.at), y: trackY + trackH + 6)
                        .zIndex(3)
                }

                // Words over the video, on their own lane (under the camera's).
                let textY = trackY + trackH + 6 + (model.doc.cameraClips.isEmpty ? 0 : Self.cameraH + 6)
                let rows = Self.textRows(model.doc.overlays)
                ForEach(model.doc.overlays) { o in
                    TextPill(model: model, text: o, width: max(10, CGFloat(min(o.end, d) - o.at) * pps), height: Self.textH, pxPerSecond: pps)
                        .offset(x: x(o.at), y: textY + CGFloat(rows[o.id] ?? 0) * (Self.textH + 6))
                        .zIndex(3)
                }

                playhead(at: x(model.time), height: geo.size.height)
                    .zIndex(4)
            }
            .coordinateSpace(.named("timeline"))
        }
        .padding(.vertical, 10)
        .background(Palette.charcoal)
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter { $0.pathExtension == "reel" || UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
            guard !videos.isEmpty else { return false }
            Task { await model.addFootage(videos) }
            return true
        }
    }

    private func ruler(w: CGFloat, d: Double, x: @escaping (Double) -> CGFloat) -> some View {
        // A tick every second (every 5 or 10 on long videos), labels on the majors.
        let step: Double = d > 120 ? 10 : d > 40 ? 5 : 1
        let major: Double = step * (d > 40 ? 2 : 5)
        let ticks = Array(stride(from: 0.0, through: d, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                let isMajor = t.truncatingRemainder(dividingBy: major) < 0.001
                Rectangle()
                    .fill(Palette.faint.opacity(isMajor ? 1 : 0.5))
                    .frame(width: 1, height: isMajor ? 8 : 4)
                    .offset(x: x(t), y: rulerH - (isMajor ? 8 : 4))
                if isMajor {
                    Text(TransportBar.stamp(t).replacingOccurrences(of: ".0", with: ""))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.faint)
                        .fixedSize()
                        .offset(x: x(t) + 4, y: 1)
                }
            }
        }
        .frame(width: w + inset * 2, height: rulerH, alignment: .topLeading)
    }

    private func playhead(at x: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Palette.violet).frame(width: 1.5, height: height - 12)
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Palette.violet)
                .frame(width: 9, height: 12)
        }
        .offset(x: x - 4.5, y: 0)
        .allowsHitTesting(false)
    }
}

/// One clip: a filmstrip of its stretch of footage in a frame, handles at
/// both ends, a small take badge when there are several takes. Click to
/// select and jump there; drag the body to move it; drag a handle to trim.
struct ClipBlock: View {
    let model: EditorModel
    let index: Int
    let clip: Clip
    let width: CGFloat
    let height: CGFloat
    let pxPerSecond: CGFloat
    let showTake: Bool
    let seek: (CGFloat) -> Void

    private var selected: Bool { model.selectedClip == index }
    private var lifted: Bool { model.moving?.index == index }

    var body: some View {
        film
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if showTake && width > 54 {
                    Text("Take \(clip.take + 1)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(Capsule().fill(Palette.charcoal.opacity(0.78)))
                        .foregroundStyle(Palette.moonWhite)
                        .padding(.leading, 14)
                        .padding(.top, 5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if clip.rate != 1 && width > 40 {
                    Text(ClipBlock.speedLabel(clip.rate))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(Capsule().fill(Palette.violet.opacity(0.92)))
                        .foregroundStyle(Palette.charcoal)
                        .padding(.trailing, 14)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .overlay { fades.allowsHitTesting(false) }
            .overlay(
                // A light frame inside a dark hairline: legible on light and dark footage alike.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Palette.violet : Palette.moonWhite, lineWidth: selected ? 2.5 : 2)
                    .padding(1)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.charcoal.opacity(0.9), lineWidth: 1))
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                model.selectClip(index)
                seek(p.x)
            }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        if model.moving == nil { model.beginMove(index) }
                        model.move(by: Double(v.translation.width / pxPerSecond))
                    }
                    .onEnded { _ in model.endMove() }
            )
            .overlay(alignment: .leading) { handle(leading: true) }
            .overlay(alignment: .trailing) { handle(leading: false) }
            .scaleEffect(lifted && !Motion.reduceMotion ? 1.03 : 1)
            .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: 10, y: 4)
            .opacity(lifted ? 0.92 : 1)
            .animation(Motion.snappy(), value: selected)
            .animation(Motion.snappy(), value: lifted)
            .padding(.horizontal, 1)
    }

    /// "2×", "0.5×".
    static func speedLabel(_ rate: Double) -> String {
        (rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)) + "×"
    }

    /// The fades as soft wedges at the clip's ends.
    private var fades: some View {
        let d = max(clip.outputDuration, 0.01)
        let a = CGFloat(min(clip.fadeIn, d / 2)) * pxPerSecond, b = CGFloat(min(clip.fadeOut, d / 2)) * pxPerSecond
        return HStack(spacing: 0) {
            LinearGradient(colors: [Palette.charcoal.opacity(0.75), .clear], startPoint: .leading, endPoint: .trailing).frame(width: a)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, Palette.charcoal.opacity(0.75)], startPoint: .leading, endPoint: .trailing).frame(width: b)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Frames from this clip's own stretch of its take, one tile per ~86 pt.
    private var film: some View {
        let tileW = height * 1.6
        let n = max(1, Int((width / tileW).rounded(.up)))
        return HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let t = clip.start + (Double(k) + 0.5) / Double(n) * clip.duration
                Group {
                    if let img = model.thumbnail(take: clip.take, time: t) {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Palette.midnight
                    }
                }
                .frame(width: width / CGFloat(n), height: height)
                .clipped()
            }
        }
        .background(Palette.midnight)
    }

    private func handle(leading: Bool) -> some View {
        let color = selected ? Palette.violet : Palette.midnight
        return UnevenRoundedRectangle(
            topLeadingRadius: leading ? 8 : 0, bottomLeadingRadius: leading ? 8 : 0,
            bottomTrailingRadius: leading ? 0 : 8, topTrailingRadius: leading ? 0 : 8, style: .continuous)
            .fill(color)
            .frame(width: 10, height: height)
            .overlay(Capsule().fill(selected ? Palette.charcoal.opacity(0.7) : Palette.moonWhite.opacity(0.85)).frame(width: 2, height: 16))
            .frame(width: 16, height: height, alignment: leading ? .leading : .trailing)
            .contentShape(Rectangle())
            .opacity(width > 22 ? 1 : 0.6)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        if !model.isDraggingClip(index, leading: leading) { model.beginClipDrag(index, leading: leading) }
                        model.dragClip(by: Double(v.translation.width / pxPerSecond))
                    }
                    .onEnded { _ in model.endClipDrag() }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help(leading ? "Drag to change where this clip starts" : "Drag to change where this clip ends")
    }
}

/// One zoom on the track. Body drags move it; the ends resize it.
struct ZoomPill: View {
    let model: EditorModel
    let seg: ZoomSegment
    let width: CGFloat
    let pxPerSecond: CGFloat
    private let height: CGFloat = 32

    private var selected: Bool { model.selectedID == seg.id }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.violet.opacity(0.28) : Palette.midnight)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Palette.violet : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            if width > 54 {
                HStack(spacing: 4) {
                    Image(systemName: seg.followsCursor ? "cursorarrow.motionlines" : "scope")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(String(format: "%.1f×", seg.scale))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(selected ? Palette.moonWhite : Palette.dim)
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture { model.select(seg.id) }
        .gesture(drag(edge: nil))
        .overlay(alignment: .leading) { handle(.leading) }
        .overlay(alignment: .trailing) { handle(.trailing) }
        .animation(Motion.snappy(), value: selected)
    }

    private func handle(_ edge: TimelineEdge) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: min(9, width / 3), height: height)
            .overlay(
                Capsule().fill(selected ? Palette.violet : Palette.faint)
                    .frame(width: 2, height: 12)
                    .opacity(width > 30 ? 1 : 0)
            )
            .contentShape(Rectangle())
            .gesture(drag(edge: edge))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func drag(edge: TimelineEdge?) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if !model.isDragging(seg.id) { model.beginDrag(seg.id) }
                model.drag(seg.id, edge: edge, by: Double(v.translation.width / pxPerSecond))
            }
            .onEnded { _ in model.endDrag() }
    }
}

/// A text on its lane: click to edit it, drag to move it, drag an end to
/// change when it comes in or goes.
private struct TextPill: View {
    let model: EditorModel
    let text: TextOverlay
    let width: CGFloat
    let height: CGFloat
    let pxPerSecond: CGFloat

    private var selected: Bool { model.selectedTextID == text.id }

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Palette.clay.opacity(0.4) : Palette.clay.opacity(0.2))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.clay.opacity(selected ? 1 : 0.55), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .leading) {
                Label(text.text.split(separator: "\n").first.map(String.init) ?? "Text", systemImage: "textformat")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.moonWhite.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .opacity(width > 44 ? 1 : 0)
            }
            .frame(width: width, height: height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { model.selectText(text.id); model.seek(to: text.at + 0.05) }
            .gesture(drag(edge: nil))
            .overlay(alignment: .leading) { handle(.leading) }
            .overlay(alignment: .trailing) { handle(.trailing) }
            .contextMenu { Button("Delete", role: .destructive) { model.deleteText(text.id) } }
            .animation(Motion.snappy(), value: selected)
            .help("Text: click to edit, drag to move")
    }

    private func handle(_ edge: TimelineEdge) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: min(9, width / 3), height: height)
            .contentShape(Rectangle())
            .gesture(drag(edge: edge))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }

    private func drag(edge: TimelineEdge?) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
            .onChanged { v in
                if model.textOrigin?.id != text.id { model.beginTextDrag(text.id) }
                model.dragText(text.id, edge: edge, by: Double(v.translation.width / pxPerSecond))
            }
            .onEnded { _ in model.endTextDrag() }
    }
}

/// A camera clip on its lane: click to go there, right-click for bubble,
/// full frame or delete.
private struct CameraPill: View {
    let model: EditorModel
    let clip: CameraClip
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Palette.violet.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.violet.opacity(0.5), lineWidth: 1))
            .overlay(alignment: .leading) {
                Label(clip.full ? "You, full frame" : "You", systemImage: clip.full ? "rectangle.inset.filled" : "person.crop.circle")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.moonWhite.opacity(0.85))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .opacity(width > 44 ? 1 : 0)
            }
            .frame(width: width, height: height)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { model.seek(to: clip.at + 0.05) }
            .contextMenu {
                Button(clip.full ? "Show in the bubble" : "Fill the frame") { model.setCameraClip(clip.id) { $0.full.toggle() } }
                Button("Delete", role: .destructive) { model.deleteCameraClip(clip.id) }
            }
            .help("You on camera: right-click for bubble or full frame")
    }
}
