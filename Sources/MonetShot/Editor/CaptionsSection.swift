import MonetShotKit
import SwiftUI

/// What you said, as words on the video: transcribe (on this Mac), the
/// Captions switch, and the transcript itself, a word at a time.
struct CaptionsSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        Section("Captions") {
            if model.voicedTakes.isEmpty && !model.hasTranscript {
                Hint("Choose a microphone in the menu bar before you record, and what you say can become captions.")
            } else {
                ToggleRow("Captions", isOn: Binding(get: { model.captionsOn }, set: { model.setCaptions($0) }))
                    .disabled(!model.hasTranscript)
                if let p = model.transcribing {
                    HStack(spacing: 10) {
                        ProgressView(value: p)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                        Button("Cancel", action: model.cancelTranscription)
                            .buttonStyle(PillButtonStyle())
                    }
                    Hint("Listening, on this Mac.")
                } else {
                    HStack(spacing: 8) {
                        Button { model.transcribe() } label: {
                            Label(model.hasTranscript ? "Transcribe again" : "Transcribe", systemImage: "waveform")
                        }
                        .buttonStyle(PillButtonStyle())
                        .fixedSize()
                        .disabled(model.voicedTakes.isEmpty)
                        Spacer(minLength: 0)
                        Picker("", selection: $model.language) {
                            Text("Automatic").tag("auto")
                            ForEach(model.speechLanguages, id: \.identifier) { l in
                                Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 130)
                        .help("The language spoken")
                    }
                }
                if let e = model.transcribeError { Hint("Couldn't transcribe: \(e).") }
                if model.hasTranscript {
                    TranscriptPanel(model: model)
                    HStack(spacing: 8) {
                        Button { model.copyTranscript() } label: { Label("Copy transcript", systemImage: "doc.on.doc") }
                            .buttonStyle(PillButtonStyle())
                        Spacer(minLength: 0)
                    }
                }
                ToggleRow("Transcribe after recording", isOn: $model.autoTranscribeOn)
                ToggleRow("Subtitles beside the export", isOn: $model.subtitlesOn)
            }
        }
        .task { if model.speechLanguages.isEmpty { model.speechLanguages = await Transcriber.languages() } }
    }
}

/// The words the video shows, in play order. Click one to hear it (the
/// playhead jumps there) and fix its spelling; clear it to drop it.
private struct TranscriptPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let words = model.captionWords
        let now = model.time
        ScrollView {
            FlowLayout(spacing: 1, lineSpacing: 3) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    let current = now >= w.start && now < w.end
                    Text(w.text)
                        .font(.system(size: 12, weight: current ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(current ? Palette.clay : Palette.moonWhite)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(model.editingWord == i ? Palette.midnight : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.seek(to: w.start + 0.01)
                            model.wordDraft = w.text
                            model.editingWord = i
                        }
                        .popover(isPresented: Binding(get: { model.editingWord == i }, set: { if !$0 { model.editingWord = nil } }), arrowEdge: .bottom) {
                            WordEditor(text: $model.wordDraft) {
                                model.editWord(take: w.take, index: w.index, to: model.wordDraft)
                                model.editingWord = nil
                            }
                        }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 190)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.charcoal.opacity(0.55)))
        Hint("Click a word to fix it; clear it to drop it.")
    }
}

private struct WordEditor: View {
    @Binding var text: String
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Word", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5, design: .rounded))
            .frame(width: 160)
            .focused($focused)
            .onSubmit(done)
            .padding(10)
            .onAppear { focused = true }
    }
}

/// Words left to right, wrapping like a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        let w = rows.map { $0.width }.max() ?? 0
        let h = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > width { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
