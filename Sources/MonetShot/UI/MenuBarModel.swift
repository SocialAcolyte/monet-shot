import AppKit
import Observation
import MonetShotKit

/// The menu bar's state machine. Views read it; only its methods change it.
///
///   idle --click--> picking --chose--> countdown(3,2,1) --> starting --> recording
///   recording --hold the ring--> saving --> idle (editor opens)
///   picking/countdown --click--> idle
@MainActor
@Observable
final class MenuBarModel {
    enum Phase: Equatable {
        case idle
        case picking
        case countdown(Int)
        case starting
        case recording(since: Date)
        case saving
    }

    private(set) var phase: Phase = .idle
    /// 0...1 while the stop ring is held.
    private(set) var holdProgress: Double = 0
    private(set) var holding = false
    /// Paused mid-recording (the paused stretch will be cut).
    private(set) var paused = false
    /// Paused time so far, so the clock shows recorded time only.
    private(set) var pausedTotal: TimeInterval = 0
    private(set) var pausedSince: Date?
    /// A short message shown in the bar for a few seconds after a failure.
    private(set) var problem: String?

    @ObservationIgnored let recorder = ScreenRecorder()
    @ObservationIgnored var openEditor: (URL) -> Void = { _ in }
    /// A take recorded into an existing recording is ready.
    @ObservationIgnored var takeFinished: (URL, [Clip]) -> Void = { _, _ in }
    /// Editor windows step out of the way while the screen is recorded.
    @ObservationIgnored var hideWindows: (Bool) -> Void = { _ in }
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var holdTask: Task<Void, Never>?
    @ObservationIgnored private var problemTask: Task<Void, Never>?

    init() {
        recorder.onEvent = { [weak self] e in self?.handle(e) }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    /// A left click on the mark.
    func tap() {
        switch phase {
        case .idle:
            problem = nil
            phase = .picking
            recorder.pick()
        case .countdown:
            cancel()
        case .picking, .starting, .recording, .saving:
            break   // a recording only stops through the hold ring
        }
    }

    func cancel() {
        countdownTask?.cancel()
        if isCountingDown || phase == .starting { putCameraAway() }
        recorder.cancelPending()
        recorder.takeTarget = nil
        if phase == .picking || isCountingDown {
            phase = .idle
            hideWindows(false)
        }
    }

    /// Records a new take for the recording in `folder` (from its editor).
    func recordTake(into folder: URL) {
        guard phase == .idle else { return }
        recorder.takeTarget = folder
        tap()
    }

    /// Pause or resume (also double-tap Shift while recording).
    func togglePause() {
        guard isRecording else { return }
        recorder.togglePause()
    }

    /// Recorded time at `date`, not counting pauses.
    func elapsed(at date: Date) -> TimeInterval {
        guard case .recording(let since) = phase else { return 0 }
        return date.timeIntervalSince(since) - pausedTotal - (pausedSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    // MARK: hold to stop

    func holdBegan() {
        guard isRecording, !holding else { return }
        holding = true
        holdTask?.cancel()
        let start = Date()
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                let p = min(1, Date().timeIntervalSince(start) / Motion.holdDuration)
                self?.holdProgress = p
                if p >= 1 { self?.stopRecording(); return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func holdEnded() {
        guard holding else { return }
        holding = false
        holdTask?.cancel()
        if isRecording { holdProgress = 0 }
    }

    func stopRecording() {
        guard isRecording else { return }
        holding = false
        holdTask?.cancel()
        phase = .saving
        recorder.stop()
        Log.info("stop requested")
    }

    // MARK: recorder events

    private func handle(_ e: ScreenRecorder.Event) {
        switch e {
        case .pickerClosed:
            if phase == .picking { phase = .idle }
            recorder.takeTarget = nil
        case .picked:
            hideWindows(true)
            startCountdown()
            // Recording yourself too: see yourself while it counts in.
            if CameraRecorder.withScreen {
                Task {
                    guard await CameraRecorder.shared.acquire() else { return }
                    guard phase != .idle else { CameraRecorder.shared.release(); return }
                    cameraHeld = true
                    if isCountingDown { bubble.show() }
                }
            }
        case .started:
            bubble.hide()   // it would be in the recording
            phase = .recording(since: Date())
            holdProgress = 0
            paused = false
            pausedTotal = 0
            pausedSince = nil
        case .paused(let on):
            if on {
                pausedSince = Date()
            } else if let s = pausedSince {
                pausedTotal += Date().timeIntervalSince(s)
                pausedSince = nil
            }
            paused = on
        case .finishedTake(let folder, let clips):
            phase = .idle
            putCameraAway()
            paused = false
            holdProgress = 0
            hideWindows(false)
            takeFinished(folder, clips)
        case .finished(let folder):
            phase = .idle
            putCameraAway()
            paused = false
            hideWindows(false)
            holdProgress = 0
            openEditor(folder)
        case .failed(let message):
            Log.error(message)
            putCameraAway()
            hideWindows(false)
            phase = .idle
            holdProgress = 0
            show(problem: "Couldn't record")
        }
    }

    @ObservationIgnored private let bubble = CameraBubble()
    /// This model holds the camera (acquired for a recording with it).
    @ObservationIgnored private var cameraHeld = false

    private func putCameraAway() {
        bubble.hide()
        if cameraHeld {
            cameraHeld = false
            CameraRecorder.shared.release()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            for n in [3, 2, 1] {
                self?.phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let self else { return }
            phase = .starting
            recorder.beginRecording()
        }
    }

    private func show(problem text: String) {
        problem = text
        problemTask?.cancel()
        problemTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.problem = nil }
        }
    }

    /// Snapshot mode only: put the bar in a given state without recording.
    func debugShow(_ phase: Phase, hold: Double = 0, paused: Bool = false) {
        self.phase = phase
        self.paused = paused
        pausedSince = paused ? Date() : nil
        holdProgress = hold
        holding = hold > 0
    }

    /// The bar's elapsed-time text, "0:07" or "12:41".
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
