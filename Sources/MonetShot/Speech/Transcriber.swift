import AVFoundation
import Foundation
import MonetShotKit
import Speech

/// Speech to text on this Mac, never leaving it: macOS 26's SpeechAnalyzer
/// (SpeechTranscriber with word timings), or the older on-device
/// SFSpeechRecognizer if that can't run. Words come back in the take's own
/// time (the voice file's time plus where it starts in the take).
enum Transcriber {
    enum Failure: Error, CustomStringConvertible {
        case noVoice, unreadable, language(String), denied
        var description: String {
            switch self {
            case .noVoice: "this take has no voice"
            case .unreadable: "couldn't read the voice"
            case .language(let l): "on-device speech doesn't know \(l)"
            case .denied: "speech recognition isn't allowed"
            }
        }
    }

    /// "auto" (the Mac's own language) or a language code, as chosen in the editor.
    static var language: String {
        get { UserDefaults.standard.string(forKey: "transcribeLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "transcribeLanguage") }
    }

    /// Transcribe automatically when a take with a voice opens without a transcript.
    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoTranscribe") }
    }

    /// The languages to offer: on-device speech's own, by code.
    static func languages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
    }

    /// Transcribes `take`'s voice, reporting 0...1. Cancel the calling task to stop.
    static func transcribe(_ take: Take, language: String = Transcriber.language,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Transcript {
        guard let url = take.voiceURL, FileManager.default.fileExists(atPath: url.path) else { throw Failure.noVoice }
        let offset = take.meta.voiceOffset ?? 0
        let (file, cleanup) = try await readable(url)
        defer { cleanup() }
        let want = language == "auto" ? Locale.current : Locale(identifier: language)
        var words: [TranscriptWord]
        var code = want.language.languageCode?.identifier
        do {
            let r = try await analyze(file, locale: want, progress: progress)
            words = r.words
            code = r.locale.language.languageCode?.identifier ?? code
            Log.info("transcribed with SpeechAnalyzer (\(r.locale.identifier)): \(words.count) words")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("SpeechAnalyzer: \(error); trying SFSpeechRecognizer")
            words = try await recognize(file.url, locale: want)
        }
        try Task.checkCancellation()
        let shifted = words.map { TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            .sorted { $0.start < $1.start }
        progress(1)
        return Transcript(words: shifted, language: code, engine: "apple")
    }

    /// The voice as a file AVAudioFile can read: as it is, or its sound
    /// copied out of a movie into a temporary .m4a.
    private static func readable(_ url: URL) async throws -> (AVAudioFile, () -> Void) {
        if let f = try? AVAudioFile(forReading: url) { return (f, {}) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("monetshot-voice-\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw Failure.unreadable }
        try await session.export(to: tmp, as: .m4a)
        guard let f = try? AVAudioFile(forReading: tmp) else { throw Failure.unreadable }
        return (f, { try? FileManager.default.removeItem(at: tmp) })
    }

    private struct Heard: Sendable {
        var words: [TranscriptWord]
        var locale: Locale
    }

    private static func analyze(_ file: AVAudioFile, locale want: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Heard {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: want) else {
            throw Failure.language(want.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.info("speech: downloading the \(locale.identifier) model")
            try await request.downloadAndInstall()
        }
        let length = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () throws -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words += Self.words(in: result.text)
                if length > 0 { progress(min(0.99, result.range.end.seconds / length)) }
            }
            return words
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            collect.cancel()
            throw error
        }
        let words = try await collect.value
        try Task.checkCancellation()
        return Heard(words: words, locale: locale)
    }

    /// Words from a result's runs: a run that doesn't start with a space
    /// (a word's second half, a comma) joins the word before it.
    static func words(in text: AttributedString) -> [TranscriptWord] {
        var out: [TranscriptWord] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let (start, end) = (range.start.seconds, range.end.seconds)
            if let last = out.last, !(piece.first?.isWhitespace ?? true) {
                out[out.count - 1] = TranscriptWord(text: last.text + trimmed, start: last.start, end: max(last.end, end))
            } else {
                // One run may hold several words; share its time between them.
                let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                let step = (end - start) / Double(parts.count)
                for (k, p) in parts.enumerated() {
                    out.append(TranscriptWord(text: p, start: start + Double(k) * step, end: start + Double(k + 1) * step))
                }
            }
        }
        return out
    }

    /// The older recogniser, kept on the device.
    private static func recognize(_ url: URL, locale: Locale) async throws -> [TranscriptWord] {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure.language(locale.identifier)
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        nonisolated(unsafe) var task: SFSpeechRecognitionTask?
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[TranscriptWord], Error>) in
                nonisolated(unsafe) var done = false
                task = recognizer.recognitionTask(with: request) { result, error in
                    guard !done else { return }
                    if let error { done = true; c.resume(throwing: error); return }
                    guard let result, result.isFinal else { return }
                    done = true
                    c.resume(returning: result.bestTranscription.segments.map {
                        TranscriptWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                }
            }
        } onCancel: {
            task?.cancel()
        }
    }
}
