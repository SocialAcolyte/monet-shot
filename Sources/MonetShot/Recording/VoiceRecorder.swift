import AVFoundation
import MonetShotKit
import QuartzCore

/// Your voice without the camera: the chosen microphone into `voice.m4a`
/// beside the screen recording. Its own small capture session, so the
/// camera's stays as it was.
@MainActor
final class VoiceRecorder: NSObject {
    static let shared = VoiceRecorder()

    private let queue = DispatchQueue(label: "monetshot.voice")
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioFileOutput?
    private var started: CheckedContinuation<Double?, Never>?
    private var finished: CheckedContinuation<URL?, Never>?

    /// The microphone chosen in the menu (its uniqueID); nil = no voice.
    static var choice: String? {
        get { UserDefaults.standard.string(forKey: "micDevice") }
        set { UserDefaults.standard.set(newValue, forKey: "micDevice") }
    }

    static var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// The chosen microphone, if it's still plugged in.
    static var chosen: AVCaptureDevice? {
        guard let id = choice else { return nil }
        return microphones.first { $0.uniqueID == id }
    }

    var isRecording: Bool { output?.isRecording ?? false }

    /// Starts recording the chosen microphone into `url`. Returns the moment
    /// the file started (`CACurrentMediaTime`), or nil (no mic, no access).
    func record(to url: URL) async -> Double? {
        guard let mic = Self.chosen, !isRecording else { return nil }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            Log.error("voice: microphone access denied")
            return nil
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioFileOutput()
        guard let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input), session.canAddOutput(output) else {
            Log.error("voice: couldn't open \(mic.localizedName)")
            return nil
        }
        session.addInput(input)
        session.addOutput(output)
        output.audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000]
        self.session = session
        self.output = output
        nonisolated(unsafe) let running = session
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { running.startRunning(); c.resume() }
        }
        try? FileManager.default.removeItem(at: url)
        return await withCheckedContinuation { c in
            started = c
            output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        }
    }

    /// Stops and returns the finished file.
    func stop() async -> URL? {
        guard let output, output.isRecording else { tearDown(); return nil }
        return await withCheckedContinuation { c in
            finished = c
            output.stopRecording()
        }
    }

    private func tearDown() {
        nonisolated(unsafe) let s = session
        session = nil
        output = nil
        if s != nil { queue.async { s?.stopRunning() } }
    }
}

extension VoiceRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = CACurrentMediaTime()
        Task { @MainActor in
            started?.resume(returning: now)
            started = nil
            Log.info("voice recording: \(fileURL.lastPathComponent)")
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: (any Error)?) {
        let ok = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        let message = error?.localizedDescription
        Task { @MainActor in
            if let message { Log.error("voice recording: \(message)") }
            started?.resume(returning: nil)
            started = nil
            finished?.resume(returning: ok ? outputFileURL : nil)
            finished = nil
            tearDown()
        }
    }
}
