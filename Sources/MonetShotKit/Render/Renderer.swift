import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Turns one frame of the raw recording into one frame of the finished
/// video: the backdrop, the recording framed with rounded corners and a
/// shadow, zoomed and panned by the camera, with MonetShot's own cursor and click
/// ripples on top. The preview and the export both call `render`, so what
/// you see while editing is exactly what you get.
public final class Renderer: @unchecked Sendable {
    public let doc: EditDoc
    public let canvas: CGSize
    /// Which clips play, in what order (output time -> take and take time).
    public let map: TimeMap
    let backdrop: CIImage
    let cursor: CIImage?
    let cursorTip: CGPoint
    /// Height of the arrow itself inside `cursor` (the image adds a margin).
    let cursorArtHeight: CGFloat
    let looks: [TakeLook]

    /// Everything that depends on one take: where it sits on the canvas
    /// (takes can differ in shape), its pointer, its clicks and its zooms.
    /// Pointer, clicks and zoom focus are in the cropped picture's own
    /// 0...1 coordinates; blurs stay in the whole frame's.
    struct TakeLook {
        let meta: RecordingMeta
        let crop: NormRect
        let blurs: [BlurRegion]
        /// Where the recording sits on the canvas (CoreImage coordinates:
        /// origin bottom-left, y up).
        let frameRect: CGRect
        /// Output pixels per screen point at 1x zoom.
        let pxPerPoint: CGFloat
        let cursorBaseHeight: CGFloat
        let hasCursor: Bool
        let clicks: [CursorSample]
        let cursorTrack: SmoothTrack
        let focusTrack: SmoothTrack
        let segments: [ZoomSegment]
        /// A wide take in a tall or square frame: the window that follows the action.
        let follow: FollowTrack?
        let mask: CIImage?
        let shadow: CIImage?

        /// The camera at the take's time `t`.
        func camera(at t: Double) -> Camera {
            follow?.camera(at: t, segments: segments) ?? CameraMath.camera(at: t, segments: segments, focus: focusTrack)
        }
    }

    public convenience init(project: Project) {
        self.init(doc: project.edit, takes: project.takes.map { ($0.meta, $0.cursor) }, folder: project.folder)
    }

    /// A single-take renderer (tests, and recordings with one take).
    public convenience init(doc: EditDoc, meta: RecordingMeta, cursor track: CursorTrack, folder: URL? = nil) {
        self.init(doc: doc, takes: [(meta, track)], folder: folder)
    }

    /// `folder` is where an `.image` backdrop's file lives (the .reel folder).
    public init(doc: EditDoc, takes: [(meta: RecordingMeta, cursor: CursorTrack)], folder: URL?) {
        self.doc = doc
        let first = takes.first?.meta ?? RecordingMeta(pixelWidth: 1920, pixelHeight: 1080, pointScale: 1, duration: 1, source: "display")
        map = TimeMap(doc, duration: first.duration)
        let size = doc.canvasSize(recordingAspect: first.aspect)
        let canvas = CGSize(width: size.width, height: size.height)
        self.canvas = canvas
        let framed = doc.backdrop != .none
        let pad = framed ? CGFloat(doc.padding) * min(canvas.width, canvas.height) : 0
        let room = CGRect(origin: .zero, size: canvas).insetBy(dx: pad, dy: pad)

        looks = takes.enumerated().map { index, take in
            let meta = take.meta
            let crop = doc.crop(take: index)
            let aspect = CGFloat(meta.aspect * crop.w / crop.h)
            // Vertical and square: a wider take fills the room, seen through a window.
            let follows = doc.followsAction && FollowFraming.window(takeAspect: Double(aspect), frameAspect: Double(room.width / room.height)) != nil
            var fw = room.width, fh = room.width / aspect
            if follows { fh = room.height } else if fh > room.height { fh = room.height; fw = fh * aspect }
            let frame = CGRect(x: (room.midX - fw / 2).rounded(), y: (room.midY - fh / 2).rounded(),
                               width: fw.rounded(), height: fh.rounded())
            let window = follows ? FollowFraming.window(takeAspect: Double(aspect), frameAspect: Double(frame.width / frame.height)) : nil
            let ppp = window != nil
                ? frame.height / (CGFloat(meta.pixelHeight) * CGFloat(crop.h) / CGFloat(max(meta.pointScale, 1)))
                : frame.width / (CGFloat(meta.pixelWidth) * CGFloat(crop.w) / CGFloat(max(meta.pointScale, 1)))
            let radius = framed ? CGFloat(doc.cornerRadius) * min(frame.width, frame.height) : 0
            let mask: CIImage? = radius > 0.5 ? CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: frame), "inputRadius": radius, "inputColor": CIColor.white,
            ])?.outputImage : nil
            var shadow: CIImage?
            if framed && doc.shadow {
                let blur = 0.035 * min(canvas.width, canvas.height)
                shadow = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                    "inputExtent": CIVector(cgRect: frame), "inputRadius": max(radius, 1),
                    "inputColor": CIColor(red: 0.05, green: 0.04, blue: 0.03, alpha: doc.backdrop == .paper ? 0.30 : 0.55),
                ])?.outputImage?
                    .transformed(by: CGAffineTransform(translationX: 0, y: -blur * 0.45))
                    .applyingGaussianBlur(sigma: blur)
                    .cropped(to: CGRect(origin: .zero, size: canvas))
            }
            func local(_ s: CursorSample) -> CursorSample {
                let p = crop.local(s.x, s.y)
                return CursorSample(t: s.t, x: p.x, y: p.y)
            }
            let samples = crop.isFull ? take.cursor.samples : take.cursor.samples.map(local)
            let segments = doc.segments.filter { $0.take == index }.map { seg in
                var z = seg
                if let fx = seg.focusX, let fy = seg.focusY {
                    let p = crop.local(fx, fy)
                    z.focusX = p.x; z.focusY = p.y
                }
                return z
            }
            let focusTrack = SmoothTrack.make(from: samples, duration: meta.duration, omega: CameraMath.cameraOmega)
            return TakeLook(
                meta: meta, crop: crop, blurs: doc.blurs.filter { $0.take == index },
                frameRect: frame, pxPerPoint: ppp,
                cursorBaseHeight: CGFloat(CursorArt.pointHeight * doc.cursorScale) * ppp,
                hasCursor: !take.cursor.samples.isEmpty,
                clicks: crop.isFull ? take.cursor.clicks : take.cursor.clicks.map(local),
                cursorTrack: SmoothTrack.make(from: samples, duration: meta.duration,
                                              omega: CameraMath.cursorOmega(smoothing: doc.cursorSmoothing)),
                focusTrack: focusTrack,
                segments: segments,
                follow: window.map { FollowTrack.make(window: $0, segments: segments, focus: focusTrack, duration: meta.duration) },
                mask: mask, shadow: shadow)
        }

        let picture = doc.backdrop == .image
            ? doc.backdropImage.flatMap { name in folder.flatMap { BackdropImages.load($0.appendingPathComponent(name)) } }
            : nil
        backdrop = Renderer.backdrop(doc.backdrop, size: canvas, picture: picture, blur: doc.backdropBlur)
        // Cursor art drawn once, big enough for a 2.5x zoom of the biggest take.
        let base = looks.map(\.cursorBaseHeight).max() ?? 40
        let artHeight = Int(min(512, max(24, base * 2.5)).rounded())
        cursorArtHeight = CGFloat(artHeight)
        if let art = CursorArt.image(style: doc.cursorStyle, tint: doc.cursorTint, label: doc.cursorLabel, pixelHeight: artHeight) {
            cursor = CIImage(cgImage: art.image)
            // CoreImage puts the image's origin bottom-left: flip the tip's y.
            cursorTip = CGPoint(x: art.tip.x, y: CGFloat(art.image.height) - art.tip.y)
        } else {
            cursor = nil
            cursorTip = .zero
        }
    }

    private func look(_ take: Int) -> TakeLook? { looks.indices.contains(take) ? looks[take] : looks.first }

    /// Where take `take` sits on the canvas.
    public func frameRect(take: Int = 0) -> CGRect { look(take)?.frameRect ?? .zero }

    /// The part of take `take` that is framed (the whole frame if uncropped).
    public func crop(take: Int) -> NormRect { look(take)?.crop ?? .full }

    /// The camera in take `take` at that take's time `time`. Its centre and
    /// viewport are in the cropped picture's coordinates: `crop(take:).global`
    /// turns them back into the whole frame's.
    public func camera(take: Int, time: Double) -> Camera {
        guard let l = look(take) else { return .identity }
        return l.camera(at: time)
    }

    /// The camera at output time `t`.
    public func camera(at t: Double) -> Camera {
        let p = map.locate(t)
        return camera(take: p.take, time: p.time)
    }

    /// One finished frame at output time `t`. `source` is the frame of the
    /// clip playing then, as decoded (pixel-sized, extent at the origin).
    public func render(source: CIImage, at t: Double) -> CIImage {
        let p = map.locate(t)
        return render(source: source, take: p.take, time: p.time)
    }

    /// One finished frame from take `take` at its own time `time`.
    public func render(source: CIImage, take: Int, time: Double) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        guard let l = look(take) else { return backdrop }
        let frameRect = l.frameRect
        let cam = l.camera(at: time)
        let source = Renderer.framed(Renderer.obscure(source, l.blurs, at: time), crop: l.crop)
        let src = source.extent
        let pw = src.width, ph = src.height
        let v = cam.viewport
        let crop = CGRect(x: src.minX + CGFloat(v.x) * pw, y: src.minY + CGFloat(1 - v.y - v.h) * ph,
                          width: CGFloat(v.w) * pw, height: CGFloat(v.h) * ph)
        let k = frameRect.width / crop.width
        // Large shrinks go through Lanczos first so fine text doesn't alias.
        // Then sample past the edges as the edge colour, so resampling never
        // pulls transparent black into the frame's border.
        let place = CGAffineTransform(translationX: frameRect.minX, y: frameRect.minY)
        let scaled: CIImage
        if k < 0.75 {
            scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
                .clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -crop.minX * k, y: -crop.minY * k).concatenating(place))
        } else {
            scaled = source.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                    .concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(place))
        }
        var content = scaled.cropped(to: frameRect)

        if doc.cursorVisible, l.hasCursor, let cursor {
            content = drawCursor(cursor, over: content, look: l, camera: cam, time: time)
        }
        if let mask = l.mask {
            content = content.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
            ])
        }
        var out = backdrop
        if let shadow = l.shadow { out = shadow.composited(over: out) }
        return content.composited(over: out).cropped(to: canvasRect)
    }

    /// The raw frame with every blur showing at take time `time` drawn into it.
    /// Each box is blurred from its own pixels only, so nothing sharp from
    /// around it bleeds in, and the result is cut back to the box.
    public static func obscure(_ image: CIImage, _ blurs: [BlurRegion], at time: Double) -> CIImage {
        let e = image.extent
        var out = image
        for b in blurs where b.covers(time) {
            let r = CGRect(x: e.minX + CGFloat(b.rect.x) * e.width, y: e.minY + CGFloat(1 - b.rect.maxY) * e.height,
                           width: CGFloat(b.rect.w) * e.width, height: CGFloat(b.rect.h) * e.height)
                .integral.intersection(e)
            guard r.width >= 1, r.height >= 1 else { continue }
            let short = min(e.width, e.height)
            let k = CGFloat(min(max(b.strength, 0), 1))
            let inside = image.cropped(to: r).clampedToExtent()
            let patch: CIImage
            switch b.style {
            case .blur:
                // Two passes: a wide blur, then a softer one over it, so even
                // heavy type turns to haze rather than ghosted letters.
                let sigma = (0.006 + 0.03 * k) * short
                patch = inside.applyingGaussianBlur(sigma: sigma).clampedToExtent().applyingGaussianBlur(sigma: sigma * 0.5)
            case .pixelate:
                patch = inside.applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(4, (0.008 + 0.035 * k) * short),
                    kCIInputCenterKey: CIVector(x: r.minX, y: r.maxY),
                ])
            case .solid:
                patch = CIImage(color: CIColor(red: 0.09, green: 0.10, blue: 0.11))
            }
            out = patch.cropped(to: r).composited(over: out)
        }
        return out
    }

    /// The kept part of the raw frame, moved to the origin.
    public static func framed(_ image: CIImage, crop: NormRect) -> CIImage {
        guard !crop.isFull else { return image }
        let e = image.extent
        let r = CGRect(x: e.minX + CGFloat(crop.x) * e.width, y: e.minY + CGFloat(1 - crop.maxY) * e.height,
                       width: CGFloat(crop.w) * e.width, height: CGFloat(crop.h) * e.height)
            .integral.intersection(e)
        guard r.width >= 2, r.height >= 2 else { return image }
        return image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    private func drawCursor(_ art: CIImage, over content: CIImage, look l: TakeLook, camera cam: Camera, time: Double) -> CIImage {
        var out = content
        let zoom = CGFloat(cam.scale)
        let frameRect = l.frameRect
        func place(_ x: Double, _ y: Double) -> CGPoint {
            let p = cam.project(x: x, y: y)
            return CGPoint(x: frameRect.minX + CGFloat(p.x) * frameRect.width,
                           y: frameRect.maxY - CGFloat(p.y) * frameRect.height)
        }
        if doc.clickRipple {
            for r in CameraMath.ripples(clicks: l.clicks, at: time) {
                let at = place(r.click.x, r.click.y)
                let grow = 1 - pow(1 - r.progress, 3)
                let radius = (9 + 24 * grow) * l.pxPerPoint * zoom * CGFloat(doc.cursorScale) / 1.5
                let alpha = 0.85 * (1 - r.progress)
                out = ring(center: at, radius: radius, alpha: alpha, tint: doc.cursorStyle.tinted ? doc.cursorTint.hex : nil).composited(over: out)
            }
        }
        let p = l.cursorTrack.position(at: time)
        let tip = place(p.x, p.y)
        let height = l.cursorBaseHeight * zoom * CGFloat(CameraMath.pressScale(clicks: l.clicks, at: time))
        let s = height / cursorArtHeight
        let scaled = art.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
        // Lanczos scales about the origin: move the scaled tip onto the pointer.
        let placed = scaled.transformed(by: CGAffineTransform(translationX: tip.x - cursorTip.x * s, y: tip.y - cursorTip.y * s))
        return placed.composited(over: out).cropped(to: frameRect)
    }

    /// A soft ring in Insomnia's blue-grey: an outer glow with its middle cut out.
    private func ring(center: CGPoint, radius: CGFloat, alpha: Double, tint: UInt32? = nil) -> CIImage {
        let c = CIVector(x: center.x, y: center.y)
        let hex = tint ?? 0xA6BBC3
        let r = CGFloat((hex >> 16) & 0xFF) / 255, g = CGFloat((hex >> 8) & 0xFF) / 255, b = CGFloat(hex & 0xFF) / 255
        let color = CIColor(red: r, green: g, blue: b, alpha: alpha)
        let clear = CIColor(red: r, green: g, blue: b, alpha: 0)
        guard
            let outer = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": radius * 0.78, "inputRadius1": radius,
                "inputColor0": color, "inputColor1": clear,
            ])?.outputImage,
            let inner = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": radius * 0.55, "inputRadius1": radius * 0.78,
                "inputColor0": CIColor.white, "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            ])?.outputImage
        else { return .empty() }
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return outer.cropped(to: box)
            .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner.cropped(to: box)])
    }

    /// The canvas behind the recording.
    static func backdrop(_ b: Backdrop, size: CGSize, picture: CIImage? = nil, blur: Double = 0) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        func rgb(_ hex: UInt32) -> CIColor {
            CIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255)
        }
        func gradient(_ a: UInt32, _ b: UInt32, from p0: CGPoint, to p1: CGPoint) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: p0), "inputPoint1": CIVector(cgPoint: p1),
                "inputColor0": rgb(a), "inputColor1": rgb(b),
            ])?.outputImage?.cropped(to: rect) ?? CIImage(color: rgb(a)).cropped(to: rect)
        }
        let base: CIImage
        switch b {
        case .paper:
            base = CIImage(color: rgb(0xF3F0E8)).cropped(to: rect)
        case .charcoal:
            base = gradient(0x17191B, 0x303336, from: .zero, to: CGPoint(x: size.width * 0.3, y: size.height))
        case .dusk:
            base = gradient(0x2B211C, 0xB8694A, from: CGPoint(x: size.width, y: 0), to: CGPoint(x: 0, y: size.height))
        case .slate:
            base = gradient(0x252C30, 0x6E8088, from: CGPoint(x: size.width * 0.8, y: 0), to: CGPoint(x: size.width * 0.1, y: size.height))
        case .none:
            return CIImage(color: rgb(0x000000)).cropped(to: rect)
        case .image:
            guard let picture else { return backdrop(.charcoal, size: size) }
            // Fill the canvas (cropping the overflow), centred.
            let e = picture.extent
            let k = max(size.width / e.width, size.height / e.height)
            var img = picture
                .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: (size.width - e.width * k) / 2,
                                                   y: (size.height - e.height * k) / 2))
            if blur > 0.01 {
                img = img.clampedToExtent().applyingGaussianBlur(sigma: blur * 0.03 * min(size.width, size.height))
            }
            return img.cropped(to: rect)
        }
        // A fine, still grain, so flat colour reads as a surface, not a fill:
        // noise mapped to a narrow band just under white, multiplied in, so
        // it can only darken a pixel by a few percent.
        let depth: CGFloat = b == .paper ? 0.045 : 0.03
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return base }
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: depth, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: depth, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: depth, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 1 - depth, y: 1 - depth, z: 1 - depth, w: 1),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
            .cropped(to: rect)
        return grain.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: base])
    }
}

/// Backdrop pictures, decoded once per file version and shared by every
/// renderer (the editor makes a new renderer on each edit).
public enum BackdropImages {
    nonisolated(unsafe) private static var cache: [String: CIImage] = [:]
    private static let lock = NSLock()

    public static func load(_ url: URL) -> CIImage? {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(stamp)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let img = CIImage(cgImage: cg)
        cache[key] = img
        return img
    }
}

// MARK: camera

extension Renderer {
    /// Where the camera bubble sits on the canvas (CoreImage coordinates).
    public var bubbleRect: CGRect {
        let look = doc.cameraLook
        let short = min(canvas.width, canvas.height)
        let m = (0.045 * short).rounded()
        let right = look.corner == .bottomRight || look.corner == .topRight
        let bottom = look.corner == .bottomRight || look.corner == .bottomLeft
        if doc.canvasLayout == .vertical {
            // On a phone: bigger, and inside the safe area: a bottom corner sits
            // in the lower third, above the band captions use; a top one under its top.
            let shape: CGFloat = look.shape == .circle ? 1 : 4.0 / 3.0
            let h = min((CGFloat(look.size) * Renderer.phoneBubble * short).rounded(), ((canvas.width - 2 * m) / shape).rounded(.down))
            let w = look.shape == .circle ? h : (h * 4 / 3).rounded()
            let safe = safeArea(canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
            let top = bottom ? CGFloat(safe.maxY) - (CGFloat(SafeArea.captionBand) * canvas.height).rounded() - h : CGFloat(safe.minY)
            return CGRect(x: right ? canvas.width - m - w : m, y: canvas.height - top - h, width: w, height: h)
        }
        let h = (CGFloat(look.size) * short).rounded()
        let w = look.shape == .circle ? h : (h * 4 / 3).rounded()
        return CGRect(x: right ? canvas.width - m - w : m, y: bottom ? m : canvas.height - m - h, width: w, height: h)
    }

    /// How much bigger the camera bubble is in the vertical layout.
    public static let phoneBubble: Double = 1.5

    /// One finished frame with you on camera over it. `overlay` says the
    /// camera frame came from a clip recorded in the editor (which may fill
    /// the frame and fades at its ends) rather than with the take.
    public func render(source: CIImage, webcam: CIImage?, overlay: Bool, at t: Double) -> CIImage {
        let out = render(source: source, at: t)
        guard doc.cameraLook.visible, let webcam else { return finished(out, at: t) }
        var full = false, presence = 1.0
        if overlay, let c = doc.cameraClips.first(where: { $0.covers(t) }) {
            full = c.full
            presence = CameraEdits.presence(c, at: t)
        }
        guard presence > 0.001 else { return finished(out, at: t) }
        return finished(drawWebcam(webcam, over: out, full: full, presence: presence, take: map.locate(t).take), at: t)
    }

    /// The last layers: a fading clip's veil, then the texts over everything.
    func finished(_ frame: CIImage, at t: Double) -> CIImage {
        withTexts(fadedIn(frame, at: t), at: t)
    }

    /// Every text showing at output time `t`, in list order (later on top).
    func withTexts(_ frame: CIImage, at t: Double) -> CIImage {
        var out = frame
        for o in doc.overlays {
            guard let st = TextMotion.state(Renderer.inSafeArea(o, width: canvas.width, height: canvas.height), at: t, width: canvas.width, height: canvas.height), st.opacity > 0.001,
                  let art = TextArt.image(st, tone: o.tone, backing: o.hasBacking) else { continue }
            let s = CGFloat(st.scale)
            let w = CGFloat(art.width) * s, h = CGFloat(art.height) * s
            // Centred on the state's centre (top-left canvas pixels; CoreImage is y-up).
            var img = CIImage(cgImage: art.image)
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: CGFloat(st.centerX) - w / 2, y: canvas.height - CGFloat(st.centerY) - h / 2))
            if st.opacity < 0.999 {
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(st.opacity), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(st.opacity), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(st.opacity), w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(st.opacity)),
                ])
            }
            out = img.composited(over: out)
        }
        return out.cropped(to: CGRect(origin: .zero, size: canvas))
    }

    /// On a tall canvas, a text's place (0...1 across the canvas) is taken
    /// as a place inside the safe area, so phone apps' buttons never cover it.
    public static func inSafeArea(_ o: TextOverlay, width: Double, height: Double) -> TextOverlay {
        guard SafeArea.isInset(canvasWidth: width, canvasHeight: height) else { return o }
        let safe = safeArea(canvasWidth: width, canvasHeight: height)
        var out = o
        out.x = (Double(safe.minX) + o.x * Double(safe.width)) / width
        out.y = (Double(safe.minY) + o.y * Double(safe.height)) / height
        return out
    }

    /// While a clip fades in or out, the finished frame dissolves into the
    /// backdrop: the backdrop laid back over it at `1 - presence`.
    func fadedIn(_ frame: CIImage, at t: Double) -> CIImage {
        let p = map.presence(t)
        guard p < 0.999 else { return frame }
        let veil = backdrop.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)])
        return veil.composited(over: frame).cropped(to: CGRect(origin: .zero, size: canvas))
    }

    private func drawWebcam(_ webcam: CIImage, over out: CIImage, full: Bool, presence: Double, take: Int) -> CIImage {
        var cam = webcam
        let e = cam.extent
        if doc.cameraLook.mirror {
            cam = cam.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.minX + e.maxX, ty: 0))
        }
        func fill(_ rect: CGRect) -> CIImage {
            let e = cam.extent
            let k = max(rect.width / e.width, rect.height / e.height)
            return cam.transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: rect.midX - e.midX * k, y: rect.midY - e.midY * k))
                .cropped(to: rect)
        }
        func shape(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
            CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: rect), "inputRadius": radius, "inputColor": color,
            ])?.outputImage ?? CIImage.empty()
        }
        func fade(_ image: CIImage) -> CIImage {
            presence >= 0.999 ? image : image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: presence)])
        }

        if full {
            let rect = frameRect(take: take)
            var layer = fill(rect)
            let radius = doc.backdrop != .none ? CGFloat(doc.cornerRadius) * min(rect.width, rect.height) : 0
            if radius > 0.5 {
                layer = layer.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: shape(rect, radius: radius, color: .white),
                ])
            }
            return fade(layer).composited(over: out)
        }

        // The bubble grows in a little as it fades in.
        let base = bubbleRect
        let grow = 0.86 + 0.14 * presence
        let rect = CGRect(x: base.midX - base.width * grow / 2, y: base.midY - base.height * grow / 2,
                          width: base.width * grow, height: base.height * grow)
        let radius = doc.cameraLook.shape == .circle ? rect.height / 2 : rect.height * 0.2
        let rim = max(2, rect.height * 0.018)
        let mask = shape(rect, radius: radius, color: .white)
        let face = fill(rect).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        let ring = shape(rect.insetBy(dx: -rim, dy: -rim), radius: radius + rim, color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.96))
        let shadow = shape(rect.offsetBy(dx: 0, dy: -rect.height * 0.03), radius: radius,
                           color: CIColor(red: 0.04, green: 0.03, blue: 0.02, alpha: 0.38))
            .applyingGaussianBlur(sigma: rect.height * 0.045)
        return fade(face.composited(over: ring).composited(over: shadow)).composited(over: out)
            .cropped(to: CGRect(origin: .zero, size: canvas))
    }
}
