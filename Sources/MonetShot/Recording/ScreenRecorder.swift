import AppKit
import AVFoundation
import MonetShotKit
import ScreenCaptureKit

/// Records a display or a window to a new `.reel` folder.
///
/// The content is chosen in macOS's own sharing picker, which grants access
/// to just that content for this session: no Screen Recording permission is
/// needed (and an ad-hoc signed app would lose such a grant on every build).
/// The video is written by ScreenCaptureKit's `SCRecordingOutput` with the
/// system cursor hidden; `CursorTracker` logs the pointer alongside it.
@MainActor
final class ScreenRecorder: NSObject {
    enum Event {
        case pickerClosed
        case picked
        case started
        case paused(Bool)
        case finished(URL)
        /// A take recorded into an existing recording: its folder and the
        /// clips it brings (its own times, pauses already left out).
        case finishedTake(URL, [Clip])
        case failed(String)
    }

    var onEvent: (Event) -> Void = { _ in }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var tracker: CursorTracker?
    private var folder: URL?
    private var content: CGRect = .zero
    private var pixelSize: CGSize = .zero
    private var scale: Double = 2
    private var source = "display"
    private var stopRequestedAt: Double?
    /// Paused stretches so far, in recording time; they become cuts.
    private var pauses: [Cut] = []
    private var pausedAt: Double?
    var isPaused: Bool { pausedAt != nil }
    /// When set, the next recording becomes a new take of this recording
    /// instead of a recording of its own.
    var takeTarget: URL?
    private var recordingTake: URL?
    private let frameSink = FrameSink()
    /// When the camera file and the screen file started (CACurrentMediaTime).
    private var cameraStart: Double?
    private var screenStart: Double?
    private var observing = false

    // MARK: picking

    func pick() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay, .singleWindow]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "com.connorhood.monetshot"]
        config.allowsChangingSelectedContent = false
        picker.configuration = config
        if !observing { picker.add(self); observing = true }
        picker.isActive = true
        picker.present()
        Log.info("picker presented")
    }

    private func pickerDone() {
        SCContentSharingPicker.shared.isActive = false
    }

    // MARK: recording

    /// Called with the picked content; starts after the menu bar countdown.
    private var pendingFilter: SCContentFilter?

    func beginRecording() {
        guard let filter = pendingFilter else { return }
        pendingFilter = nil
        Task { await start(filter) }
    }

    func cancelPending() { pendingFilter = nil }

    private func start(_ filter: SCContentFilter) async {
        scale = Double(filter.pointPixelScale)
        if let window = filter.includedWindows.first {
            content = window.frame
            source = "window"
        } else if let display = filter.includedDisplays.first {
            content = display.frame
            source = "display"
        } else {
            content = filter.contentRect
            source = "display"
        }
        let size = filter.contentRect.size
        pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let config = SCStreamConfiguration()
        config.width = Int(pixelSize.width)
        config.height = Int(pixelSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false   // MonetShot draws its own, smoothed
        config.capturesAudio = false
        config.queueDepth = 6

        recordingTake = takeTarget
        takeTarget = nil
        let folder = recordingTake.flatMap { try? Project.load($0).nextTakeFolder() } ?? Project.newFolder()
        if recordingTake != nil && !folder.path.contains("/take-") { recordingTake = nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            onEvent(.failed("could not create \(folder.path): \(error.localizedDescription)"))
            return
        }
        self.folder = folder
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = folder.appendingPathComponent("screen.mov")
        rc.outputFileType = .mov
        rc.videoCodecType = rc.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            // A screen output keeps the stream's frame pipeline running; it drops every frame.
            try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameSink.queue)
            try stream.addRecordingOutput(output)
            let tracker = CursorTracker(content: content)
            tracker.onDoubleShift = { [weak self] in self?.togglePause() }
            tracker.start()
            pauses = []
            pausedAt = nil
            self.tracker = tracker
            self.stream = stream
            self.output = output
            stopRequestedAt = nil
            // You on camera too, if the menu says so (the menu bar warmed it up).
            cameraStart = nil
            screenStart = nil
            if CameraRecorder.withScreen, CameraRecorder.shared.session.isRunning {
                cameraStart = await CameraRecorder.shared.record(to: folder.appendingPathComponent("camera.mov"))
            }
            try await stream.startCapture()
            Log.info("capture started: \(source) \(Int(pixelSize.width))x\(Int(pixelSize.height)) @\(scale)x -> \(folder.lastPathComponent)")
        } catch {
            _ = tracker?.stop()
            tracker = nil
            self.stream = nil
            self.output = nil
            _ = await CameraRecorder.shared.stop()
            try? FileManager.default.removeItem(at: folder)
            onEvent(.failed("could not start recording: \(error.localizedDescription)"))
        }
    }

    /// Pausing keeps capturing (ScreenCaptureKit can't pause a file) and marks
    /// the stretch, which the editor then leaves out: each take becomes a clip.
    func togglePause() {
        guard stream != nil, let tracker else { return }
        let t = tracker.currentTime
        if let start = pausedAt {
            if t - start > 0.05 { pauses.append(Cut(start: start, end: t)) }
            pausedAt = nil
            Log.info(String(format: "resumed at %.1fs", t))
        } else {
            pausedAt = t
            Log.info(String(format: "paused at %.1fs", t))
        }
        onEvent(.paused(pausedAt != nil))
    }

    func stop() {
        guard let stream else { return }
        stopRequestedAt = output.map { $0.recordedDuration.seconds }
        Task {
            do { try await stream.stopCapture() } catch { Log.error("stopCapture: \(error)") }
        }
    }

    var isRecording: Bool { stream != nil }

    private func finish() {
        guard let folder, let tracker else { return }
        let track = tracker.stop()
        self.tracker = nil
        stream = nil
        let duration = output?.recordedDuration.seconds ?? track.samples.last?.t ?? 0
        output = nil
        var meta = RecordingMeta(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height),
                                 pointScale: scale, duration: duration, source: source)
        // Read the real duration from the file when it's there.
        let asset = AVURLAsset(url: folder.appendingPathComponent("screen.mov"))
        Task { @MainActor in
            if let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0 { meta.duration = d }
            if CameraRecorder.shared.isRecording, let cam = await CameraRecorder.shared.stop(),
               let cs = cameraStart, let ss = screenStart {
                meta.camera = cam.lastPathComponent
                meta.cameraOffset = cs - ss
                Log.info(String(format: "camera saved with the take, %.2fs offset", meta.cameraOffset))
            }
            var project = Project(folder: folder, meta: meta, cursor: track, edit: EditDoc())
            var cuts = pauses
            if let open = pausedAt { cuts.append(Cut(start: open, end: meta.duration)) }
            pausedAt = nil
            pauses = []
            project.edit.cuts = cuts.filter { $0.end > $0.start }
            let map = TimeMap(project.edit, duration: meta.duration)
            project.edit.segments = CameraMath.autoZooms(clicks: track.clicks.filter { map.keeps(take: 0, time: $0.t) }, duration: meta.duration)
            // Recording the screen means the hand travels up to the menu bar to
            // stop: end the edit just before it got there.
            if source == "display", let menuBar = NSScreen.screens.first.map({ 40 / $0.frame.height }),
               let last = CursorTracker.lastTimeBelowMenuBar(track.samples, end: meta.duration, menuBarFraction: menuBar),
               meta.duration - last < 6, last > 1 {
                project.edit.trimEnd = last
            }
            do {
                if let target = recordingTake {
                    recordingTake = nil
                    try Take(folder: folder, meta: meta, cursor: track).save()
                    Log.info("take saved: \(target.lastPathComponent)/\(folder.lastPathComponent) \(String(format: "%.1f", meta.duration))s")
                    onEvent(.finishedTake(target, project.clips))
                    return
                }
                try project.saveMeta(); try project.saveCursor(); try project.saveEdit()
                Log.info("recording saved: \(folder.lastPathComponent) \(String(format: "%.1f", meta.duration))s, \(track.samples.count) samples, \(track.clicks.count) clicks")
                onEvent(.finished(folder))
            } catch {
                onEvent(.failed("could not save the recording: \(error.localizedDescription)"))
            }
        }
    }
}

extension ScreenRecorder: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            Log.info("picker cancelled")
            pickerDone()
            onEvent(.pickerClosed)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let f = filter
        Task { @MainActor in
            guard self.stream == nil else { return }
            Log.info("picker chose content")
            pickerDone()
            pendingFilter = f
            onEvent(.picked)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            pickerDone()
            onEvent(.failed("the picker could not start: \(message)"))
        }
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            tracker?.markStart()
            screenStart = CACurrentMediaTime()
            Log.info("recording started")
            onEvent(.started)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            Log.error("recording failed: \(message)")
            if CameraRecorder.shared.isRecording { Task { _ = await CameraRecorder.shared.stop() } }
            _ = tracker?.stop()
            tracker = nil
            stream = nil
            output = nil
            onEvent(.failed(message))
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in finish() }
    }
}

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            Log.error("stream stopped: \(message)")
            // The recording output reports its own finish; only fail if it never started.
            if self.output == nil { onEvent(.failed(message)) }
        }
    }
}

/// Receives the stream's frames and drops them; the recording output does the writing.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "monetshot.frames", qos: .userInitiated)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
