// Golden fixtures: the Swift MonetShotKit's answers to fixed questions, for
// the desktop core's tests (`desktop/crates/core/tests/fixtures.rs`) to match.
// Compiled together with `Sources/MonetShotKit/**/*.swift` by
// `shared/tools/fixtures.sh` (no Package.swift change), so internals are
// reachable. Writes `shared/fixtures/*.json` and `shared/fixtures/render/`.
//
// Everything here is deterministic (a fixed LCG, no UUIDs in the outputs), so
// regenerating without a Swift change gives the same files, except the
// rendered frames' grain (CIRandomGenerator), which tests compare loosely.

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

setenv("MONETSHOT_HOME", FileManager.default.temporaryDirectory.appendingPathComponent("monetshot-fixtures-\(getpid())").path, 1)

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let out = root.appendingPathComponent("shared/fixtures")
let renderOut = out.appendingPathComponent("render")
try FileManager.default.createDirectory(at: renderOut, withIntermediateDirectories: true)

// MARK: - JSON values

indirect enum J: Encodable {
    case n(Double), i(Int), s(String), b(Bool), a([J]), o([String: J]), null
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .n(let v): try c.encode(v)
        case .i(let v): try c.encode(v)
        case .s(let v): try c.encode(v)
        case .b(let v): try c.encode(v)
        case .a(let v): try c.encode(v)
        case .o(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

func write(_ name: String, _ value: J) {
    let data = try! JSONEncoder.app.encode(value)
    try! data.write(to: out.appendingPathComponent(name))
    print("wrote shared/fixtures/\(name) (\(data.count / 1024) KB)")
}

func jsonString<T: Encodable>(_ v: T) -> J { .s(String(data: try! JSONEncoder.app.encode(v), encoding: .utf8)!) }
func n(_ v: Double) -> J { .n(v) }
func n(_ v: CGFloat) -> J { .n(Double(v)) }
func sample(_ s: CursorSample) -> J { .o(["t": n(s.t), "x": n(s.x), "y": n(s.y)]) }
func samples(_ s: [CursorSample]) -> J { .a(s.map(sample)) }
func clip(_ c: Clip) -> J {
    var o: [String: J] = ["start": n(c.start), "end": n(c.end), "take": .i(c.take)]
    // Only when set, as edit.json writes them, so older fixtures are unchanged.
    if c.speed != 1 { o["speed"] = n(c.speed) }
    if c.fadeIn != 0 { o["fadeIn"] = n(c.fadeIn) }
    if c.fadeOut != 0 { o["fadeOut"] = n(c.fadeOut) }
    return .o(o)
}
func clips(_ c: [Clip]) -> J { .a(c.map(clip)) }
func seg(_ s: ZoomSegment) -> J {
    .o(["start": n(s.start), "end": n(s.end), "scale": n(s.scale), "auto": .b(s.auto), "take": .i(s.take),
        "focusX": s.focusX.map(J.n) ?? .null, "focusY": s.focusY.map(J.n) ?? .null])
}
func segs(_ s: [ZoomSegment]) -> J { .a(s.map(seg)) }
func rect(_ r: NormRect) -> J { .o(["x": n(r.x), "y": n(r.y), "w": n(r.w), "h": n(r.h)]) }
/// A CoreImage rect (origin bottom-left) as top-left canvas pixels.
func tl(_ r: CGRect, _ height: CGFloat) -> J { .o(["x": n(r.minX), "y": n(height - r.maxY), "w": n(r.width), "h": n(r.height)]) }
func cam(_ c: Camera) -> J { .o(["scale": n(c.scale), "centerX": n(c.centerX), "centerY": n(c.centerY)]) }

// MARK: - Deterministic inputs

struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    mutating func int(_ a: Int, _ b: Int) -> Int { a + Int(next() * Double(b - a + 1)) }
}

/// A pointer that glides between targets, logged at 60 Hz, clicking on arrival.
func pointer(_ rng: inout LCG, duration: Double, rate: Double = 60) -> CursorTrack {
    var s: [CursorSample] = [], c: [CursorSample] = []
    var from = (rng.range(0.1, 0.9), rng.range(0.1, 0.9)), to = from
    var leg = (start: 0.0, end: 0.0)
    var t = 0.0
    while t <= duration {
        if t >= leg.end {
            if leg.end > 0, rng.next() < 0.6 { c.append(CursorSample(t: t, x: to.0, y: to.1)) }
            from = to
            to = (rng.range(0.02, 0.98), rng.range(0.02, 0.98))
            leg = (t + rng.range(0, 0.4), t + rng.range(0.5, 1.6))
        }
        let u = max(0, min(1, (t - leg.start) / (leg.end - leg.start)))
        let e = u * u * (3 - 2 * u)
        s.append(CursorSample(t: t, x: from.0 + (to.0 - from.0) * e, y: from.1 + (to.1 - from.1) * e))
        t += 1 / rate
    }
    return CursorTrack(samples: s, clicks: c)
}

func randomClips(_ rng: inout LCG, takes: [Double]) -> [Clip] {
    (0..<rng.int(1, 6)).map { _ in
        let take = rng.int(0, takes.count - 1)
        let a = rng.range(0, takes[take] - 0.3)
        return Clip(start: a, end: min(takes[take], a + rng.range(0.05, 3)), take: take)
    }
}

var rng = LCG(state: 0x5EED)

// MARK: - TimeMap, kept clips, clip edits

do {
    var cases: [J] = []
    var lists: [[Clip]] = [[Clip(start: 1, end: 3, take: 0), Clip(start: 5, end: 9, take: 1), Clip(start: 0, end: 1, take: 0)], [],
                           [Clip(start: 0, end: 0.0005), Clip(start: 2, end: 4)]]
    for _ in 0..<12 { lists.append(randomClips(&rng, takes: [10, 6])) }
    for list in lists {
        let m = TimeMap(clips: list)
        var q: [J] = []
        var t = -0.5
        while t < m.duration + 0.6 {
            let l = m.locate(t)
            q.append(.o(["t": n(t), "index": .i(l.index), "take": .i(l.take), "time": n(l.time)]))
            t += 0.37
        }
        var o: [J] = []
        for take in 0..<2 {
            for k in stride(from: -0.5, through: 10.5, by: 0.61) {
                o.append(.o(["take": .i(take), "time": n(k), "output": m.output(take: take, time: k).map(J.n) ?? .null,
                             "keeps": .b(m.keeps(take: take, time: k))]))
            }
        }
        cases.append(.o(["clips": clips(list), "duration": n(m.duration),
                         "spans": .a(m.spans.map { .o(["take": .i($0.take), "start": n($0.start), "end": n($0.end), "at": n($0.at)]) }),
                         "locate": .a(q), "output": .a(o)]))
    }
    write("timemap.json", .o(["cases": .a(cases)]))
}

do {
    var cases: [J] = []
    func add(_ doc: EditDoc, _ duration: Double) {
        cases.append(.o(["edit": jsonString(doc), "duration": n(duration), "clips": clips(doc.keptClips(duration: duration))]))
    }
    var d = EditDoc(); d.cuts = [Cut(start: 3, end: 5)]; d.trimStart = 1; d.trimEnd = 9
    add(d, 10)
    add(EditDoc(), 7.5)
    for _ in 0..<20 {
        var doc = EditDoc()
        let dur = rng.range(1, 30)
        doc.trimStart = rng.next() < 0.3 ? rng.range(-1, dur) : 0
        doc.trimEnd = rng.next() < 0.5 ? rng.range(0, dur + 2) : nil
        doc.cuts = (0..<rng.int(0, 5)).map { _ in let a = rng.range(-1, dur); return Cut(start: a, end: a + rng.range(0, 4)) }
        if rng.next() < 0.15 { doc.clips = randomClips(&rng, takes: [dur]) }
        add(doc, dur)
    }
    write("kept_clips.json", .o(["cases": .a(cases)]))
}

do {
    var cases: [J] = []
    for w in [2560, 1920, 1921, 1280, 3840, 1, 0, 641] {
        for a in [16.0 / 9.0, 0, 1, 9.0 / 16.0, 4.0 / 3.0, 21.0 / 9.0] {
            for ra in [16.0 / 10.0, 3456.0 / 2234.0, 16.0 / 9.0, 0.5] {
                var doc = EditDoc(); doc.outputWidth = w; doc.canvasAspect = a
                let s = doc.canvasSize(recordingAspect: ra)
                cases.append(.o(["outputWidth": .i(w), "canvasAspect": n(a), "recordingAspect": n(ra), "width": .i(s.width), "height": .i(s.height)]))
            }
        }
    }
    write("canvas.json", .o(["cases": .a(cases)]))
}

do {
    var cases: [J] = []
    let three = [Clip(start: 0, end: 2), Clip(start: 0, end: 2, take: 1), Clip(start: 5, end: 6)]
    var lists: [[Clip]] = [[Clip(start: 0, end: 10)], [Clip(start: 0, end: 4), Clip(start: 4, end: 10)], three]
    for _ in 0..<10 { lists.append(randomClips(&rng, takes: [10, 6])) }
    for list in lists {
        let total = ClipEdits.starts(list).last.map { $0 + list.last!.duration } ?? 0
        var splits: [J] = [], resizes: [J] = [], moves: [J] = [], drops: [J] = [], deletes: [J] = []
        for k in 0..<9 {
            let t = total * Double(k) / 8 + (k % 2 == 0 ? 0.05 : 0)
            splits.append(.o(["t": n(t), "result": ClipEdits.split(list, atOutput: t).map(clips) ?? .null]))
        }
        for i in -1...list.count {
            deletes.append(.o(["i": .i(i), "result": clips(ClipEdits.delete(list, at: i))]))
            for leading in [true, false] {
                for to in [-1.0, 0.5, 3.3, 5.95, 12] {
                    resizes.append(.o(["i": .i(i), "leading": .b(leading), "to": n(to), "takeDuration": n(6 as Double),
                                       "result": clips(ClipEdits.resize(list, at: i, leading: leading, to: to, takeDuration: 6))]))
                }
            }
            for to in [-2, 0, 1, list.count, list.count + 3] {
                moves.append(.o(["from": .i(i), "to": .i(to), "result": clips(ClipEdits.move(list, from: i, to: to))]))
            }
            for c in [-1.0, 0.4, total / 2, total + 1] {
                drops.append(.o(["dragging": .i(i), "centreAt": n(c), "result": .i(ClipEdits.dropIndex(list, dragging: i, centreAt: c))]))
            }
        }
        cases.append(.o(["clips": clips(list), "starts": .a(ClipEdits.starts(list).map(J.n)), "split": .a(splits),
                         "delete": .a(deletes), "resize": .a(resizes), "move": .a(moves), "dropIndex": .a(drops)]))
    }
    write("clip_edits.json", .o(["cases": .a(cases)]))
}

// MARK: - Smoothing, camera, auto-zoom, segment edits, ripples

do {
    var cases: [J] = []
    let held = [CursorSample(t: 0, x: 0.1, y: 0.1), CursorSample(t: 1, x: 0.1, y: 0.1),
                CursorSample(t: 2, x: 0.9, y: 0.5), CursorSample(t: 4, x: 0.9, y: 0.5)]
    var inputs: [([CursorSample], Double)] = [(held, 4), ([], 2), ([CursorSample(t: 0.5, x: 0.3, y: 0.7)], 1.5)]
    for _ in 0..<3 { let d = rng.range(2, 5); inputs.append((pointer(&rng, duration: d).samples, d)) }
    for (s, d) in inputs {
        for omega in [CameraMath.cursorOmega(smoothing: 0), CameraMath.cursorOmega(smoothing: 0.6), CameraMath.cursorOmega(smoothing: 1),
                      CameraMath.cameraOmega, 200] {
            let tr = SmoothTrack.make(from: s, duration: d, omega: omega)
            var pos: [J] = []
            for t in stride(from: -0.3, through: d + 0.5, by: 0.173) {
                let p = tr.position(at: t)
                pos.append(.o(["t": n(t), "x": n(p.x), "y": n(p.y)]))
            }
            cases.append(.o(["samples": samples(s), "duration": n(d), "omega": n(omega),
                             "xs": .a(tr.xs.map(J.n)), "ys": .a(tr.ys.map(J.n)), "positions": .a(pos)]))
        }
    }
    var omegas: [J] = []
    for s in stride(from: -0.5, through: 1.5, by: 0.1) { omegas.append(.o(["smoothing": n(s), "omega": n(CameraMath.cursorOmega(smoothing: s))])) }
    write("smooth.json", .o(["cases": .a(cases), "cursorOmega": .a(omegas)]))
}

do {
    var cases: [J] = []
    for k in 0..<8 {
        let d = rng.range(4, 12)
        let track = pointer(&rng, duration: d)
        var ss: [ZoomSegment] = CameraMath.autoZooms(clicks: track.clicks, duration: d)
        ss.append(ZoomSegment(start: rng.range(0, d / 2), end: rng.range(d / 2, d), scale: rng.range(0.5, 3.5),
                              focusX: k % 2 == 0 ? rng.next() : nil, focusY: k % 2 == 0 ? rng.next() : nil))
        if k == 3 { ss.append(ZoomSegment(start: 1, end: 1.3, scale: 2)) }
        let focus = SmoothTrack.make(from: track.samples, duration: d, omega: CameraMath.cameraOmega)
        var q: [J] = []
        for t in stride(from: -0.2, through: d + 0.3, by: 0.0917) {
            q.append(.o(["t": n(t), "camera": cam(CameraMath.camera(at: t, segments: ss, focus: focus)),
                         "weights": .a(ss.map { n(CameraMath.weight($0, at: t)) })]))
        }
        cases.append(.o(["samples": samples(track.samples), "duration": n(d), "segments": segs(ss), "queries": .a(q)]))
    }
    var eases: [J] = []
    for u in stride(from: -0.2, through: 1.2, by: 0.05) { eases.append(.o(["u": n(u), "ease": n(CameraMath.ease(u))])) }
    var vp: [J] = []
    for c in [Camera.identity, Camera(scale: 2, centerX: 0.25, centerY: 0.75), Camera(scale: 1.37, centerX: 0.6, centerY: 0.41)] {
        let v = c.viewport, p = c.project(x: 0.3, y: 0.8)
        vp.append(.o(["camera": cam(c), "viewport": .a([n(v.x), n(v.y), n(v.w), n(v.h)]), "project": .a([n(p.x), n(p.y)])]))
    }
    write("camera.json", .o(["cases": .a(cases), "ease": .a(eases), "viewport": .a(vp)]))
}

do {
    var cases: [J] = []
    var inputs: [([CursorSample], Double)] = [
        ([CursorSample(t: 2, x: 0.3, y: 0.3), CursorSample(t: 3, x: 0.31, y: 0.3), CursorSample(t: 12, x: 0.8, y: 0.7)], 20),
        ([CursorSample(t: 2, x: 0, y: 0), CursorSample(t: 5.8, x: 0, y: 0)], 20), ([], 10),
        ([CursorSample(t: 0.1, x: 0, y: 0), CursorSample(t: -1, x: 0, y: 0), CursorSample(t: 9.9, x: 0, y: 0), CursorSample(t: 11, x: 0, y: 0)], 10),
        ([CursorSample(t: 9.8, x: 0, y: 0)], 10),
    ]
    for _ in 0..<10 {
        let d = rng.range(3, 40)
        inputs.append(((0..<rng.int(0, 14)).map { _ in CursorSample(t: rng.range(-1, d + 1), x: rng.next(), y: rng.next()) }, d))
    }
    for (c, d) in inputs {
        cases.append(.o(["clicks": samples(c), "duration": n(d), "segments": segs(CameraMath.autoZooms(clicks: c, duration: d)),
                         "scale3take2": segs(CameraMath.autoZooms(clicks: c, duration: d, scale: 3, take: 2))]))
    }
    write("auto_zooms.json", .o(["cases": .a(cases)]))
}

do {
    var moves: [J] = [], resizes: [J] = [], inserts: [J] = [], reAutos: [J] = []
    let s = ZoomSegment(start: 2, end: 4, scale: 2, auto: true)
    for delta in [-5.0, -1, 0, 0.7, 10] {
        moves.append(.o(["segment": seg(s), "delta": n(delta), "duration": n(6 as Double), "result": seg(SegmentEdits.move(s, by: delta, duration: 6))]))
    }
    for leading in [true, false] {
        for to in [-1.0, 1, 3.9, 2.1, 5, 7] {
            resizes.append(.o(["segment": seg(s), "leading": .b(leading), "to": n(to), "duration": n(6 as Double),
                               "result": seg(SegmentEdits.resize(s, leading: leading, to: to, duration: 6))]))
        }
    }
    let list = [s, ZoomSegment(start: 7, end: 8, take: 0), ZoomSegment(start: 3, end: 5, take: 1)]
    for at in [0.0, 1, 3, 4.2, 4.5, 5, 6, 6.8, 9, 9.9] {
        for length in [2.5, 1] {
            inserts.append(.o(["at": n(at), "segments": segs(list), "duration": n(10 as Double), "length": n(length), "take": .i(0),
                               "result": SegmentEdits.insert(at: at, into: list, duration: 10, length: length).map(seg) ?? .null]))
        }
        inserts.append(.o(["at": n(at), "segments": segs(list), "duration": n(10 as Double), "length": n(2.5 as Double), "take": .i(1),
                           "result": SegmentEdits.insert(at: at, into: list, duration: 10, take: 1).map(seg) ?? .null]))
    }
    let manual = ZoomSegment(start: 0, end: 3, scale: 3)
    reAutos.append(.o(["segments": segs([manual]), "clicks": samples([CursorSample(t: 1, x: 0.5, y: 0.5), CursorSample(t: 10, x: 0.5, y: 0.5)]),
                       "duration": n(20 as Double), "take": .i(0),
                       "result": segs(SegmentEdits.reAuto([manual], clicks: [CursorSample(t: 1, x: 0.5, y: 0.5), CursorSample(t: 10, x: 0.5, y: 0.5)], duration: 20))]))
    for k in 0..<6 {
        let d = rng.range(8, 30)
        let clicks = (0..<rng.int(1, 10)).map { _ in CursorSample(t: rng.range(0, d), x: rng.next(), y: rng.next()) }
        var segments = CameraMath.autoZooms(clicks: (0..<4).map { _ in CursorSample(t: rng.range(0, d), x: 0, y: 0) }, duration: d, take: k % 2)
        segments.append(ZoomSegment(start: rng.range(0, d / 2), end: rng.range(d / 2, d), scale: 2.5, take: 0))
        segments.append(ZoomSegment(start: rng.range(0, d / 2), end: rng.range(d / 2, d), scale: 1.5, take: 1))
        let take = k % 2
        reAutos.append(.o(["segments": segs(segments), "clicks": samples(clicks), "duration": n(d), "take": .i(take),
                           "result": segs(SegmentEdits.reAuto(segments, clicks: clicks, duration: d, take: take))]))
    }
    write("segment_edits.json", .o(["move": .a(moves), "resize": .a(resizes), "insert": .a(inserts), "reAuto": .a(reAutos)]))
}

do {
    var cases: [J] = []
    let clicks = [CursorSample(t: 1, x: 0.2, y: 0.3), CursorSample(t: 1.3, x: 0.5, y: 0.5), CursorSample(t: 4, x: 0.9, y: 0.1)]
    for t in stride(from: 0.8, through: 4.8, by: 0.0371) {
        cases.append(.o(["t": n(t),
                         "ripples": .a(CameraMath.ripples(clicks: clicks, at: t).map { .o(["click": sample($0.click), "progress": n($0.progress)]) }),
                         "ripples02": .a(CameraMath.ripples(clicks: clicks, at: t, duration: 0.2).map { .o(["click": sample($0.click), "progress": n($0.progress)]) }),
                         "pressScale": n(CameraMath.pressScale(clicks: clicks, at: t))]))
    }
    write("ripples.json", .o(["clicks": samples(clicks), "cases": .a(cases)]))
}

// MARK: - NormRect, camera clips, music envelope

do {
    var cases: [J] = []
    for _ in 0..<40 {
        let r = NormRect(x: rng.range(-0.2, 1), y: rng.range(-0.2, 1), w: rng.range(0, 1.2), h: rng.range(0, 1.2))
        let (dx, dy) = (rng.range(-0.6, 0.6), rng.range(-0.6, 0.6))
        let (hx, hy) = ([0.0, 0.5, 1][rng.int(0, 2)], [0.0, 0.5, 1][rng.int(0, 2)])
        let (px, py) = (rng.next(), rng.next())
        let l = r.local(px, py), g = r.global(px, py)
        let a = (x: rng.next(), y: rng.next()), b = (x: rng.next(), y: rng.next())
        cases.append(.o([
            "rect": rect(r), "isFull": .b(r.isFull), "clamped": rect(r.clamped()), "clamped01": rect(r.clamped(minSize: 0.1)),
            "point": .a([n(px), n(py)]), "local": .a([n(l.x), n(l.y)]), "global": .a([n(g.x), n(g.y)]),
            "dx": n(dx), "dy": n(dy), "moved": rect(r.moved(dx: dx, dy: dy)),
            "hx": n(hx), "hy": n(hy), "resized": rect(r.resized(handleX: hx, handleY: hy, dx: dx, dy: dy)),
            "resized05": rect(r.resized(handleX: hx, handleY: hy, dx: dx, dy: dy, minSize: 0.05)),
            "a": .a([n(a.x), n(a.y)]), "b": .a([n(b.x), n(b.y)]), "spanning": rect(NormRect.spanning(a, b)),
        ]))
    }
    var crops: [J] = []
    for r in [NormRect(x: 0, y: 0, w: 0.5, h: 1), .full, NormRect(x: 0.00001, y: 0, w: 0.99995, h: 1), NormRect(x: 0.9, y: 0.95, w: 0.05, h: 0.01)] {
        var doc = EditDoc()
        doc.setCrop(NormRect(x: 0.1, y: 0.1, w: 0.3, h: 0.3), take: 1)
        doc.setCrop(r, take: 0)
        crops.append(.o(["set": rect(r), "crops": .a(doc.crops.map { .o(["take": .i($0.take), "rect": rect($0.rect)]) }),
                         "crop0": rect(doc.crop(take: 0)), "crop2": rect(doc.crop(take: 2))]))
    }
    write("normrect.json", .o(["cases": .a(cases), "setCrop": .a(crops)]))
}

do {
    func cj(_ c: CameraClip) -> J { .o(["file": .s(c.file), "at": n(c.at), "duration": n(c.duration), "full": .b(c.full)]) }
    var inserts: [J] = []
    let a = CameraClip(file: "a.mov", at: 1, duration: 4), b = CameraClip(file: "b.mov", at: 3, duration: 2)
    var list = [a]
    for c in [b, CameraClip(file: "c.mov", at: 0.5, duration: 9), CameraClip(file: "d.mov", at: 12, duration: 1),
              CameraClip(file: "e.mov", at: 9.4, duration: 1, full: true), CameraClip(file: "f.mov", at: 12.1, duration: 3)] {
        let next = CameraEdits.insert(c, into: list)
        inserts.append(.o(["clips": .a(list.map(cj)), "clip": cj(c), "result": .a(next.map(cj))]))
        list = next
    }
    var presence: [J] = []
    for c in [a, CameraClip(file: "s.mov", at: 2, duration: 0.3), CameraClip(file: "z.mov", at: 2, duration: 0)] {
        for t in stride(from: 0.5, through: 5.5, by: 0.0473) {
            presence.append(.o(["clip": cj(c), "t": n(t), "presence": n(CameraEdits.presence(c, at: t))]))
        }
    }
    var env: [J] = []
    let voices: [[ClosedRange<Double>]] = [[], [4...8], [1...2, 2.5...3, 15...19.5]]
    for (len, fi, fo) in [(20.0, true, true), (2.0, true, false), (20, false, true), (0.0, true, true)] {
        for v in voices {
            for t in stride(from: -0.5, through: len + 0.5, by: max(0.05, len / 97)) {
                env.append(.o(["t": n(t), "length": n(len), "fadeIn": .b(fi), "fadeOut": .b(fo),
                               "voice": .a(v.map { .a([n($0.lowerBound), n($0.upperBound)]) }),
                               "gain": n(MusicEnvelope.gain(at: t, length: len, fadeIn: fi, fadeOut: fo, voice: v))]))
            }
        }
    }
    write("camera_clips.json", .o(["insert": .a(inserts), "presence": .a(presence)]))
    write("music_envelope.json", .o(["cases": .a(env)]))
}

// MARK: - Music catalog and grid

do {
    var ids: [J] = []
    for s in ["holiznacc0_night-driving", "", "a", "own-My Song.mp3", "é😀", "john-bartmann_disco-in-the-sky"] {
        ids.append(.o(["id": .s(s), "stableID": .s(MusicCatalog.stableID(s))]))
    }
    var labels: [J] = []
    for (lic, ver) in [("cc0", "1.0"), ("pdm", nil), ("own", nil), ("by", "4.0"), ("by-sa", nil)] as [(String, String?)] {
        let s = Song(id: "x", title: "T", artist: "A", duration: 1, genres: [], license: lic, licenseVersion: ver, audioURL: "x.m4a")
        labels.append(.o(["license": .s(lic), "licenseVersion": ver.map(J.s) ?? .null, "label": .s(s.licenseLabel), "needsCredit": .b(s.needsCredit)]))
    }
    var searches: [J] = []
    for (q, mood) in [("", nil), ("night", nil), ("warm piano", nil), ("HOLIZNA", nil), ("zzz", nil), ("", "dreamy"), ("", "mellow"),
                      ("groove", "sunny"), ("disco-in", nil)] as [(String, String?)] {
        let m = mood.flatMap { f in MusicMood.all.first { $0.feel == f } }
        let found = (try? await MusicCatalog.search(q, mood: m)) ?? []
        searches.append(.o(["query": .s(q), "mood": mood.map(J.s) ?? .null, "ids": .a(found.map { .s($0.id) })]))
    }

    // A synthetic song, made the same way by the Rust test (see music.rs tests):
    // `bpm`, downbeats from `start`, hard on beat one, `quietBars` quiet bars then
    // louder; a deterministic hat between beats.
    // MusicGrid is in the Mac's music work that isn't committed yet;
    // fixtures.sh defines MONETSHOT_MUSIC_GRID only when its file is there.
    var grids: [J] = []
    #if MONETSHOT_MUSIC_GRID
    for (bpm, start, quiet, seconds) in [(108.0, 0.5, 8, 40.0), (92.0, 0.21, 6, 36.0), (128.0, 1.0, 12, 45.0)] {
        let s = synthSong(bpm: bpm, start: start, quietBars: quiet, seconds: seconds)
        let g = MusicGrid.analyze(samples: s, rate: 11_025)
        grids.append(.o(["bpm": n(bpm), "start": n(start), "quietBars": .i(quiet), "seconds": n(seconds),
                         "grid": gridJ(g)]))
    }
    grids.append(.o(["bpm": n(100 as Double), "start": n(0 as Double), "quietBars": .i(0), "seconds": n(5 as Double),
                     "grid": MusicGrid.analyze(samples: synthSong(bpm: 100, start: 0, quietBars: 0, seconds: 5), rate: 11_025) == nil ? .null : .s("unexpected")]))
    #endif
    write("music.json", .o(["stableID": .a(ids), "licenses": .a(labels), "search": .a(searches), "grid": .a(grids)]))
}

#if MONETSHOT_MUSIC_GRID
func gridJ(_ g: MusicGrid?) -> J {
    guard let g else { return .null }
    let nearest: [J] = [0.0, 1.3, 7.7, 20].map { t in J.a([J.n(t), J.n(g.nearestBarLine(t))]) }
    return .o(["bar": .n(g.bar), "firstDownbeat": .n(g.firstDownbeat), "lifts": .a(g.lifts.map(J.n)), "nearest": .a(nearest)])
}
#endif

func synthSong(bpm: Double, start: Double, quietBars: Int, seconds: Double) -> [Float] {
    let rate = 11_025.0, beat = 60.0 / bpm, count = Int(rate * seconds)
    var s = [Float](repeating: 0, count: count)
    var k = 0, t = start
    var noise: UInt32 = 12345
    while t < seconds {
        let loud: Float = t < start + Double(quietBars) * beat * 4 ? 0.25 : 0.8
        let hit: Float = (k % 4 == 0 ? 1 : 0.45) * loud
        let i0 = Int(t * rate)
        for i in 0..<Int(rate * 0.12) where i0 + i < count {
            s[i0 + i] += hit * Float(sin(Double(i) * 0.35)) * Float(exp(-Double(i) / (rate * 0.03)))
        }
        let h0 = Int((t + beat / 2) * rate)
        for i in 0..<Int(rate * 0.02) where h0 + i < count {
            noise = noise &* 1_103_515_245 &+ 12345
            s[h0 + i] += 0.08 * loud * (Float((noise >> 16) & 0x7FFF) / 16383.5 - 1)
        }
        k += 1; t += beat
    }
    return s
}

// MARK: - JSON: what the Mac reads and writes

do {
    var cases: [J] = []
    func roundTrip<T: Codable>(_ type: T.Type, _ kind: String, _ input: String, note: String = "") {
        let back: J
        if let v = try? JSONDecoder.app.decode(T.self, from: Data(input.utf8)) {
            back = .s(String(data: try! JSONEncoder.app.encode(v), encoding: .utf8)!)
        } else {
            back = .null
        }
        cases.append(.o(["type": .s(kind), "input": .s(input), "output": back, "note": .s(note)]))
    }
    var full = EditDoc()
    full.segments = [ZoomSegment(id: UUID(uuidString: "E66CDC53-D527-48B9-B32E-9E7FD7751E19")!, start: 1.25, end: 3.5, scale: 2.2,
                                 focusX: 0.3, focusY: 0.71, auto: false, take: 1)]
    full.backdrop = .image; full.backdropImage = "backdrop-monet-water-lilies.jpg"; full.backdropBlur = 0.35
    full.padding = 0.1; full.cornerRadius = 0.03; full.shadow = false; full.cursorVisible = false; full.cursorScale = 2.25
    full.cursorSmoothing = 0.1; full.clickRipple = false; full.cursorStyle = .tag; full.cursorTint = .lilac; full.cursorLabel = "Connor / \"C\""
    full.cameraClips = [CameraClip(id: UUID(uuidString: "0D1B2C3A-0000-4000-8000-000000000001")!, file: "camera-1.mov", at: 2, duration: 3.5, full: true)]
    full.cameraLook.shape = .rounded; full.cameraLook.corner = .topLeft; full.cameraLook.size = 0.31; full.cameraLook.mirror = false
    full.cameraLook.duckMusic = false; full.cameraLook.visible = false
    full.outputWidth = 1920; full.canvasAspect = 1; full.trimStart = 0.5; full.trimEnd = 12.25
    full.cuts = [Cut(start: 3, end: 4.5)]; full.clips = [Clip(start: 0, end: 2), Clip(start: 1, end: 3, take: 1)]
    full.blurs = [BlurRegion(id: UUID(uuidString: "0D1B2C3A-0000-4000-8000-000000000002")!, take: 0, rect: NormRect(x: 0.1, y: 0.2, w: 0.3, h: 0.05),
                             style: .pixelate, strength: 0.75, start: 1, end: nil)]
    full.crops = [TakeCrop(take: 0, rect: NormRect(x: 0, y: 0.059, w: 1, h: 0.941))]
    let song = Song(id: "holiznacc0_night-driving", title: "Night Driving", artist: "HoliznaCC0", album: "Only in the Milky Way", duration: 131.4,
                    genres: ["dreamy", "grooving"], license: "by", licenseVersion: "4.0",
                    licenseURL: "https://creativecommons.org/licenses/by/4.0/", audioURL: "file:///Applications/Monet%20Shot.app/x.m4a",
                    artworkURL: "https://x/a.jpg", pageURL: "https://freemusicarchive.org/x/", attribution: "Night Driving by HoliznaCC0",
                    bpm: 96, about: "Warm synth pads.", instruments: "synth, piano")
    var choice = MusicChoice(track: song, file: "music-bnw1z9.m4a"); choice.offset = 32.87874794997538; choice.volume = 0.55; choice.fadeOut = false
    full.music = choice
    roundTrip(EditDoc.self, "edit", String(data: try! JSONEncoder.app.encode(full), encoding: .utf8)!, note: "every field set")
    roundTrip(EditDoc.self, "edit", String(data: try! JSONEncoder.app.encode(EditDoc()), encoding: .utf8)!, note: "defaults")
    roundTrip(EditDoc.self, "edit", "{}", note: "empty")
    roundTrip(EditDoc.self, "edit", #"{"padding": 0.1}"#, note: "old file")
    roundTrip(EditDoc.self, "edit", #"{"segments":[{"id":"e66cdc53-d527-48b9-b32e-9e7fd7751e19","start":1,"end":2,"scale":2,"auto":true}]}"#, note: "zoom before takes, lower-case id")
    roundTrip(EditDoc.self, "edit", #"{"segments":[{"start":1,"end":2,"scale":2}]}"#, note: "zoom without id: whole edit unreadable")
    roundTrip(EditDoc.self, "edit", #"{"clips":[{"start":1,"end":2}],"trimEnd":null,"music":null}"#, note: "clip without take, nulls")
    roundTrip(EditDoc.self, "edit", #"{"backdrop":"neon"}"#, note: "unknown backdrop (Mac: unreadable; desktop keeps it)")
    roundTrip(EditDoc.self, "edit", #"{"cameraLook":{"size":0.2}}"#, note: "partial camera look")
    roundTrip(EditDoc.self, "edit", #"{"music":{"file":"m.m4a","track":{"id":"x","title":"T","artist":"A","duration":3,"genres":[],"license":"cc0","audioURL":"x"}}}"#,
              note: "music without offset/volume/fades")
    roundTrip(EditDoc.self, "edit", #"{"blurs":[{"id":"0D1B2C3A-0000-4000-8000-000000000002","take":0,"rect":{"x":0,"y":0,"w":1,"h":1},"style":"solid","strength":1}]}"#,
              note: "always-on cover")
    roundTrip(EditDoc.self, "edit", #"{"outputWidth": 1920.0, "cursorScale": 2}"#, note: "number forms")
    roundTrip(EditDoc.self, "edit", "not json", note: "garbage")
    roundTrip(RecordingMeta.self, "meta", #"{"pixelWidth":3456,"pixelHeight":2234,"pointScale":2,"duration":94.97,"createdAt":"2026-11-02T05:57:48Z","source":"display"}"#,
              note: "before video/camera existed")
    roundTrip(RecordingMeta.self, "meta", #"{"pixelWidth":1920,"pixelHeight":1080,"pointScale":1.25,"duration":1e-05,"createdAt":"2026-11-02T05:57:48Z","source":"import","video":"screen.mp4","camera":"camera.mp4","cameraOffset":0.125}"#,
              note: "with camera")
    roundTrip(RecordingMeta.self, "meta", #"{"pixelWidth":1920,"pixelHeight":1080,"pointScale":1,"duration":3,"createdAt":"2026-11-02T05:57:48.123Z","source":"display"}"#,
              note: "fractional date (Mac refuses)")
    roundTrip(RecordingMeta.self, "meta", #"{"pixelWidth":1920,"pixelHeight":1080,"pointScale":1,"duration":3,"source":"display"}"#, note: "no date")
    roundTrip(CursorTrack.self, "cursor", #"{"samples":[{"t":0,"x":0.5,"y":0.25},{"t":0.008333333333333333,"x":1.0000001,"y":-0.02}],"clicks":[]}"#, note: "")
    roundTrip(CursorTrack.self, "cursor", #"{"samples":[]}"#, note: "no clicks key")
    write("json.json", .o(["cases": .a(cases)]))
}

// MARK: - Frame layout per take (the Renderer's own numbers)

func takePairs(_ specs: [(Int, Int, Double, Double)], _ rng: inout LCG, cursor: Bool = true) -> [(meta: RecordingMeta, cursor: CursorTrack)] {
    specs.enumerated().map { i, s in
        var m = RecordingMeta(pixelWidth: s.0, pixelHeight: s.1, pointScale: s.2, duration: s.3,
                              createdAt: Date(timeIntervalSince1970: 1_793_592_514), source: i == 0 ? "display" : "import",
                              video: i == 0 ? "screen.mov" : "screen.mp4")
        if i == 1 { m.camera = "camera.mp4"; m.cameraOffset = 0.4 }
        return (m, cursor || i == 0 ? pointer(&rng, duration: s.3) : CursorTrack())
    }
}

/// Fixed ids for everything in an edit, so the fixtures don't change run to run.
func fixedIDs(_ doc: EditDoc) -> EditDoc {
    var d = doc
    var k = 0
    func next() -> UUID { k += 1; return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", k))! }
    for i in d.segments.indices { d.segments[i].id = next() }
    for i in d.blurs.indices { d.blurs[i].id = next() }
    for i in d.cameraClips.indices { d.cameraClips[i].id = next() }
    return d
}

func layoutCase(_ name: String, _ doc: EditDoc, _ takes: [(meta: RecordingMeta, cursor: CursorTrack)]) -> J {
    let doc = fixedIDs(doc)
    let r = Renderer(doc: doc, takes: takes, folder: nil)
    let H = r.canvas.height
    var frames: [J] = []
    let d = r.map.duration
    for k in 0...24 {
        let t = d * Double(k) / 24 + (k == 24 ? 0.25 : 0)
        let p = r.map.locate(t)
        let look = r.looks.indices.contains(p.take) ? r.looks[p.take] : r.looks[0]
        let c = r.camera(take: p.take, time: p.time)
        var f: [String: J] = ["t": n(t), "index": .i(p.index), "take": .i(p.take), "time": n(p.time), "camera": cam(c)]
        let fr = look.frameRect
        func place(_ x: Double, _ y: Double) -> J {
            let q = c.project(x: x, y: y)
            return .a([n(fr.minX + CGFloat(q.x) * fr.width), n(H - (fr.maxY - CGFloat(q.y) * fr.height))])
        }
        if doc.cursorVisible && look.hasCursor {
            let pos = look.cursorTrack.position(at: p.time)
            f["cursorTip"] = place(pos.x, pos.y)
            f["cursorHeight"] = n(look.cursorBaseHeight * CGFloat(c.scale) * CGFloat(CameraMath.pressScale(clicks: look.clicks, at: p.time)))
            f["ripples"] = .a(doc.clickRipple ? CameraMath.ripples(clicks: look.clicks, at: p.time).map { rp in
                let grow = 1 - pow(1 - rp.progress, 3)
                return .o(["center": place(rp.click.x, rp.click.y),
                           "radius": n((9 + 24 * grow) * look.pxPerPoint * CGFloat(c.scale) * CGFloat(doc.cursorScale) / 1.5),
                           "alpha": n(0.85 * (1 - rp.progress))])
            } : [])
        }
        frames.append(.o(f))
    }
    return .o([
        "name": .s(name), "edit": jsonString(doc),
        "takes": .a(takes.map { .o(["meta": jsonString($0.meta), "cursor": jsonString($0.cursor)]) }),
        "canvas": .a([n(r.canvas.width), n(r.canvas.height)]), "cursorArtHeight": n(r.cursorArtHeight),
        "bubbleRect": tl(r.bubbleRect, H), "duration": n(d),
        "looks": .a(r.looks.map { l in
            .o(["frame": tl(l.frameRect, H), "pxPerPoint": n(l.pxPerPoint), "cursorBaseHeight": n(l.cursorBaseHeight),
                "crop": rect(l.crop), "hasCursor": .b(l.hasCursor)])
        }),
        "frames": .a(frames),
    ])
}

do {
    var cases: [J] = []
    var lr = LCG(state: 42)
    cases.append(layoutCase("default", EditDoc(), takePairs([(2880, 1800, 2, 6)], &lr)))
    var d = EditDoc(); d.backdrop = .none; d.canvasAspect = 0; d.outputWidth = 1921
    cases.append(layoutCase("none-match", d, takePairs([(3456, 2234, 2, 5)], &lr)))
    d = EditDoc(); d.canvasAspect = 1; d.padding = 0.12; d.cursorScale = 2.4; d.setCrop(NormRect(x: 0.5, y: 0, w: 0.5, h: 1), take: 0)
    d.segments = CameraMath.autoZooms(clicks: [CursorSample(t: 1, x: 0, y: 0), CursorSample(t: 3, x: 0, y: 0)], duration: 5)
    d.segments.append(ZoomSegment(start: 3.5, end: 4.8, scale: 3, focusX: 0.9, focusY: 0.2))
    cases.append(layoutCase("square-crop-zoom", d, takePairs([(1920, 1080, 1, 5)], &lr)))
    d = EditDoc(); d.canvasAspect = 9.0 / 16.0; d.backdrop = .charcoal; d.cameraLook.shape = .rounded; d.cameraLook.corner = .topLeft
    d.clips = [Clip(start: 0.5, end: 2.5, take: 0), Clip(start: 1, end: 4, take: 1), Clip(start: 3, end: 4.5, take: 0)]
    d.segments = [ZoomSegment(start: 1, end: 3.5, scale: 2, take: 1), ZoomSegment(start: 0, end: 2, scale: 1.6, take: 0)]
    d.setCrop(NormRect(x: 0.1, y: 0.1, w: 0.6, h: 0.5), take: 1)
    cases.append(layoutCase("portrait-two-takes", d, takePairs([(2880, 1800, 2, 5), (1280, 720, 1, 4.5)], &lr)))
    d = EditDoc(); d.cameraLook.corner = .bottomLeft; d.cameraLook.size = 0.4; d.outputWidth = 1280; d.canvasAspect = 4.0 / 3.0
    d.cuts = [Cut(start: 1, end: 1.6)]; d.trimEnd = 4; d.cursorSmoothing = 0
    cases.append(layoutCase("cuts-trim", d, takePairs([(1512, 982, 2, 5), (640, 480, 1, 3)], &lr, cursor: false)))
    d = EditDoc(); d.cursorVisible = false; d.cameraLook.corner = .topRight
    cases.append(layoutCase("no-cursor", d, takePairs([(2560, 1600, 2, 3)], &lr)))
    d = EditDoc(); d.clickRipple = false; d.backdrop = .slate; d.cursorStyle = .dot
    cases.append(layoutCase("no-ripple", d, takePairs([(2560, 1600, 2, 3)], &lr)))
    write("layout.json", .o(["cases": .a(cases)]))
}

// MARK: - Cursor art

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func savePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

do {
    var arts: [J] = []
    for style in CursorStyle.allCases {
        for tint in CursorTint.allCases where style.tinted || tint == .clay {
            for (h, label) in [(66, "Connor"), (33, "")] {
                guard let a = CursorArt.image(style: style, tint: tint, label: label, pixelHeight: h) else { continue }
                let name = "cursor-\(style.rawValue)-\(tint.rawValue)-\(h).png"
                savePNG(a.image, renderOut.appendingPathComponent(name))
                arts.append(.o(["style": .s(style.rawValue), "tint": .s(tint.rawValue), "label": .s(label), "pixelHeight": .i(h),
                                "file": .s(name), "width": .i(a.image.width), "height": .i(a.image.height), "tip": .a([n(a.tip.x), n(a.tip.y)])]))
            }
        }
    }
    write("cursor_art.json", .o(["cases": .a(arts)]))
}

// MARK: - Reference frames rendered by the Swift Renderer

/// A test card: colour blocks, fine text, a checkerboard and a gradient.
func testCard(width w: Int, height h: Int, hue: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // a title bar and a sidebar
    ctx.setFillColor(CGColor(srgbRed: 0.85 * hue, green: 0.3, blue: 0.9 - 0.5 * hue, alpha: 1)); ctx.fill(CGRect(x: 0, y: H * 0.92, width: W, height: H * 0.08))
    ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.2, blue: 0.24, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W * 0.18, height: H * 0.92))
    // colour blocks
    let colours: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.2), (0.2, 0.7, 0.3), (0.2, 0.4, 0.9), (0.95, 0.8, 0.1), (0.6, 0.2, 0.7)]
    for (i, c) in colours.enumerated() {
        ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(CGRect(x: W * (0.22 + 0.15 * CGFloat(i)), y: H * 0.7, width: W * 0.12, height: H * 0.15))
    }
    // checkerboard
    let cell = max(2, W / 160)
    for yy in 0..<20 { for xx in 0..<30 where (xx + yy) % 2 == 0 {
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: W * 0.22 + CGFloat(xx) * cell, y: H * 0.08 + CGFloat(yy) * cell, width: cell, height: cell))
    } }
    // gradient
    let g = CGGradient(colorsSpace: srgb, colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)] as CFArray, locations: nil)!
    ctx.saveGState(); ctx.clip(to: CGRect(x: W * 0.6, y: H * 0.08, width: W * 0.35, height: H * 0.1))
    ctx.drawLinearGradient(g, start: CGPoint(x: W * 0.6, y: 0), end: CGPoint(x: W * 0.95, y: 0), options: []); ctx.restoreGState()
    // lines of text
    let font = CTFontCreateWithName("Helvetica" as CFString, max(8, H / 60), nil)
    for k in 0..<14 {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Line \(k): The quick brown fox jumps over the lazy dog 0123456789", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.1, green: 0.1, blue: 0.12, alpha: 1),
        ]))
        ctx.textPosition = CGPoint(x: W * 0.22, y: H * 0.62 - CGFloat(k) * H / 40)
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage()!
}

func webcamCard(width w: Int, height h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let W = CGFloat(w), H = CGFloat(h)
    ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.45, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.75, blue: 0.62, alpha: 1)); ctx.fillEllipse(in: CGRect(x: W * 0.3, y: H * 0.25, width: W * 0.4, height: H * 0.55))
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W * 0.15, height: H * 0.15)) // a marker: bottom-left in CG, mirrored shows it right
    return ctx.makeImage()!
}

do {
    let srcA = testCard(width: 1440, height: 900, hue: 0.2), srcB = testCard(width: 1280, height: 720, hue: 0.9), cam = webcamCard(width: 640, height: 480)
    savePNG(srcA, renderOut.appendingPathComponent("source-a.png"))
    savePNG(srcB, renderOut.appendingPathComponent("source-b.png"))
    savePNG(cam, renderOut.appendingPathComponent("webcam.png"))
    // CoreImage's CPU renderer: the same pixels every run (the GPU one isn't
    // guaranteed to be); the export painter is compared with a tolerance anyway.
    let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    let backdrops = root.appendingPathComponent("Resources/Backdrops")
    var cases: [J] = []
    var rr = LCG(state: 7)

    func render(_ name: String, _ doc: EditDoc, _ takes: [(meta: RecordingMeta, cursor: CursorTrack)], at t: Double,
                webcam: Bool = false, overlay: Bool = false, transcripts: [Transcript?] = []) {
        let doc = fixedIDs(doc)
        let r = Renderer(doc: doc, takes: takes, folder: backdrops, transcripts: transcripts)
        let p = r.map.locate(t)
        let src = CIImage(cgImage: p.take == 0 ? srcA : srcB)
        let image = r.render(source: src, webcam: webcam ? CIImage(cgImage: cam) : nil, overlay: overlay, at: t)
        // Render twice and insist on the same bytes: the fixtures must not
        // change between runs (CI regenerates and diffs them).
        func pixels() -> [UInt8] {
            let w = Int(r.canvas.width), h = Int(r.canvas.height)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(origin: .zero, size: r.canvas), format: .RGBA8, colorSpace: srgb)
            return px
        }
        let a = pixels(), b = pixels()
        if a != b {
            let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
            print("WARNING \(name): two renders differ (max \(worst)/255)")
        }
        let w = Int(r.canvas.width), h = Int(r.canvas.height)
        let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: a), width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        savePNG(ctx.makeImage()!, renderOut.appendingPathComponent("\(name).png"))
        var c: [String: J] = ["name": .s(name), "file": .s("\(name).png"), "t": n(t), "edit": jsonString(doc),
                              "takes": .a(takes.map { .o(["meta": jsonString($0.meta), "cursor": jsonString($0.cursor)]) }),
                              "sources": .a([.s("source-a.png"), .s("source-b.png")]), "webcam": webcam ? .s("webcam.png") : .null,
                              "overlay": .b(overlay), "backdropFolder": .s("Resources/Backdrops")]
        // Only on the cases that have them, so the older cases are unchanged.
        if !transcripts.isEmpty { c["transcripts"] = .a(transcripts.map { $0.map(jsonString) ?? .null }) }
        cases.append(.o(c))
    }
    func one(_ w: Int = 1440, _ h: Int = 900, duration: Double = 4) -> [(meta: RecordingMeta, cursor: CursorTrack)] {
        var m = RecordingMeta(pixelWidth: w, pixelHeight: h, pointScale: 1, duration: duration, createdAt: Date(timeIntervalSince1970: 0), source: "display")
        m.video = "screen.mov"
        var track = pointer(&rr, duration: duration)
        track.clicks.append(CursorSample(t: 1.0, x: 0.45, y: 0.4))
        return [(m, track)]
    }

    var d = EditDoc(); d.outputWidth = 960
    render("paper-default", d, one(), at: 1.12)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .charcoal; d.cursorStyle = .white
    d.segments = [ZoomSegment(start: 0, end: 4, scale: 2.2)]
    render("charcoal-zoom", d, one(), at: 2)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .dusk; d.cursorStyle = .soft; d.cursorTint = .sky
    d.setCrop(NormRect(x: 0.15, y: 0.05, w: 0.8, h: 0.7), take: 0)
    d.blurs = [BlurRegion(rect: NormRect(x: 0.2, y: 0.35, w: 0.35, h: 0.1), style: .blur, strength: 0.8),
               BlurRegion(rect: NormRect(x: 0.6, y: 0.1, w: 0.3, h: 0.15), style: .pixelate, strength: 0.5),
               BlurRegion(rect: NormRect(x: 0.22, y: 0.5, w: 0.2, h: 0.08), style: .solid, strength: 1)]
    render("dusk-crop-hides", d, one(), at: 1.6)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .slate; d.cursorStyle = .tag; d.cursorTint = .mint; d.cursorLabel = "Connor"
    d.cornerRadius = 0.05; d.cursorScale = 2.5
    render("slate-tag", d, one(), at: 2.5)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .none; d.canvasAspect = 0; d.cursorStyle = .dot; d.cursorTint = .rose
    render("none-dot", d, one(), at: 1.05)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .image; d.backdropImage = "monet-water-lilies.jpg"; d.backdropBlur = 0.5
    d.cameraLook.shape = .rounded; d.cameraLook.corner = .topLeft; d.cameraLook.mirror = false
    render("image-blur-camera-rounded", d, one(), at: 2, webcam: true)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .image; d.backdropImage = "hokusai-great-wave.jpg"
    d.cameraClips = [CameraClip(file: "x.mov", at: 1, duration: 3)]
    render("image-camera-fading", d, one(), at: 1.12, webcam: true, overlay: true)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .paper
    d.cameraClips = [CameraClip(file: "x.mov", at: 1, duration: 3, full: true)]
    render("camera-full", d, one(), at: 2.2, webcam: true, overlay: true)
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .charcoal; d.canvasAspect = 1
    d.clips = [Clip(start: 0, end: 1.5, take: 0), Clip(start: 0.5, end: 3, take: 1)]
    var two = one()
    var m2 = RecordingMeta(pixelWidth: 1280, pixelHeight: 720, pointScale: 1, duration: 3, createdAt: Date(timeIntervalSince1970: 0), source: "import", video: "screen.mp4")
    m2.cameraOffset = 0
    two.append((m2, CursorTrack()))
    render("two-takes-second", d, two, at: 2.4)
    render("two-takes-first", d, two, at: 0.7)
    // A clip at 1.5x, half way through fading up from the backdrop.
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .dusk
    var fast = Clip(start: 0.5, end: 3.5, speed: 1.5); fast.fadeIn = 1
    d.clips = [fast]
    render("dusk-fast-fading-in", d, one(), at: 0.45)
    // Texts: a title rising in over a fade, a caption with its words arriving, a label.
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .charcoal
    var first = Clip(start: 0, end: 4); first.fadeIn = 1.2
    d.clips = [first]
    var title = TextOverlay(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!, text: "Monet Shot", at: 0, duration: 3, style: .title, animation: .rise)
    title.uppercase = true
    let caption = TextOverlay(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!, text: "Zooms decided\nafter recording", at: 0.1, duration: 3.5, style: .caption, animation: .words)
    var label = TextOverlay(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000A3")!, text: "Click here", at: 0, duration: 4, style: .label, animation: .pop)
    label.tone = .dark; label.x = 0.3; label.y = 0.25
    d.texts = [title, caption, label]
    render("charcoal-texts", d, one(), at: 0.4)
    render("charcoal-texts-settled", d, one(), at: 1.9)
    // Captions from a transcript, the third word being said, on a phone-shaped canvas too.
    let said = Transcript(words: [TranscriptWord(text: "Zooms", start: 0.3, end: 0.7), TranscriptWord(text: "are", start: 0.75, end: 0.9),
                                  TranscriptWord(text: "decided", start: 0.95, end: 1.4), TranscriptWord(text: "after", start: 1.45, end: 1.7),
                                  TranscriptWord(text: "recording.", start: 1.75, end: 2.3), TranscriptWord(text: "Nice!", start: 3, end: 3.4)],
                          language: "en", engine: "apple")
    d = EditDoc(); d.outputWidth = 960; d.backdrop = .charcoal; d.captions = true
    render("charcoal-captions", d, one(), at: 1.2, transcripts: [said])
    d = EditDoc(); d.outputWidth = 540; d.backdrop = .dusk; d.canvasAspect = 9.0 / 16; d.captions = true; d.format = "melancholic"
    render("dusk-captions-tall", d, one(), at: 0.9, transcripts: [said])
    write("render/cases.json", .o(["cases": .a(cases)]))
}

// MARK: - Clip speed and fades
// Their own random stream, so adding them left every older fixture as it was.

do {
    var sr = LCG(state: 0x5BEED)
    func speedClips(_ rng: inout LCG, takes: [Double]) -> [Clip] {
        randomClips(&rng, takes: takes).map { c in
            var c = c
            c.speed = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 0.1, 9][rng.int(0, 9)]
            if rng.next() < 0.5 { c.fadeIn = rng.range(0, 1.5) }
            if rng.next() < 0.5 { c.fadeOut = rng.range(0, 1.5) }
            return c
        }
    }
    var cases: [J] = []
    var lists: [[Clip]] = [[Clip(start: 1, end: 3, take: 0, speed: 2), Clip(start: 5, end: 9, take: 1, speed: 0.5), Clip(start: 0, end: 1, take: 0)]]
    for _ in 0..<14 { lists.append(speedClips(&sr, takes: [10, 6])) }
    for list in lists {
        let m = TimeMap(clips: list)
        var q: [J] = []
        var t = -0.5
        while t < m.duration + 0.6 {
            let l = m.locate(t)
            q.append(.o(["t": n(t), "index": .i(l.index), "take": .i(l.take), "time": n(l.time), "presence": n(m.presence(t))]))
            t += 0.29
        }
        var o: [J] = []
        for take in 0..<2 {
            for k in stride(from: -0.5, through: 10.5, by: 0.61) {
                o.append(.o(["take": .i(take), "time": n(k), "output": m.output(take: take, time: k).map(J.n) ?? .null]))
            }
        }
        let total = m.duration
        var splits: [J] = [], drops: [J] = [], speeds: [J] = []
        for k in 0..<9 {
            let t = total * Double(k) / 8 + (k % 2 == 0 ? 0.05 : 0)
            splits.append(.o(["t": n(t), "result": ClipEdits.split(list, atOutput: t).map(clips) ?? .null]))
        }
        for i in -1...list.count {
            for c in [-1.0, 0.4, total / 2, total + 1] {
                drops.append(.o(["dragging": .i(i), "centreAt": n(c), "result": .i(ClipEdits.dropIndex(list, dragging: i, centreAt: c))]))
            }
            for v in [0.1, 0.5, 1, 2.5, 4, 7] {
                speeds.append(.o(["i": .i(i), "speed": n(v), "result": clips(ClipEdits.setSpeed(list, at: i, to: v))]))
            }
        }
        cases.append(.o(["clips": clips(list), "duration": n(m.duration),
                         "spans": .a(m.spans.map { .o(["take": .i($0.take), "start": n($0.start), "end": n($0.end), "at": n($0.at),
                                                        "speed": n($0.speed), "fadeIn": n($0.fadeIn), "fadeOut": n($0.fadeOut)]) }),
                         "starts": .a(ClipEdits.starts(list).map(J.n)),
                         "locate": .a(q), "output": .a(o), "split": .a(splits), "dropIndex": .a(drops), "setSpeed": .a(speeds)]))
    }
    write("clip_speed.json", .o(["cases": .a(cases)]))
}

// MARK: - Text overlays

func fixedID(_ k: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", k))! }

do {
    var tr = LCG(state: 0x7E47)
    let texts = ["Monet Shot", "Hello there", "Fast\nand clean", "  two  spaces ", "Ça va? Ünïcode", "", "One more line\nthen two\nthen three", "word"]
    var cases: [J] = []
    for k in 0..<40 {
        var o = TextOverlay(id: fixedID(k), text: texts[k % texts.count], at: tr.range(0, 5), duration: [0.3, 1, 2.5, 4, 0.005][tr.int(0, 4)],
                            style: TextStyle.allCases[tr.int(0, 2)], animation: TextAnimation.allCases[tr.int(0, 3)])
        o.x = tr.range(0, 1); o.y = tr.range(0, 1)
        o.size = [1, 0.5, 2, 0.1, 6][tr.int(0, 4)]
        o.tone = TextTone.allCases[tr.int(0, 2)]
        o.uppercase = tr.next() < 0.3
        if tr.next() < 0.3 { o.backing = tr.next() < 0.5 }
        let (w, h): (Double, Double) = [(2560, 1440), (960, 540), (1080, 1920), (641, 641)][tr.int(0, 3)]
        var q: [J] = []
        var t = o.at - 0.2
        while t < o.end + 0.2 {
            if let st = TextMotion.state(o, at: t, width: w, height: h) {
                q.append(.o(["t": n(t), "lines": .a(st.lines.map(J.s)), "px": n(st.px), "tracking": n(st.tracking), "centerX": n(st.centerX),
                             "centerY": n(st.centerY), "opacity": n(st.opacity), "scale": n(st.scale), "words": .a(st.words.map(J.n))]))
            } else {
                q.append(.o(["t": n(t), "state": .null]))
            }
            t += max(0.013, o.duration / 23)
        }
        cases.append(.o(["overlay": jsonString(o), "width": n(w), "height": n(h), "backing": .b(o.hasBacking), "states": .a(q)]))
    }
    var edits: [J] = []
    for _ in 0..<30 {
        let length = tr.range(0.2, 20)
        let (at, duration) = (tr.range(-2, 22), tr.range(0.1, 6))
        let (moveTo, leadTo, trailTo) = (tr.range(-3, 25), tr.range(-3, 25), tr.range(-3, 25))
        let o = TextEdits.insert("x", style: .caption, animation: .fade, at: at, videoLength: length, duration: duration)
        let moved = TextEdits.move(o, to: moveTo, videoLength: length)
        let lead = TextEdits.resize(o, leading: true, to: leadTo, videoLength: length)
        let trail = TextEdits.resize(o, leading: false, to: trailTo, videoLength: length)
        func span(_ o: TextOverlay) -> J { .o(["at": n(o.at), "duration": n(o.duration)]) }
        edits.append(.o(["videoLength": n(length), "at": n(at), "duration": n(duration), "moveTo": n(moveTo), "leadTo": n(leadTo),
                         "trailTo": n(trailTo), "inserted": span(o), "moved": span(moved), "lead": span(lead), "trail": span(trail)]))
    }
    // The Mac's layout of whole lines (pen advance and tracking), for the
    // desktop's own layout to match.
    var widths: [J] = []
    for (line, px, tracking) in [("Monet Shot", 40.0, -0.01), ("Hello there", 18.0, 0.02), ("ÇA VA? ÜNÏCODE", 77.0, 0), ("WWW iii", 31.0, 0)] {
        let l = TextArt.layout(line, font: TextArt.font(px), tracking: tracking)
        widths.append(.o(["line": .s(line), "px": n(px), "tracking": n(tracking), "width": n(Double(l.width)), "xs": .a(l.xs.map { n(Double($0)) })]))
    }
    // Edits mixing old keys with texts and a format, as the Mac writes them.
    var doc = EditDoc()
    doc.texts = [TextOverlay(id: fixedID(1), text: "Hi\nthere", at: 1, duration: 2, style: .caption, animation: .words)]
    doc.format = "fast"
    write("text.json", .o(["cases": .a(cases), "edits": .a(edits), "widths": .a(widths), "edit": jsonString(doc)]))
}

// MARK: - Formats

do {
    var fr = LCG(state: 0xF0F0)
    var docs: [(EditDoc, Double)] = []
    var d = EditDoc(); d.cuts = [Cut(start: 3, end: 5)]; d.trimStart = 1; d.trimEnd = 9
    d.segments = [ZoomSegment(id: fixedID(10), start: 1, end: 2.5, scale: 2, auto: true), ZoomSegment(id: fixedID(11), start: 6, end: 8, scale: 3.1)]
    docs.append((d, 10))
    d = EditDoc(); d.backdrop = .image; d.backdropImage = "backdrop-x.jpg"
    d.clips = [Clip(start: 0, end: 2, take: 0), Clip(start: 1, end: 4, take: 1, speed: 3)]
    d.texts = [TextOverlay(id: fixedID(20), text: "Title", at: 0, style: .title), TextOverlay(id: fixedID(21), text: "a caption", at: 1, style: .caption, animation: .rise),
               TextOverlay(id: fixedID(22), text: "label", at: 2, style: .label, animation: .words)]
    docs.append((d, 4))
    docs.append((EditDoc(), 7.5))
    for _ in 0..<5 {
        var doc = EditDoc()
        doc.clips = randomClips(&fr, takes: [10, 6])
        doc.segments = (0..<fr.int(0, 3)).map { k in ZoomSegment(id: fixedID(30 + k), start: fr.range(0, 4), end: fr.range(4, 8), scale: fr.range(1.2, 4), auto: fr.next() < 0.5) }
        doc.format = "clean"
        docs.append((doc, 10))
    }
    var cases: [J] = []
    for (doc, duration) in docs {
        for f in EditFormat.all {
            cases.append(.o(["format": .s(f.id), "duration": n(duration), "edit": jsonString(doc), "result": jsonString(f.apply(to: doc, duration: duration))]))
        }
    }
    let list: [J] = EditFormat.all.map { f in
        .o(["id": .s(f.id), "name": .s(f.name), "blurb": .s(f.blurb), "speed": n(f.speed), "musicMood": .s(f.musicMood)])
    }
    write("formats.json", .o(["formats": .a(list), "cases": .a(cases)]))
}


// MARK: - Captions
// Their own random stream, so adding them left every older fixture as it was.

do {
    var cr = LCG(state: 0xCA97)
    let vocab = ["so", "this", "is", "Monet", "Shot", "and", "the", "zoom", "follows", "my", "cursor", "here", "we", "go", "really",
                 "Ça", "va", "naïve", "café", "okay", "um", "uh", "nice", "recording", "editor", "captions", "word", "by", "a", "New York"]
    func transcript(_ length: Double) -> Transcript {
        var words: [TranscriptWord] = []
        var t = cr.range(0, 0.8)
        while t < length {
            let d = cr.range(0.12, 0.6)
            var w = vocab[cr.int(0, vocab.count - 1)]
            let r = cr.next()
            if r < 0.12 { w += "." } else if r < 0.16 { w += "?" } else if r < 0.18 { w += "…" } else if r < 0.24 { w += "," }
            if cr.next() < 0.03 { w = "" }
            words.append(TranscriptWord(text: w, start: t, end: min(length, t + d)))
            t += d + (cr.next() < 0.15 ? cr.range(0.7, 2) : cr.range(0.01, 0.3))
        }
        return Transcript(words: words, language: cr.next() < 0.5 ? "en" : nil, engine: cr.next() < 0.5 ? "whisper" : "apple")
    }
    var cases: [J] = []
    let canvases: [(Double, Double)] = [(2560, 1440), (1080, 1920), (960, 960), (1920, 1080)]
    for k in 0..<24 {
        let lengths = [10.0, 6.0]
        let trs: [Transcript?] = [transcript(lengths[0]), k % 3 == 0 ? nil : transcript(lengths[1])]
        var doc = EditDoc()
        if k % 4 != 0 {
            var list = randomClips(&cr, takes: lengths)
            for i in list.indices where cr.next() < 0.4 { list[i].speed = [0.5, 1.5, 2, 0.75][cr.int(0, 3)] }
            doc.clips = list
        } else {
            doc.cuts = [Cut(start: 2, end: 3.1)]
        }
        let map = TimeMap(doc, duration: lengths[0])
        let (w, h) = canvases[k % canvases.count]
        let anim = TextAnimation.allCases[cr.int(0, 3)]
        let words = Captions.words(trs, map: map)
        let overlays = Captions.overlays(trs, map: map, width: w, height: h, animation: anim)
        var states: [J] = []
        for o in overlays {
            var t = o.at - 0.05
            while t < o.end + 0.05 {
                if let st = TextMotion.state(o, at: t, width: w, height: h) {
                    states.append(.o(["t": n(t), "lines": .a(st.lines.map(J.s)), "px": n(st.px), "centerX": n(st.centerX), "centerY": n(st.centerY),
                                      "opacity": n(st.opacity), "scale": n(st.scale), "words": .a(st.words.map(J.n)),
                                      "highlight": st.highlight.map(J.i) ?? .null]))
                }
                t += 0.11
            }
        }
        cases.append(.o([
            "transcripts": .a(trs.map { $0.map(jsonString) ?? .null }), "edit": jsonString(doc), "takeDuration": n(lengths[0]),
            "width": n(w), "height": n(h), "animation": .s(anim.rawValue),
            "words": .a(words.map { .o(["text": .s($0.text), "start": n($0.start), "end": n($0.end), "span": .i($0.span), "take": .i($0.take), "index": .i($0.index)]) }),
            "overlays": .a(overlays.map(jsonString)), "srt": .s(Captions.srt(overlays)), "text": .s(Captions.text(words)), "states": .a(states),
        ]))
    }
    var lines: [J] = []
    for ws in [["one"], ["two", "words"], ["a", "rather", "longer", "phrase", "here"], ["Supercalifragilistic", "x"], ["Ça", "va", "très", "bien", "merci", "beaucoup"]] {
        lines.append(.o(["words": .a(ws.map(J.s)), "text": .s(Captions.lines(ws))]))
    }
    let tr = Transcript(words: [TranscriptWord(text: "Helo", start: 0.5, end: 0.9), TranscriptWord(text: "um", start: 1, end: 1.2),
                                TranscriptWord(text: "world", start: 1.3, end: 1.8)], language: "en", engine: "whisper")
    let edits: [J] = [(0, "Hello"), (1, ""), (2, "  big  world "), (5, "x")].map { i, text in
        .o(["index": .i(i), "text": .s(text), "result": jsonString(tr.editing(i, to: text))])
    }
    var meta = RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 2, duration: 12, createdAt: Date(timeIntervalSince1970: 1_700_000_000), source: "display")
    meta.voice = "voice.m4a"; meta.voiceOffset = 0.25
    var withCaptions = EditDoc(); withCaptions.captions = true
    write("captions.json", .o(["cases": .a(cases), "lines": .a(lines), "transcript": jsonString(tr), "edits": .a(edits),
                               "meta": jsonString(meta), "edit": jsonString(withCaptions),
                               "safeArea": .a(canvases.map { w, h in let r = safeArea(canvasWidth: w, canvasHeight: h)
                                   return .o(["width": n(w), "height": n(h), "x": n(Double(r.minX)), "y": n(Double(r.minY)), "w": n(Double(r.width)), "h": n(Double(r.height))]) })]))
}

// MARK: - Sync stamp

let head = Process()
head.executableURL = URL(fileURLWithPath: "/usr/bin/git")
head.arguments = ["-C", root.path, "rev-parse", "HEAD"]
let pipe = Pipe(); head.standardOutput = pipe
try head.run(); head.waitUntilExit()
let sha = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
let dirty = Process()
dirty.executableURL = URL(fileURLWithPath: "/usr/bin/git")
dirty.arguments = ["-C", root.path, "status", "--porcelain", "--", "Sources/MonetShotKit"]
let dpipe = Pipe(); dirty.standardOutput = dpipe
try dirty.run(); dirty.waitUntilExit()
let changed = String(data: dpipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
let stamp = sha + (changed.isEmpty ? "" : "\n# plus uncommitted MonetShotKit changes at generation time:\n" + changed.split(separator: "\n").map { "# " + $0 }.joined(separator: "\n")) + "\n"
try stamp.write(to: root.appendingPathComponent("shared/LAST_SYNC"), atomically: true, encoding: .utf8)
print("wrote shared/LAST_SYNC (\(sha.prefix(7)))")
