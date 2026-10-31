import MonetShotKit
import SwiftUI

/// Over the preview while framing: the take shown whole, the crop as a
/// bright window in a dimmed frame, and a box over each hidden part.
/// With the blur tool, drag anywhere to draw a new box; drag a box to move
/// it, its handles to resize it. With the crop tool, drag the crop's edges.
struct FrameOverlay: View {
    let model: EditorModel
    /// Size of the shown preview (the overlay's own size).
    let shown: CGSize

    var body: some View {
        let f = model.takeRect(in: shown)
        let take = model.framingTake
        let crop = model.doc.crop(take: take)
        let blurs = model.doc.blurs.filter { $0.take == take }
        let cropping = model.frameTool == .crop
        ZStack(alignment: .topLeading) {
            // Empty space: draw a new box (blur tool), or let go of the selection.
            Color.clear
                .contentShape(Rectangle())
                .gesture(drawGesture(in: f), including: cropping ? .none : .all)
                .onTapGesture { model.selectBlur(nil) }

            // Everything cropped away, dimmed: four bands around the crop.
            let c = Self.view(crop, in: f)
            ForEach(Array(Self.bands(around: c, in: f).enumerated()), id: \.offset) { _, band in
                Rectangle()
                    .fill(Color.black.opacity(cropping ? 0.62 : 0.5))
                    .frame(width: band.width, height: band.height)
                    .offset(x: band.minX, y: band.minY)
                    .allowsHitTesting(false)
            }

            ForEach(blurs) { b in
                EditableBox(model: model, rect: b.rect, frame: f, kind: .blur, selected: b.id == model.selectedBlurID,
                            label: b.style.label + (b.always ? "" : " · timed"),
                            onSelect: { model.selectBlur(b.id) },
                            onChange: { r in model.setBlur(b.id) { $0.rect = r } })
                    .allowsHitTesting(!cropping)
                    .opacity(cropping ? 0.45 : 1)
            }

            if cropping {
                EditableBox(model: model, rect: crop, frame: f, kind: .crop, selected: true, label: nil,
                            onSelect: {}, onChange: { r in model.setCrop(r) })
            }

            if let r = model.drawingBox {
                Rectangle()
                    .fill(Palette.violet.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(Palette.violet, lineWidth: 1.5))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
        .coordinateSpace(name: FrameOverlay.space)
    }

    static let space = "monetshot.frame"

    /// The parts of `f` outside `c`: above, below, left and right of it.
    static func bands(around c: CGRect, in f: CGRect) -> [CGRect] {
        [CGRect(x: f.minX, y: f.minY, width: f.width, height: c.minY - f.minY),
         CGRect(x: f.minX, y: c.maxY, width: f.width, height: f.maxY - c.maxY),
         CGRect(x: f.minX, y: c.minY, width: c.minX - f.minX, height: c.height),
         CGRect(x: c.maxX, y: c.minY, width: f.maxX - c.maxX, height: c.height)]
            .filter { $0.width > 0.5 && $0.height > 0.5 }
    }

    static func view(_ r: NormRect, in f: CGRect) -> CGRect {
        CGRect(x: f.minX + r.x * f.width, y: f.minY + r.y * f.height, width: r.w * f.width, height: r.h * f.height)
    }

    private func drawGesture(in f: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { v in
                let a = v.startLocation, b = v.location
                model.drawingBox = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { v in
                model.drawingBox = nil
                func norm(_ p: CGPoint) -> (x: Double, y: Double) {
                    (min(max((p.x - f.minX) / f.width, 0), 1), min(max((p.y - f.minY) / f.height, 0), 1))
                }
                let r = NormRect.spanning(norm(v.startLocation), norm(v.location))
                guard r.w * f.width > 6, r.h * f.height > 6 else { return }
                model.addBlur(r)
            }
    }
}

/// A rectangle on the preview that moves by its body and resizes by eight
/// handles. Drags are measured from where they began, so they never drift.
private struct EditableBox: View {
    enum Kind { case blur, crop }

    let model: EditorModel
    let rect: NormRect
    let frame: CGRect
    let kind: Kind
    let selected: Bool
    let label: String?
    let onSelect: () -> Void
    let onChange: (NormRect) -> Void

    private static let handles: [(Double, Double)] = [
        (0, 0), (0.5, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1), (0.5, 1), (1, 1),
    ]

    var body: some View {
        let r = FrameOverlay.view(rect, in: frame)
        let line = kind == .crop ? Color.white : (selected ? Palette.violet : Color.white.opacity(0.85))
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(kind == .blur && !selected ? 0.04 : 0.001))
                .overlay(
                    Rectangle().strokeBorder(line, style: StrokeStyle(lineWidth: selected ? 1.5 : 1,
                                                                     dash: kind == .blur && !selected ? [5, 4] : []))
                )
                .overlay { if kind == .crop { thirds } }
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(moveGesture)
                .onTapGesture(perform: onSelect)

            if let label, selected || kind == .blur {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(selected ? Palette.charcoal : Palette.moonWhite)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selected ? Palette.violet : Palette.charcoal.opacity(0.8)))
                    .fixedSize()
                    .offset(x: r.minX, y: max(frame.minY, r.minY - 21))
                    .allowsHitTesting(false)
            }

            if selected {
                ForEach(Self.handles.indices, id: \.self) { i in
                    let (hx, hy) = Self.handles[i]
                    handle(corner: hx != 0.5 && hy != 0.5)
                        .position(x: r.minX + hx * r.width, y: r.minY + hy * r.height)
                        .gesture(resizeGesture(hx, hy))
                }
            }
        }
    }

    /// Rule-of-thirds lines inside the crop, faint.
    private var thirds: some View {
        GeometryReader { g in
            Path { p in
                for k in [1.0 / 3, 2.0 / 3] {
                    p.move(to: CGPoint(x: g.size.width * k, y: 0)); p.addLine(to: CGPoint(x: g.size.width * k, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: g.size.height * k)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * k))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func handle(corner: Bool) -> some View {
        let size: CGFloat = corner ? 11 : 9
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Palette.charcoal.opacity(0.5), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(6)                       // a bigger target than it looks
            .contentShape(Rectangle())
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(FrameOverlay.space))
            .onChanged { v in
                if model.boxOrigin == nil { model.boxOrigin = rect; onSelect() }
                guard let o = model.boxOrigin else { return }
                onChange(o.moved(dx: v.translation.width / frame.width, dy: v.translation.height / frame.height))
            }
            .onEnded { _ in model.boxOrigin = nil }
    }

    private func resizeGesture(_ hx: Double, _ hy: Double) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(FrameOverlay.space))
            .onChanged { v in
                if model.boxOrigin == nil { model.boxOrigin = rect }
                guard let o = model.boxOrigin else { return }
                onChange(o.resized(handleX: hx, handleY: hy, dx: v.translation.width / frame.width,
                                   dy: v.translation.height / frame.height, minSize: kind == .crop ? 0.1 : 0.02))
            }
            .onEnded { _ in model.boxOrigin = nil }
    }
}

/// Replaces the transport while framing.
struct FrameBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button("Done", action: model.closeFraming)
                .buttonStyle(PillButtonStyle(prominent: true))
                .help("Back to the finished look (Esc)")

            Button(action: model.togglePlay) {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PillButtonStyle())
            .help("Play / Pause (Space)")

            Text("\(TransportBar.stamp(model.time)) / \(TransportBar.stamp(model.duration))")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.dim)

            Picker("", selection: Binding(get: { model.frameTool }, set: { model.frameTool = $0 })) {
                Label("Hide", systemImage: "eye.slash").tag(EditorModel.FrameTool.blur)
                Label("Crop", systemImage: "crop").tag(EditorModel.FrameTool.crop)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text(model.frameTool == .crop
                 ? "Drag the edges to keep only part of the screen."
                 : "Drag over anything you don't want seen.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)

            if model.frameTool == .crop {
                Button("Reset", action: model.resetCrop)
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.doc.crop(take: model.framingTake).isFull)
                    .help("Show the whole recording again")
            } else if let b = model.selectedBlur {
                Button(role: .destructive) { model.deleteBlur(b.id) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(PillButtonStyle())
                .help("Stop hiding this (Delete)")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
