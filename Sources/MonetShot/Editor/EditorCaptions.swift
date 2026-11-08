import AppKit
import MonetShotKit

/// Captions in the editor: transcribing the takes' voices on this Mac,
/// the Captions switch, fixing a word, copying the transcript.
extension EditorModel {
    /// Write `<name>.srt` beside every export that has words.
    static var writeSubtitles: Bool {
        get { UserDefaults.standard.object(forKey: "writeSubtitles") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "writeSubtitles") }
    }

    /// Takes recorded with a voice.
    var voicedTakes: [Int] { project.takes.indices.filter { project.takes[$0].meta.voice != nil } }
    var hasTranscript: Bool { project.takes.contains { $0.transcript != nil } }
    var captionsOn: Bool { doc.captions == true }

    /// Every word the edit shows, in play order.
    var captionWords: [CaptionWord] { Captions.words(project.takes.map(\.transcript), map: renderer.map) }

    func setCaptions(_ on: Bool) {
        update { $0.captions = on }
        Log.info("captions \(on ? "on" : "off")")
    }

    /// After a recording with a voice: transcribe what hasn't been, if the setting says so.
    func autoTranscribe() {
        guard Transcriber.automatic else { return }
        let missing = voicedTakes.filter { project.takes[$0].transcript == nil }
        if !missing.isEmpty { transcribe(missing) }
    }

    /// Transcribes `takes` (all with a voice by default), one after another.
    func transcribe(_ takes: [Int]? = nil) {
        guard transcribing == nil else { return }
        let list = takes ?? voicedTakes
        guard !list.isEmpty else { return }
        transcribing = 0
        transcribeError = nil
        let language = Transcriber.language
        transcribeTask = Task { [weak self] in
            for (n, k) in list.enumerated() {
                guard let self, !Task.isCancelled, project.takes.indices.contains(k) else { break }
                let take = project.takes[k]
                let share = 1 / Double(list.count)
                do {
                    let t = try await Transcriber.transcribe(take, language: language) { p in
                        Task { @MainActor [weak self] in
                            if self?.transcribing != nil { self?.transcribing = (Double(n) + p) * share }
                        }
                    }
                    try t.save(take.folder)
                    setTranscript(t, take: k)
                    Log.info("transcript saved: take \(k + 1), \(t.words.count) words")
                } catch is CancellationError {
                    Log.info("transcription cancelled")
                    break
                } catch {
                    transcribeError = "\(error)"
                    Log.error("transcription: \(error)")
                    break
                }
            }
            self?.transcribing = nil
            self?.transcribeTask = nil
        }
    }

    func cancelTranscription() {
        transcribeTask?.cancel()
        transcribeTask = nil
        transcribing = nil
    }

    /// Spells word `index` of take `take`'s transcript `text`; empty removes it.
    func editWord(take: Int, index: Int, to text: String) {
        guard project.takes.indices.contains(take), let tr = project.takes[take].transcript else { return }
        let next = tr.editing(index, to: text)
        guard next != tr else { return }
        do { try next.save(project.takes[take].folder) } catch { Log.error("save transcript: \(error)") }
        setTranscript(next, take: take)
    }

    func copyTranscript() {
        let text = Captions.text(captionWords)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
