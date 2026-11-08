import AppKit
import AVFoundation
import QuartzCore
import MonetShotKit
import SwiftUI

/// The webcam and microphone, for you on camera. One shared capture session:
/// the live preview (in the editor, or a bubble while the menu bar counts
/// down) and the recorded file come from the same capture.
@MainActor
final class CameraRecorder: NSObject {
    static let shared = CameraRecorder()

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "monetshot.camera")
    private let output = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var users = 0
    private var started: CheckedContinuation<Double?, Never>?
    private var finished: CheckedContinuation<URL?, Never>?

    /// "Record my camera too" for screen recordings, from the menu.
    static var withScreen: Bool {
        get { UserDefaults.standard.bool(forKey: "cameraWithScreen") }
        set { UserDefaults.standard.set(newValue, forKey: "cameraWithScreen") }
    }

    static var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                         mediaType: .video, position: .unspecified).devices
    }

    /// The chosen camera (remembered), else the system default.
    var device: AVCaptureDevice? { videoInput?.device }

    private static var savedID: String? {
        get { UserDefaults.standard.string(forKey: "cameraDevice") }
        set { UserDefaults.standard.set(newValue, forKey: "cameraDevice") }
    }

    /// Asks for camera and microphone (the first time only). The microphone
    /// is optional: without it the camera records silent.
    static func requestAccess() async -> Bool {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        return video
    }

    /// Starts the camera. Balance each successful call with `release()`.
    func acquire() async -> Bool {
        guard await Self.requestAccess() else {
            Log.error("camera: access denied")
            return false
        }
        if !configured { configure() }
        guard videoInput != nil else { return false }
        users += 1
        let s = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if !s.isRunning { s.startRunning() }
                c.resume()
            }
        }
        return session.isRunning
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0, !output.isRecording else { return }
        let s = session
        queue.async { if s.isRunning { s.stopRunning() } }
    }

    func use(_ camera: AVCaptureDevice) {
        Self.savedID = camera.uniqueID
        guard configured, let input = try? AVCaptureDeviceInput(device: camera) else { return }
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        if session.canAddInput(input) { session.addInput(input); videoInput = input }
        session.commitConfiguration()
    }

    /// Hears you through `mic` from now on (not mid-recording).
    func useMic(_ mic: AVCaptureDevice) {
        guard configured, !output.isRecording, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let input = try? AVCaptureDeviceInput(device: mic) else { return }
        session.beginConfiguration()
        for old in session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }) where old.device.hasMediaType(.audio) {
            session.removeInput(old)
        }
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let camera = Self.cameras.first { $0.uniqueID == Self.savedID } ?? AVCaptureDevice.default(for: .video)
        if let camera, let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
        // The microphone chosen in the menu, else the system's.
        if let mic = VoiceRecorder.chosen ?? AVCaptureDevice.default(for: .audio), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        Log.info("camera: \(videoInput?.device.localizedName ?? "none")")
    }

    var isRecording: Bool { output.isRecording }

    /// Records to `url`. Returns once the file has started, with that moment
    /// (`CACurrentMediaTime`), or nil if it couldn't start.
    func record(to url: URL) async -> Double? {
        guard session.isRunning, !output.isRecording else { return nil }
        try? FileManager.default.removeItem(at: url)
        return await withCheckedContinuation { c in
            started = c
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stops and returns the finished file.
    func stop() async -> URL? {
        guard output.isRecording else { return nil }
        return await withCheckedContinuation { c in
            finished = c
            output.stopRecording()
        }
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = CACurrentMediaTime()
        Task { @MainActor in
            started?.resume(returning: now)
            started = nil
            Log.info("camera recording: \(fileURL.lastPathComponent)")
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: (any Error)?) {
        // A file that finished with an error can still be whole (disk full aside).
        let ok = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { Log.error("camera recording: \(message)") }
            started?.resume(returning: nil)
            started = nil
            finished?.resume(returning: ok ? outputFileURL : nil)
            finished = nil
            if users == 0 {
                let s = session
                queue.async { if s.isRunning { s.stopRunning() } }
            }
        }
    }
}

/// The live camera, filling its frame.
struct CameraPreview: NSViewRepresentable {
    var mirror = true

    func makeNSView(context: Context) -> CameraPreviewView {
        let v = CameraPreviewView()
        v.preview.session = CameraRecorder.shared.session
        v.mirror = mirror
        return v
    }

    func updateNSView(_ v: CameraPreviewView, context: Context) { v.mirror = mirror }
}

final class CameraPreviewView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    var mirror = true { didSet { applyMirror() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        preview.videoGravity = .resizeAspectFill
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) { nil }

    private func applyMirror() {
        guard let c = preview.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = mirror
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
        applyMirror()
    }
}
