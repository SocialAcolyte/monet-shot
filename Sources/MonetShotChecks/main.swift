import AVFoundation
import Foundation
import CoreImage
import MonetShotKit

// Tests as a plain program: `swift run MonetShotChecks`. Exits non-zero on
// any failure. Each check gets a fresh temp directory; nothing touches the
// real config or logs (MONETSHOT_HOME is set before anything logs).
setenv("MONETSHOT_HOME", FileManager.default.temporaryDirectory.appendingPathComponent("monetshot-checks-\(getpid())").path, 1)

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func expect(_ condition: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if condition { passed += 1 } else { failures += 1; print("FAIL \(file):\(line) \(what)") }
}

func check(_ name: String, _ body: (URL) async throws -> Void) async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    do { try await body(dir) } catch { failures += 1; print("FAIL \(name): threw \(error)") }
}

await check("config round-trips") { dir in
    let store = Store(dir: dir)
    var c = Config()
    c.refreshSeconds = 120
    store.save(c)
    expect(store.loadConfig() == c, "saved config loads back")
}

// MARK: vertical (phones): layout, safe area, follow framing

await check("vertical layout round-trips and leaves landscape untouched") { _ in
    var d = EditDoc(); d.outputWidth = 3840; d.canvasAspect = 1
    let before = try JSONEncoder.app.encode(d)
    d.setLayout(.vertical)
    let tall = String(decoding: try JSONEncoder.app.encode(d), as: UTF8.self)
    expect(tall.contains("\"layout\" : \"vertical\""), "vertical is written")
    expect(d.canvasSize(recordingAspect: 1.6) == (1080, 1920), "vertical is 1080x1920")
    d.setLayout(.square)
    expect(d.canvasSize(recordingAspect: 1.6) == (1080, 1080), "square is 1080x1080")
    d.setLayout(.landscape)
    expect(try JSONEncoder.app.encode(d) == before, "back to landscape: byte-for-byte the old edit")
    let odd = try JSONDecoder.app.decode(EditDoc.self, from: Data(#"{"layout": "diagonal", "padding": 0.1}"#.utf8))
    expect(odd.canvasLayout == .landscape && odd.padding == 0.1, "an unknown layout draws as landscape, the rest still loads")
}

await check("safe area: phone bands on tall canvases only") { _ in
    let s = safeArea(canvasWidth: 1080, canvasHeight: 1920)
    expect(s == CGRect(x: 86, y: 230, width: 908, height: 1306), "1080x1920 keeps clear of the top 12% and bottom 20% (\(s))")
    expect(safeArea(canvasWidth: 1920, canvasHeight: 1080) == CGRect(x: 0, y: 0, width: 1920, height: 1080), "landscape is clear edge to edge")
    expect(safeArea(canvasWidth: 1080, canvasHeight: 1080).width == 1080, "square is clear edge to edge")
}

await check("follow framing: a tall window that holds, then glides") { _ in
    // The pointer rests left, wobbles a little (inside the dead zone), then crosses to the right.
    var samples: [CursorSample] = []
    for i in 0...600 {
        let t = Double(i) / 60
        let x = t < 5 ? 0.3 + 0.01 * sin(t * 9) : 0.85
        samples.append(CursorSample(t: t, x: x, y: 0.5))
    }
    let meta = RecordingMeta(pixelWidth: 2880, pixelHeight: 1800, pointScale: 2, duration: 10, source: "display")
    var d = EditDoc(); d.setLayout(.vertical)
    let r = Renderer(doc: d, meta: meta, cursor: CursorTrack(samples: samples))
    let f = r.frameRect()
    expect(r.canvas == CGSize(width: 1080, height: 1920), "canvas is 1080x1920")
    let pad = (0.07 * 1080).rounded()
    expect(f.width >= 1080 - 2 * pad - 1 && f.height >= 1920 - 2 * pad - 1, "the recording fills the phone frame inside the padding (\(f))")
    let c1 = r.camera(take: 0, time: 1), c2 = r.camera(take: 0, time: 3)
    expect(c1.window < 0.4 && c1.window > 0.25, "the window is tall (\(c1.window))")
    expect(abs(c1.centerX - c2.centerX) < 0.003, "a small wobble doesn't move it (\(c1.centerX) vs \(c2.centerX))")
    expect(abs(c1.centerX - 0.3) < 0.02, "it is on the pointer (\(c1.centerX))")
    let late = r.camera(take: 0, time: 9.5)
    expect(late.centerX > 0.8 - late.window / 2 && late.centerX <= 1 - late.window / 2 + 1e-9, "it ends on the right, inside the picture (\(late.centerX))")
    var fastest = 0.0
    var last = r.camera(take: 0, time: 0).centerX
    for k in 1...600 {
        let x = r.camera(take: 0, time: Double(k) / 60).centerX
        fastest = max(fastest, abs(x - last) * 60)
        last = x
    }
    expect(fastest < 0.9, "the glide is calm: at most \(fastest) picture widths a second")
    let v = late.viewport
    expect(v.x >= -1e-9 && v.x + v.w <= 1 + 1e-9 && v.h == 1, "the window stays inside the picture, full height")
    // Full height of a Retina take on a 1920 canvas: text is at least its own pixel size.
    expect(f.height / 1800 > 0.9, "legible: \(f.height / 1800) output px per recorded px")
}

await check("vertical: camera bubble and texts inside the safe area") { _ in
    let meta = RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 1, duration: 5, source: "display")
    for corner in CameraCorner.allCases {
        var d = EditDoc(); d.setLayout(.vertical); d.cameraLook.corner = corner; d.cameraLook.size = 0.5
        let r = Renderer(doc: d, meta: meta, cursor: CursorTrack())
        let b = r.bubbleRect
        let top = r.canvas.height - b.maxY
        let safe = safeArea(canvasWidth: 1080, canvasHeight: 1920)
        expect(top >= safe.minY && top + b.height <= safe.maxY && b.minX >= 0 && b.maxX <= 1080, "\(corner) bubble inside the safe area (\(b))")
    }
    var o = TextOverlay(text: "Hi", at: 0, duration: 2, style: .caption, animation: .fade)
    o.y = 1
    let st = TextMotion.state(Renderer.inSafeArea(o, width: 1080, height: 1920), at: 1, width: 1080, height: 1920)!
    expect(st.centerY <= 1920 * 0.8 + 0.5, "a caption at the very bottom sits on the safe line (\(st.centerY))")
}

await check("missing keys fall back to defaults") { dir in
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data(#"{"enabled": false}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
    let c = Store(dir: dir).loadConfig()
    expect(c.enabled == false, "explicit key kept")
    expect(c.refreshSeconds == Config().refreshSeconds, "missing key defaulted")
}

await check("damaged config is moved aside, not lost") { dir in
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: dir.appendingPathComponent("config.json"))
    expect(Store(dir: dir).loadConfig() == Config(), "defaults used")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    expect(names.contains { $0.hasPrefix("config.json.bad-") }, "bad file kept aside")
}

await check("files are owner-only") { dir in
    Store(dir: dir).save(Config())
    let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("config.json").path)
    expect(attrs[.posixPermissions] as? Int == 0o600, "config.json is 0600")
}

await check("journal round-trips") { dir in
    var s = RuntimeState()
    s.changes.append(.init(kind: "example", restoreValue: "0"))
    Store(dir: dir).save(s)
    expect(Store(dir: dir).loadState() == s, "state loads back")
}

await check("shell captures output") { _ in
    let r = await Shell().run("/bin/echo", ["hi"], timeout: .seconds(5))
    expect(r.ok && r.stdout == "hi\n", "echo output")
}

await check("shell times out") { _ in
    let r = await Shell().run("/bin/sleep", ["5"], timeout: .milliseconds(200))
    expect(r.timedOut && !r.ok, "sleep killed at timeout")
}


// MARK: - MonetShot logic

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-3) -> Bool { abs(a - b) < eps }

await check("auto zoom groups close clicks and merges near spans") { _ in
    let clicks = [CursorSample(t: 2, x: 0.3, y: 0.3), CursorSample(t: 3, x: 0.31, y: 0.3),
                  CursorSample(t: 12, x: 0.8, y: 0.7)]
    let segs = CameraMath.autoZooms(clicks: clicks, duration: 20)
    expect(segs.count == 2, "two groups -> two zooms (got \(segs.count))")
    expect(near(segs[0].start, 2 - CameraMath.leadIn), "zoom starts before first click")
    expect(near(segs[0].end, 3 + CameraMath.holdAfter), "zoom holds after last click")
    expect(segs.allSatisfy(\.auto), "auto segments are flagged")
    let close = CameraMath.autoZooms(clicks: [CursorSample(t: 2, x: 0, y: 0), CursorSample(t: 5.8, x: 0, y: 0)], duration: 20)
    expect(close.count == 1, "spans with too short a gap merge (got \(close.count))")
    expect(CameraMath.autoZooms(clicks: [], duration: 10).isEmpty, "no clicks, no zooms")
}

await check("zoom weight eases in, holds, eases out") { _ in
    let s = ZoomSegment(start: 1, end: 5, scale: 2)
    expect(CameraMath.weight(s, at: 0.5) == 0, "before")
    expect(CameraMath.weight(s, at: 3) == 1, "middle holds")
    let mid = CameraMath.weight(s, at: 1 + CameraMath.ramp / 2)
    expect(near(mid, 0.5), "half way up the ramp is 0.5 (smootherstep is symmetric)")
    expect(CameraMath.weight(s, at: 5) == 0, "after")
    let short = ZoomSegment(start: 0, end: 0.6, scale: 2)
    expect(CameraMath.weight(short, at: 0.3) == 1, "a short segment still reaches full zoom at its middle")
}

await check("camera stays inside the recording") { _ in
    let track = SmoothTrack(xs: [0.02, 0.02], ys: [0.98, 0.98])
    let seg = ZoomSegment(start: 0, end: 10, scale: 2)
    let cam = CameraMath.camera(at: 5, segments: [seg], focus: track)
    expect(near(cam.scale, 2), "full zoom")
    let v = cam.viewport
    expect(v.x >= -1e-9 && v.y >= -1e-9 && v.x + v.w <= 1 + 1e-9 && v.y + v.h <= 1 + 1e-9, "viewport clamped inside")
    expect(CameraMath.camera(at: 20, segments: [seg], focus: track) == .identity, "outside segments the camera is home")
    let fixed = ZoomSegment(start: 0, end: 10, scale: 2, focusX: 0.5, focusY: 0.5)
    let c2 = CameraMath.camera(at: 5, segments: [fixed], focus: track)
    expect(near(c2.centerX, 0.5) && near(c2.centerY, 0.5), "fixed focus ignores the cursor")
}

await check("smoothed cursor has no lag at a held position") { _ in
    let samples = [CursorSample(t: 0, x: 0.1, y: 0.1), CursorSample(t: 1, x: 0.1, y: 0.1),
                   CursorSample(t: 2, x: 0.9, y: 0.5), CursorSample(t: 4, x: 0.9, y: 0.5)]
    let track = SmoothTrack.make(from: samples, duration: 4, omega: CameraMath.cursorOmega(smoothing: 0.6))
    let p = track.position(at: 3)
    expect(near(p.x, 0.9, 0.01) && near(p.y, 0.5, 0.01), "settled on the held point (got \(p))")
    let mid = track.position(at: 1.5)
    expect(mid.x > 0.3 && mid.x < 0.7, "moving through the middle half way (got \(mid.x))")
    let start = track.position(at: 0)
    expect(near(start.x, 0.1, 0.02), "starts where the pointer started (got \(start.x))")
}

await check("segment edits stay in bounds and become hand-made") { _ in
    let s = ZoomSegment(start: 2, end: 4, scale: 2, auto: true)
    let moved = SegmentEdits.move(s, by: 10, duration: 6)
    expect(near(moved.start, 4) && near(moved.end, 6), "move is clamped to the end")
    expect(!moved.auto, "edited segments are no longer auto")
    let resized = SegmentEdits.resize(s, leading: true, to: 3.9, duration: 6)
    expect(near(resized.start, 4 - SegmentEdits.minDuration), "resize keeps a minimum length")
    expect(SegmentEdits.insert(at: 3, into: [s], duration: 6) == nil, "cannot insert inside a segment")
    let ins = SegmentEdits.insert(at: 5, into: [s], duration: 6)
    expect(ins != nil && ins!.start >= 4 && ins!.end <= 6, "insert fits the free space")
}

await check("re-running auto keeps hand-made zooms") { _ in
    let manual = ZoomSegment(start: 0, end: 3, scale: 3)
    let clicks = [CursorSample(t: 1, x: 0.5, y: 0.5), CursorSample(t: 10, x: 0.5, y: 0.5)]
    let out = SegmentEdits.reAuto([manual], clicks: clicks, duration: 20)
    expect(out.contains(manual), "manual kept")
    expect(out.filter(\.auto).count == 1, "the auto zoom overlapping the manual one is dropped")
}

await check("project round-trips and canvas sizes are even") { dir in
    let folder = dir.appendingPathComponent("a.reel")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("screen.mov"))
    var p = Project(folder: folder, meta: RecordingMeta(pixelWidth: 2880, pixelHeight: 1800, pointScale: 2, duration: 4, source: "display"),
                    cursor: CursorTrack(samples: [CursorSample(t: 0, x: 0.5, y: 0.5)]), edit: EditDoc())
    p.edit.backdrop = .charcoal
    try p.saveMeta(); try p.saveCursor(); try p.saveEdit()
    let back = try Project.load(folder)
    expect(back.edit == p.edit && back.meta == p.meta && back.cursor == p.cursor, "loads back identically")
    var doc = EditDoc(); doc.outputWidth = 1921; doc.canvasAspect = 0
    let size = doc.canvasSize(recordingAspect: 16.0 / 10.0)
    expect(size.height % 2 == 0, "height is even (got \(size.height))")
    let old = try JSONDecoder.app.decode(EditDoc.self, from: Data(#"{"padding": 0.1}"#.utf8))
    expect(old.padding == 0.1 && old.backdrop == .paper, "old edit files load with defaults")
}

await check("renderer frames the recording inside the canvas") { _ in
    let meta = RecordingMeta(pixelWidth: 2880, pixelHeight: 1800, pointScale: 2, duration: 2, source: "display")
    let r = Renderer(doc: EditDoc(), meta: meta, cursor: CursorTrack())
    expect(r.canvas.width == 2560 && r.canvas.height == 1440, "default canvas 2560x1440")
    let f = r.frameRect()
    expect(f.minX > 0 && f.minY > 0 && f.maxX < r.canvas.width && f.maxY < r.canvas.height, "frame sits inside the padding")
    expect(abs(f.width / f.height - 1.6) < 0.01, "frame keeps the recording's aspect")
    let src = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 2880, height: 1800))
    let out = r.render(source: src, at: 1)
    expect(out.extent == CGRect(origin: .zero, size: r.canvas), "output is exactly the canvas")
}

await check("time map plays clips in order, across takes") { _ in
    let m = TimeMap(clips: [Clip(start: 1, end: 3, take: 0), Clip(start: 5, end: 9, take: 1), Clip(start: 0, end: 1, take: 0)])
    expect(near(m.duration, 7), "duration is the clips' total (got \(m.duration))")
    let a = m.locate(2.5)
    expect(a.index == 1 && a.take == 1 && near(a.time, 5.5), "output -> clip, take and take time (got \(a))")
    let b = m.locate(6.5)
    expect(b.index == 2 && b.take == 0 && near(b.time, 0.5), "clips play in list order, not time order")
    expect(m.output(take: 1, time: 6) == 3, "take time -> output")
    expect(m.output(take: 1, time: 2) == nil && !m.keeps(take: 0, time: 4), "footage not in any clip isn't kept")
    var doc = EditDoc(); doc.cuts = [Cut(start: 3, end: 5)]; doc.trimStart = 1; doc.trimEnd = 9
    expect(near(TimeMap(doc, duration: 10).duration, 6), "a fresh recording: trim minus pause cuts")
}

await check("clip edits: split, resize, delete, reorder") { _ in
    let one = [Clip(start: 0, end: 10)]
    guard let two = ClipEdits.split(one, atOutput: 4) else { expect(false, "split failed"); return }
    expect(two == [Clip(start: 0, end: 4), Clip(start: 4, end: 10)], "split in two")
    expect(ClipEdits.split(two, atOutput: 4.05) == nil, "no split right at an edge")
    let shrunk = ClipEdits.resize(two, at: 0, leading: false, to: 3, takeDuration: 10)
    expect(shrunk[0].end == 3, "shrink the first clip's end")
    let grown = ClipEdits.resize(shrunk, at: 1, leading: true, to: 1, takeDuration: 10)
    expect(grown[1].start == 1, "an edge can reach back over footage another clip also shows")
    let clamped = ClipEdits.resize(two, at: 1, leading: false, to: 99, takeDuration: 10)
    expect(clamped[1].end == 10, "an edge stops at the end of its take")
    expect(ClipEdits.delete(two, at: 0) == [Clip(start: 4, end: 10)], "delete a clip")
    expect(ClipEdits.delete(one, at: 0) == one, "the last clip can't be deleted")
    let three = [Clip(start: 0, end: 2), Clip(start: 0, end: 2, take: 1), Clip(start: 5, end: 6)]
    expect(ClipEdits.move(three, from: 2, to: 0).first == Clip(start: 5, end: 6), "reorder")
    expect(ClipEdits.dropIndex(three, dragging: 0, centreAt: 3.5) == 2, "dragged past the last midpoint lands at the end")
    expect(ClipEdits.dropIndex(three, dragging: 2, centreAt: 0.4) == 0, "dragged to the start lands first")
    expect(ClipEdits.starts(three) == [0, 2, 4], "output starts")
}

await check("clip speed: a fast clip is shorter, edits stay on the footage") { _ in
    let m = TimeMap(clips: [Clip(start: 0, end: 4, speed: 2), Clip(start: 4, end: 6, take: 0, speed: 0.5)])
    expect(near(m.duration, 6), "2 s at 2x plus 4 s at 0.5x (got \(m.duration))")
    expect(near(m.locate(1).time, 2) && near(m.locate(3).time, 4.5), "output -> take time at each clip's speed")
    expect(near(m.output(take: 0, time: 5) ?? -1, 4), "take time -> output at 0.5x")
    let halves = ClipEdits.split([Clip(start: 0, end: 4, speed: 2)], atOutput: 1)
    expect(halves?.map(\.end) == [2, 4] && halves?.allSatisfy { $0.speed == 2 } == true, "a split cuts at the footage under the playhead and keeps the speed")
    expect(ClipEdits.setSpeed([Clip(start: 0, end: 1)], at: 0, to: 99)[0].speed == 4, "speed stays in range")
}

await check("new edit fields are written only when set") { _ in
    let plain = String(data: try JSONEncoder.app.encode(EditDoc()), encoding: .utf8)!
    expect(!plain.contains("texts") && !plain.contains("format"), "an edit without texts or a format writes neither key")
    let clip = String(data: try JSONEncoder.app.encode(Clip(start: 0, end: 1)), encoding: .utf8)!
    expect(!clip.contains("speed") && !clip.contains("fade"), "a plain clip writes no speed or fades")
    var c = Clip(start: 0, end: 1, speed: 1.5); c.fadeIn = 0.5
    let back = try JSONDecoder.app.decode(Clip.self, from: JSONEncoder.app.encode(c))
    expect(back == c, "speed and fades round-trip")
}

await check("formats set the pace and the look, texts follow them") { _ in
    var d = EditDoc(); d.cuts = [Cut(start: 2, end: 3)]; d.backdrop = .image
    d.texts = [TextOverlay(text: "Hi", at: 0, style: .title, animation: .rise)]
    let f = EditFormat.fast.apply(to: d, duration: 6)
    expect(f.clips?.count == 2 && f.clips?.allSatisfy { $0.speed == 1.5 } == true, "every clip at the format's speed")
    expect(f.backdrop == .image, "a picture of your own stays")
    expect(f.overlays.first?.animation == .pop && f.overlays.first?.uppercase == true, "titles pop, in capitals")
    let m = EditFormat.melancholic.apply(to: d, duration: 6)
    expect(m.clips?.first?.fadeIn == 1.6 && m.clips?.last?.fadeOut == 2 && m.format == "melancholic", "melancholic fades open and close")
    expect(TimeMap(clips: m.clips ?? []).presence(0) < 0.01, "a fading clip starts on the backdrop")
}

await check("texts come in, and are drawn") { _ in
    var o = TextOverlay(text: "One two three", at: 1, duration: 3, style: .caption, animation: .words)
    expect(TextMotion.state(o, at: 0.5, width: 1920, height: 1080) == nil, "not before it starts")
    let early = TextMotion.state(o, at: 1.05, width: 1920, height: 1080)
    expect(early?.words.count == 3 && (early?.words[2] ?? 1) < 0.01, "words arrive one by one")
    o.animation = .pop
    let st = TextMotion.state(o, at: 2, width: 1920, height: 1080)
    expect(st.map { abs($0.scale - 1) < 0.01 && $0.opacity > 0.99 } == true, "settled after coming in")
    expect(st.flatMap { TextArt.image($0, tone: .light, backing: true) } != nil, "the text draws (font found)")
}

await check("takes: a second take loads, and zooms stay on their take") { dir in
    let folder = dir.appendingPathComponent("b.reel")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("screen.mov"))
    var p = Project(folder: folder, meta: RecordingMeta(pixelWidth: 2880, pixelHeight: 1800, pointScale: 2, duration: 4, source: "display"),
                    cursor: CursorTrack(), edit: EditDoc())
    try p.saveMeta(); try p.saveCursor(); try p.saveEdit()
    let tf = p.nextTakeFolder()
    expect(tf.lastPathComponent == "take-2", "first extra take is take-2")
    try FileManager.default.createDirectory(at: tf, withIntermediateDirectories: true)
    try Data().write(to: tf.appendingPathComponent("screen.mp4"))
    try Take(folder: tf, meta: RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 1, duration: 6, source: "import", video: "screen.mp4"),
             cursor: CursorTrack()).save()
    p = try Project.load(folder)
    expect(p.takes.count == 2 && p.duration(ofTake: 1) == 6 && !p.takes[1].hasCursor, "take 2 loads with its own meta")
    expect(p.nextTakeFolder().lastPathComponent == "take-3", "then take-3")
    let segs = [ZoomSegment(start: 0, end: 2, take: 0), ZoomSegment(start: 1, end: 3, take: 1)]
    let re = SegmentEdits.reAuto(segs, clicks: [CursorSample(t: 2, x: 0.5, y: 0.5)], duration: 6, take: 1)
    expect(re.contains(segs[0]), "re-running auto on take 2 leaves take 1's zooms alone")
    let old = try JSONDecoder.app.decode(ZoomSegment.self, from: Data(#"{"id":"\#(UUID().uuidString)","start":1,"end":2,"scale":2,"auto":true}"#.utf8))
    expect(old.take == 0, "zooms saved before takes existed belong to the first take")
    let r = Renderer(project: p)
    let f2 = r.frameRect(take: 1)
    expect(abs(f2.width / f2.height - 16.0 / 9.0) < 0.01, "each take is framed at its own shape")
}

await check("the music library parses, and tracks without a file are skipped") { dir in
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: dir.appendingPathComponent("morning.m4a"))
    let json = #"""
    [{"id": "morning", "title": "Morning", "artist": "Someone", "duration": 154, "genres": ["dreamy"],
      "license": "cc0", "licenseVersion": "1.0", "audioURL": "morning.m4a", "about": "Soft and bright."},
     {"id": "gone", "title": "Gone", "artist": "Someone", "duration": 60, "genres": [], "license": "pdm", "audioURL": "gone.m4a"}]
    """#
    let songs = try MusicCatalog.parse(Data(json.utf8), folder: dir)
    expect(songs.count == 1, "only tracks with a file are kept (got \(songs.count))")
    let t = songs[0]
    expect(t.title == "Morning" && t.duration == 154 && t.genres == ["dreamy"], "fields read")
    expect(URL(string: t.audioURL)?.isFileURL == true && t.audioURL.hasSuffix("morning.m4a"), "file name becomes a file URL in the folder")
    expect(!t.needsCredit && t.licenseLabel == "CC0", "CC0 needs no credit")
    var doc = EditDoc(); doc.music = MusicChoice(track: t, file: "music-x.m4a")
    let back = try JSONDecoder.app.decode(EditDoc.self, from: JSONEncoder.app.encode(doc))
    expect(back.music == doc.music, "music choice round-trips in edit.json")
}

await check("the app's own music library is all there, and free of conditions") { _ in
    let songs = try await MusicCatalog.all()
    expect(songs.count >= 15, "the library has its tracks (\(songs.count))")
    expect(songs.allSatisfy { !$0.needsCredit }, "every track is CC0 or public domain")
    expect(songs.allSatisfy { s in s.genres.contains { g in MusicMood.all.contains { $0.feel == g } } }, "every track sits under a mood")
    expect(songs.count >= 40, "a library worth choosing from (\(songs.count) tracks)")
    expect(songs.allSatisfy { MusicTempo.of($0) != nil && $0.energy != nil && ($0.peaks?.count ?? 0) >= 32 },
           "every track has a tempo, an energy and a waveform")
    expect(songs.allSatisfy { $0.licenseURL != nil && $0.pageURL != nil }, "every track names its licence and its source page")
    for mood in MusicMood.all {
        expect(songs.filter { $0.genres.contains(mood.feel) }.count >= 5, "\(mood.name) has at least five tracks")
    }
    for tempo in MusicTempo.allCases {
        expect(songs.filter { MusicTempo.of($0) == tempo }.count >= 6, "\(tempo.name) has at least six tracks")
    }
    if let folder = MusicCatalog.folder {
        let bytes = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]))?
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +) ?? 0
        expect(bytes < 80_000_000, "the library stays under 80 MB (\(bytes / 1_000_000) MB)")
    }
    // a library track placed under a 30 s video: on a downbeat, the end fade from a phrase line
    for song in songs where song.grid != nil {
        let g = song.grid!
        let p = MusicFit.place(grid: g, songDuration: song.duration, length: 30, from: song.start)
        let beats = (p.offset - g.firstDownbeat) / g.bar
        expect(abs(beats - beats.rounded()) < 1e-6 && p.offset + 30 <= song.duration + 0.01, "\(song.id) starts on a downbeat inside the song")
        expect(p.outro >= min(1.5, 10) - 1e-9 && p.outro <= 10 + 1e-9, "\(song.id) fades over a bar or two (\(p.outro))")
    }
}

await check("music fits the edit: downbeat in, phrase out") { _ in
    let g = MusicGrid(bar: 2, firstDownbeat: 0.5, lifts: [16.5, 40.5])
    for length in [10.0, 23.7, 31.3, 64.9] {
        let p = MusicFit.place(grid: g, songDuration: 180, length: length)
        let end = p.offset + length
        let fadeStart = end - p.outro
        let bars = (fadeStart - g.firstDownbeat) / g.bar
        expect(abs(bars - bars.rounded()) < 1e-6, "the end fade starts on a bar line (\(length) s)")
        if p.outro < length / 3 - 1e-9 {
            expect(Int(bars.rounded()) % 4 == 0, "and on a phrase line (\(length) s: \(bars) bars)")
            expect(p.outro >= 2 - 1e-9 && p.outro < 4 + 1e-9, "the fade lasts a bar or two (\(p.outro))")
        }
    }
    let punchy = MusicFit.place(grid: g, songDuration: 180, length: 15, punchy: true)
    expect(punchy.offset >= 16.5 - 1e-9 && punchy.offset < 16.5 + 4 * g.bar, "a punchy edit starts at the first lift (\(punchy.offset))")
    let plain = MusicFit.place(grid: nil, songDuration: 60, length: 20)
    expect(plain.offset == 0 && plain.outro == MusicFit.plainOutro, "no beat: from the top, the plain fade")
    // the envelope follows the fitted fade
    expect(near(MusicEnvelope.gain(at: 17, length: 20, fadeIn: true, fadeOut: true, outro: 6, voice: []), 0.5), "a 6 s outro is halfway down 3 s before the end")
    expect(near(MusicEnvelope.gain(at: 17, length: 20, fadeIn: true, fadeOut: true, voice: []), 1), "the plain fade is 2 s")
}

await check("music ducks where the take has a voice, by its level") { _ in
    let rate = 16_000.0
    var s = [Float](repeating: 0, count: Int(rate * 12))
    for i in s.indices {
        let t = Double(i) / rate
        s[i] = Float(0.002 * sin(2 * .pi * 50 * t))                       // room hum
        if (2..<5).contains(t) || (5.3..<6).contains(t) || (9..<9.08).contains(t) {
            s[i] += Float(0.2 * sin(2 * .pi * 220 * t))                   // talking (and a click at 9 s)
        }
    }
    let r = VoiceActivity.ranges(samples: s, rate: rate)
    expect(r.count == 1, "one stretch of talk; the short pause is bridged and the click ignored (\(r))")
    if let v = r.first { expect(abs(v.lowerBound - 2) < 0.06 && abs(v.upperBound - 6) < 0.06, "from 2 s to 6 s (\(v))") }
    expect(VoiceActivity.ranges(samples: [Float](repeating: 0, count: 16_000), rate: rate).isEmpty, "silence is no voice")
}

await check("suggestions suit the video") { _ in
    let calm = Song(id: "calm", title: "C", artist: "x", duration: 200, genres: ["mellow"], license: "cc0", audioURL: "c", tempo: "calm", energy: 0.2)
    let punchy = Song(id: "punchy", title: "P", artist: "x", duration: 120, genres: ["punchy"], license: "cc0", audioURL: "p", tempo: "upbeat", energy: 0.95)
    let short = Song(id: "short", title: "S", artist: "x", duration: 20, genres: ["mellow"], license: "cc0", audioURL: "s", tempo: "steady", energy: 0.5)
    let all = [calm, punchy, short]
    expect(MusicSuggest.rank(all, length: 20, mood: nil, vertical: true).first?.id == "punchy", "vertical: the punchy one first")
    expect(MusicSuggest.rank(all, length: 60, mood: "mellow", vertical: false).first?.id == "calm", "the format's mood, long enough")
    expect(MusicSuggest.rank(all, length: 60, mood: "mellow", vertical: false).last?.id == "short", "a song that would loop comes last")
    var twin = calm; twin.id = "twin"
    expect(MusicSuggest.rank([calm, twin], length: 60, mood: nil, vertical: false, favourites: ["twin"]).first?.id == "twin", "a favourite wins a tie")
}

await check("cursor styles") { dir in
    for style in CursorStyle.allCases {
        guard let art = CursorArt.image(style: style, tint: .sky, label: "Connor", pixelHeight: 66) else {
            expect(false, "\(style) renders"); continue
        }
        expect(art.tip.x > 0 && art.tip.x < CGFloat(art.image.width) && art.tip.y < CGFloat(art.image.height), "\(style) hotspot inside")
        if style == .tag {
            let plain = CursorArt.image(style: .soft, tint: .sky, label: "", pixelHeight: 66)!
            expect(art.image.width > plain.image.width, "name tag widens the art")
        }
    }
    var doc = EditDoc(); doc.cursorStyle = .tag; doc.cursorTint = .mint; doc.cursorLabel = "Connor"
    let back = try JSONDecoder.app.decode(EditDoc.self, from: JSONEncoder.app.encode(doc))
    expect(back.cursorStyle == .tag && back.cursorTint == .mint && back.cursorLabel == "Connor", "cursor look round-trips")
    let old = try JSONDecoder.app.decode(EditDoc.self, from: Data("{}".utf8))
    expect(old.cursorStyle == .classic, "old edits keep the classic cursor")
    // MONETSHOT_CURSOR_SHEET=<out.png> writes every style and tint for a look.
    if let out = ProcessInfo.processInfo.environment["MONETSHOT_CURSOR_SHEET"] {
        let cell = 150, cols = CursorTint.allCases.count, rows = CursorStyle.allCases.count
        let ctx = CGContext(data: nil, width: cell * cols, height: cell * rows, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.92, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: cell * cols, height: cell * rows))
        for (r, style) in CursorStyle.allCases.enumerated() {
            for (c, tint) in CursorTint.allCases.enumerated() {
                let a = CursorArt.image(style: style, tint: tint, label: "Connor", pixelHeight: 66)!
                let y = cell * (rows - 1 - r) + 30
                ctx.draw(a.image, in: CGRect(x: cell * c + 30, y: y + 90 - a.image.height, width: a.image.width, height: a.image.height))
            }
        }
        let img = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }
}

await check("camera clips") { _ in
    let a = CameraClip(file: "a.mov", at: 1, duration: 4)
    let b = CameraClip(file: "b.mov", at: 3, duration: 2)
    let both = CameraEdits.insert(b, into: [a])
    expect(both.count == 2 && near(both[0].end, 3) && both[1].file == "b.mov", "recording over a clip trims it (got \(both.map(\.end)))")
    let over = CameraEdits.insert(CameraClip(file: "c.mov", at: 0.5, duration: 9), into: both)
    expect(over.count == 1 && over[0].file == "c.mov", "recording over everything replaces it")
    expect(CameraEdits.presence(a, at: 0.5) == 0 && CameraEdits.presence(a, at: 3) == 1, "present only inside, whole in the middle")
    expect(CameraEdits.presence(a, at: 1.05) > 0 && CameraEdits.presence(a, at: 1.05) < 0.5, "fades in")
    let quiet = MusicEnvelope.gain(at: 5, length: 20, fadeIn: true, fadeOut: true, voice: [4...8])
    let loud = MusicEnvelope.gain(at: 12, length: 20, fadeIn: true, fadeOut: true, voice: [4...8])
    expect(near(quiet, MusicEnvelope.duckLevel) && near(loud, 1), "music ducks under the voice (\(quiet), \(loud))")
    expect(MusicEnvelope.gain(at: 0, length: 20, fadeIn: true, fadeOut: true, voice: []) == 0, "fades in from silence")
    var doc = EditDoc(); doc.cameraClips = [a]; doc.cameraLook.corner = .topLeft
    let back = try JSONDecoder.app.decode(EditDoc.self, from: JSONEncoder.app.encode(doc))
    expect(back.cameraClips == [a] && back.cameraLook.corner == .topLeft, "camera round-trips in edit.json")
    let r = Renderer(doc: doc, meta: RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 1, duration: 10, source: "display"), cursor: CursorTrack())
    let bubble = r.bubbleRect
    expect(bubble.minX < r.canvas.width / 4 && bubble.maxY > r.canvas.height * 3 / 4, "top-left bubble sits top-left (CoreImage y-up)")
}

await check("hiding and cropping: rect maths and edit.json") { _ in
    let r = NormRect(x: 0.6, y: 0.1, w: 0.3, h: 0.5)
    expect(r.moved(dx: 0.3, dy: -0.5) == NormRect(x: 0.7, y: 0, w: 0.3, h: 0.5), "a move stops at the frame's edges")
    let grown = r.resized(handleX: 0, handleY: 1, dx: -0.1, dy: 0.2)
    expect(near(grown.x, 0.5) && near(grown.maxX, 0.9) && near(grown.y, 0.1) && near(grown.maxY, 0.8), "bottom-left handle moves only its edges")
    let flat = r.resized(handleX: 1, handleY: 0.5, dx: -0.5, dy: 0.3, minSize: 0.05)
    expect(near(flat.w, 0.05) && near(flat.h, 0.5), "an edge handle stops at the minimum and leaves the other axis")
    let p = r.local(0.75, 0.35)
    expect(near(p.x, 0.5) && near(p.y, 0.5) && near(r.global(p.x, p.y).x, 0.75), "local and global are inverses")
    var b = BlurRegion(rect: r, style: .pixelate, start: 2)
    expect(!b.covers(1) && b.covers(2) && b.covers(99), "a blur with only a start runs to the end")
    b.end = 5
    expect(!b.covers(5) && b.covers(4.9), "and stops at its end")
    var doc = EditDoc()
    doc.blurs = [b]
    doc.setCrop(NormRect(x: 0, y: 0, w: 0.5, h: 1), take: 0)
    let back = try JSONDecoder.app.decode(EditDoc.self, from: JSONEncoder.app.encode(doc))
    expect(back.blurs == [b] && back.crop(take: 0) == NormRect(x: 0, y: 0, w: 0.5, h: 1) && back.crop(take: 1) == .full, "blurs and crops round-trip")
    doc.setCrop(.full, take: 0)
    expect(doc.crops.isEmpty, "cropping to the whole frame removes the crop")
    let old = try JSONDecoder.app.decode(EditDoc.self, from: Data(#"{"padding": 0.1}"#.utf8))
    expect(old.blurs.isEmpty && old.crops.isEmpty, "older edit.json files load with nothing hidden")
}

await check("hiding and cropping: what the renderer draws") { _ in
    // A 400x200 frame, left half white, right half black, with a hard
    // black/white edge inside the right half at x = 300.
    let w = 400, h = 200
    let left = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: h))
    let stripe = CIImage(color: .white).cropped(to: CGRect(x: 300, y: 0, width: 100, height: h))
    let frame = stripe.composited(over: left).composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)))
    let ctx = CIContext(options: [.workingColorSpace: NSNull()])
    func grey(_ img: CIImage, _ x: CGFloat, _ yTop: CGFloat) -> Double {
        var px = [UInt8](repeating: 0, count: 4)
        let e = img.extent
        ctx.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: e.minX + x, y: e.maxY - yTop - 1, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        return Double(px[0]) / 255
    }
    // Hide x 250...350 (the edge at 300) for take time 1...3.
    let blur = BlurRegion(rect: NormRect(x: 0.625, y: 0, w: 0.25, h: 1), strength: 1, start: 1, end: 3)
    let on = Renderer.obscure(frame, [blur], at: 2)
    let off = Renderer.obscure(frame, [blur], at: 4)
    expect(grey(off, 298, 100) < 0.05 && grey(off, 302, 100) > 0.95, "outside its time the edge stays sharp")
    let a = grey(on, 298, 100), c = grey(on, 302, 100)
    expect(abs(a - c) < 0.25, "inside its time the edge is blurred away (\(a) vs \(c))")
    expect(grey(on, 100, 100) > 0.95 && grey(on, 220, 100) < 0.05, "nothing outside the box changes")
    let solid = Renderer.obscure(frame, [BlurRegion(rect: blur.rect, style: .solid)], at: 0)
    expect(grey(solid, 320, 100) < 0.2, "a cover is dark")

    let cropped = Renderer.framed(frame, crop: NormRect(x: 0.5, y: 0, w: 0.5, h: 1))
    expect(cropped.extent == CGRect(x: 0, y: 0, width: 200, height: 200), "a crop keeps its part, at the origin (\(cropped.extent))")
    expect(grey(cropped, 50, 100) < 0.05 && grey(cropped, 150, 100) > 0.95, "and it is the right part")

    // Cropping to a square makes the framed recording square, and the cursor follows.
    var doc = EditDoc()
    doc.canvasAspect = 1
    doc.backdrop = .none
    let meta = RecordingMeta(pixelWidth: w, pixelHeight: h, pointScale: 1, duration: 10, source: "display")
    let whole = Renderer(doc: doc, meta: meta, cursor: CursorTrack())
    doc.setCrop(NormRect(x: 0.5, y: 0, w: 0.5, h: 1), take: 0)
    let square = Renderer(doc: doc, meta: meta, cursor: CursorTrack())
    let fw = whole.frameRect(), fs = square.frameRect()
    expect(abs(fw.width / fw.height - 2) < 0.02 && abs(fs.width / fs.height - 1) < 0.02, "framed aspect follows the crop (\(fw.size), \(fs.size))")
    let out = square.render(source: frame, take: 0, time: 0)
    expect(grey(out, out.extent.width * 0.25, out.extent.height / 2) < 0.05 && grey(out, out.extent.width * 0.75, out.extent.height / 2) > 0.95,
           "the render shows only the cropped part, filling the frame")
}

await check("the music grid finds the beat, the downbeat and the lift") { _ in
    // 108 bpm, downbeats from 0.5 s, hard on beat one; eight quiet bars, then a louder section
    let rate = 11_025.0, beat = 60.0 / 108, n = Int(rate * 40)
    var s = [Float](repeating: 0, count: n)
    var k = 0
    var t = 0.5
    while t < 40 {
        let loud: Float = t < 0.5 + 8 * beat * 4 ? 0.25 : 0.8
        let hit: Float = (k % 4 == 0 ? 1 : 0.45) * loud
        let i0 = Int(t * rate)
        for i in 0..<Int(rate * 0.12) where i0 + i < n { s[i0 + i] += hit * Float(sin(Double(i) * 0.35)) * Float(exp(-Double(i) / (rate * 0.03))) }
        // a soft hat between beats
        let h0 = Int((t + beat / 2) * rate)
        for i in 0..<Int(rate * 0.02) where h0 + i < n { s[h0 + i] += 0.08 * loud * Float.random(in: -1...1) }
        k += 1; t += beat
    }
    guard let g = MusicGrid.analyze(samples: s, rate: rate) else { expect(false, "a grid was found"); return }
    expect(abs(g.bpm - 108) < 1.5, "tempo is about 108 bpm (\(g.bpm))")
    let off = abs(g.firstDownbeat - 0.5).truncatingRemainder(dividingBy: g.bar)
    expect(min(off, g.bar - off) < 0.06, "the downbeat is found (\(g.firstDownbeat))")
    let lift = 0.5 + 8 * beat * 4
    expect(g.lifts.contains { abs($0 - lift) < 0.15 }, "the louder section is a lift (\(g.lifts), want \(lift))")
    expect(abs(g.nearestBarLine(lift + 0.4) - lift) < 0.06, "times snap to the nearest bar line")
}


// MARK: - Captions and voice

await check("captions: a transcript through a cut and a 2x clip, phrases, srt, the word being said") { _ in
    let said = ["Monet", "Shot", "turns", "a", "screen", "recording", "into", "a", "polished", "demo.", "Zooms", "come", "later."]
    var words: [TranscriptWord] = []
    for (k, w) in said.enumerated() { words.append(TranscriptWord(text: w, start: 0.5 + Double(k) * 0.4, end: 0.8 + Double(k) * 0.4)) }
    let tr = Transcript(words: words, language: "en", engine: "apple")
    // Keep 0...2 (first 4 words), cut 2...3, then 3...6 at 2x.
    let a = Clip(start: 0, end: 2)
    var b = Clip(start: 3, end: 6)
    b.speed = 2
    let map = TimeMap(clips: [a, b])
    let cw = Captions.words([tr], map: map)
    expect(cw.first?.text == "Monet" && near(cw[0].start, 0.5), "first word at its own time")
    expect(!cw.contains { $0.text == "screen" }, "a word in the cut isn't shown (\(cw.map(\.text)))")
    if let i = cw.firstIndex(where: { $0.text == "into" }) {
        // "into" starts at 2.9 in the take: 3 is the clip's start, so output 2 + 0 (clamped), ends (3.2-3)/2 later.
        expect(near(cw[i].start, 2) && near(cw[i].end, 2.1), "a word in the 2x clip is squeezed (\(cw[i].start)...\(cw[i].end))")
    } else { expect(false, "\"into\" is in the 2x clip") }
    let overlays = Captions.overlays([tr], map: map, width: 1920, height: 1080)
    expect(overlays.allSatisfy { $0.style == .caption && $0.beats?.count == $0.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count }, "phrases carry a beat per word")
    expect(overlays.first?.text.contains("Monet Shot") == true, "the first phrase opens with the first words")
    expect(overlays.allSatisfy { $0.text.split(separator: "\n").count <= 2 && $0.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count <= Captions.maxWords }, "at most two lines and six words")
    expect(zip(overlays, overlays.dropFirst()).allSatisfy { $0.end <= $1.at + 1e-9 }, "phrases never overlap")
    expect(overlays.allSatisfy { $0.y > 0.7 && $0.y < 0.94 }, "captions sit in the bottom of the safe area")
    let srt = Captions.srt(overlays)
    expect(srt.hasPrefix("1\n00:00:00,500 --> "), "srt starts with the first phrase at 0.5 s (\(srt.prefix(30)))")
    let o = overlays[0]
    let st = TextMotion.state(o, at: o.at + (o.beats?[1] ?? 0) + 0.01, width: 1920, height: 1080)
    expect(st?.highlight == 1, "the second word is lit while it's said")
    expect(TextMotion.state(o, at: o.at + 0.01, width: 1920, height: 1080)?.highlight == 0, "the first word is lit at the start")
    var doc = EditDoc()
    doc.captions = true
    doc.clips = [a, b]
    let r = Renderer(doc: doc, takes: [(RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 1, duration: 8, source: "display"), CursorTrack())],
                     folder: nil, transcripts: [tr])
    expect(r.captions.count == overlays.count, "the renderer shows the captions when switched on")
    doc.captions = nil
    let off = Renderer(doc: doc, takes: [(RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 1, duration: 8, source: "display"), CursorTrack())],
                       folder: nil, transcripts: [tr])
    expect(off.captions.isEmpty, "and not when off")
    let edited = tr.editing(8, to: "polished").editing(1, to: "")
    expect(edited.words.count == said.count - 1 && edited.words[7].text == "polished", "a word is fixed, another dropped")
}

/// A short silent H.264 video (grey frames), for checks that need a real take.
func makeVideo(_ url: URL, seconds: Double, fps: Int32 = 10) async throws {
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 100])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 100])
    w.add(input)
    w.startWriting()
    w.startSession(atSourceTime: .zero)
    for i in 0..<Int(seconds * Double(fps)) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        guard let pb else { continue }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0x80, CVPixelBufferGetDataSize(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    await w.finishWriting()
}

await check("voice: the take's voice follows its clips in the edited asset") { dir in
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sentence = repo.appendingPathComponent("shared/fixtures/voice/sentence.m4a")
    guard FileManager.default.fileExists(atPath: sentence.path) else { expect(false, "voice fixture present"); return }
    let folder = dir.appendingPathComponent("v.reel")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await makeVideo(folder.appendingPathComponent("screen.mov"), seconds: 7)
    try FileManager.default.copyItem(at: sentence, to: folder.appendingPathComponent("voice.m4a"))
    var meta = RecordingMeta(pixelWidth: 160, pixelHeight: 100, pointScale: 1, duration: 7, source: "display")
    meta.voice = "voice.m4a"
    meta.voiceOffset = 0.5
    var p = Project(folder: folder, meta: meta, cursor: CursorTrack(), edit: EditDoc())
    var fast = Clip(start: 3, end: 5)
    fast.speed = 2
    p.edit.clips = [Clip(start: 0, end: 2), fast]
    try p.saveMeta(); try p.saveCursor(); try p.saveEdit()
    p = try Project.load(folder)
    expect(p.takes[0].voiceURL?.lastPathComponent == "voice.m4a", "the take knows its voice")
    try Transcript(words: [TranscriptWord(text: "Hi", start: 1, end: 1.3)]).save(folder)
    expect(try Project.load(folder).takes[0].transcript?.words.count == 1, "the first take's transcript loads with the project")
    let prepared = try await Composer.prepare(p)
    guard let comp = prepared.asset as? AVMutableComposition else { expect(false, "a composition"); return }
    let voiceTrack = comp.tracks(withMediaType: .audio).first { $0.trackID == 6 }
    expect(voiceTrack != nil, "a voice track")
    let segs = (voiceTrack?.segments ?? []).filter { !$0.isEmpty }
    let targets = segs.map { ($0.timeMapping.target.start.seconds, $0.timeMapping.target.end.seconds) }
    // Clip 1: voice from take 0.5 (file 0) to 2 -> output 0.5...2; clip 2: take 3...5 at 2x -> output 2...3.
    expect(targets.count == 2 && near(targets[0].0, 0.5, 0.01) && near(targets[0].1, 2, 0.01)
           && near(targets[1].0, 2, 0.01) && near(targets[1].1, 3, 0.01), "voice placed with its clips (\(targets))")
    expect(near(segs.last.map { $0.timeMapping.source.start.seconds } ?? 0, 2.5, 0.01), "the 2x clip's voice starts 2.5 s into the file")
}

if let file = ProcessInfo.processInfo.environment["MONETSHOT_GRID_FILE"] {
    // a look at a real song: MONETSHOT_GRID_FILE=song.mp3 swift run MonetShotChecks
    if let g = await MusicGrid.analyze(URL(fileURLWithPath: file)) {
        print(String(format: "grid: %.2f bpm, bar %.4f s, first downbeat %.3f s, lifts %@", g.bpm, g.bar, g.firstDownbeat, g.lifts.map { String(format: "%.2f", $0) }.joined(separator: " ")))
    } else { print("grid: none found") }
}

print(failures == 0 ? "All \(passed) checks passed" : "\(failures) failed, \(passed) passed")
exit(failures == 0 ? 0 : 1)
