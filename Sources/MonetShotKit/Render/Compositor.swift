import AVFoundation
import CoreImage
import CoreVideo

/// Track IDs in the edited composition: the clips, then the two camera
/// tracks (clips recorded in the editor win over the take's own camera).
enum TrackID {
    static let screen: CMPersistentTrackID = 1
    static let overlay: CMPersistentTrackID = 2
    static let takeCamera: CMPersistentTrackID = 3
    static let overlayAudio: CMPersistentTrackID = 4
    static let takeCameraAudio: CMPersistentTrackID = 5
    static let takeVoice: CMPersistentTrackID = 6
}

/// The one instruction covering the whole video: which tracks to read and
/// the renderer to draw them with.
final class MonetShotInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let renderer: Renderer
    let cameras: [CMPersistentTrackID]

    init(timeRange: CMTimeRange, renderer: Renderer, cameras: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.renderer = renderer
        self.cameras = cameras
        requiredSourceTrackIDs = ([TrackID.screen] + cameras).map { NSNumber(value: $0) }
    }
}

/// Draws each frame with the renderer: the screen frame, and whichever
/// camera frame is there. (AVFoundation's CoreImage handler only ever sees
/// one track, hence a compositor of our own.)
final class MonetShotCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]
    let sourcePixelBufferAttributes: [String: any Sendable]? = MonetShotCompositor.bgra
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = MonetShotCompositor.bgra
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? MonetShotInstruction,
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "MonetShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "no instruction or buffer"]))
            return
        }
        let r = ins.renderer
        let t = request.compositionTime.seconds
        let screen = request.sourceFrame(byTrackID: TrackID.screen).map { CIImage(cvPixelBuffer: $0) }
            ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 9))
        var webcam: CIImage?
        var overlay = false
        for id in ins.cameras {
            if let b = request.sourceFrame(byTrackID: id) {
                webcam = CIImage(cvPixelBuffer: b)
                overlay = id == TrackID.overlay
                break
            }
        }
        let image = r.render(source: screen, webcam: webcam, overlay: overlay, at: t.isFinite ? t : 0)
        CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        Self.context.render(image, to: out, bounds: CGRect(origin: .zero, size: r.canvas), colorSpace: Self.space)
        request.finish(withComposedVideoFrame: out)
    }
}
