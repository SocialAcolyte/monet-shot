import SwiftUI

/// Everything drawn inside the menu bar item. Flat, no materials or blur:
/// every frame of this view is composited into the menu bar.
struct StatusRootView: View {
    let model: MenuBarModel

    private var reduce: Bool { Motion.reduceMotion }

    var body: some View {
        HStack(spacing: 6) {
            Aperture(recording: model.isRecording || model.phase == .saving,
                     busy: model.phase == .picking || model.phase == .starting,
                     paused: model.paused)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .onTapGesture { model.tap() }

            switch model.phase {
            case .countdown(let n):
                Pill {
                    Text("\(n)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Motion.tick(reduce), value: n)
                }
                .onTapGesture { model.cancel() }
                .transition(Motion.reveal(reduce))
            case .recording(let since):
                TimelineView(.periodic(from: since, by: 0.25)) { ctx in
                    let secs = model.elapsed(at: ctx.date)
                    Text(MenuBarModel.clock(secs))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(model.paused ? .secondary : .primary)   // the menu bar's own ink
                        .contentTransition(.numericText())
                        .animation(Motion.tick(reduce), value: Int(secs))
                }
                .transition(Motion.reveal(reduce))
                PauseButton(paused: model.paused, action: model.togglePause)
                    .transition(Motion.reveal(reduce))
                HoldRing(model: model)
                    .transition(Motion.reveal(reduce))
            case .saving:
                Text("Saving")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            default:
                if let problem = model.problem {
                    Text(problem)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .transition(.opacity.animation(Motion.base(reduce)))
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .animation(Motion.base(reduce), value: model.phase)
    }
}

/// MonetShot's mark: a lens ring with a pupil of a dot. At rest both are the menu
/// bar's own ink; recording, the dot fills the ring in clay.
struct Aperture: View {
    let recording: Bool
    let busy: Bool
    var paused = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(recording ? Palette.clay : Color.primary.opacity(busy ? 0.5 : 0.9), lineWidth: 1.5)
            // Paused, the pupil shrinks back to a dot: the take is waiting.
            Circle()
                .fill(recording ? Palette.clay : Color.primary.opacity(busy ? 0.5 : 0.9))
                .padding(recording && !paused ? 3.2 : 5)
                .opacity(paused ? 0.55 : 1)
        }
        .animation(Motion.base(), value: recording)
        .animation(Motion.base(), value: paused)
    }
}

/// Pause / resume. The paused stretch is cut from the video, so every
/// pause ends a clip and every resume starts the next.
struct PauseButton: View {
    let paused: Bool
    let action: () -> Void

    var body: some View {
        Image(systemName: paused ? "play.fill" : "pause.fill")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(paused ? Palette.clay : Color.primary.opacity(0.85))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 18, height: 18)
            .background(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1.6))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(paused ? "Resume (double-tap Shift)" : "Pause; the pause is cut out (double-tap Shift)")
    }
}

/// A flat charcoal pill, as Insomnia's duration fields.
struct Pill<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .foregroundStyle(Palette.moonWhite)
            .padding(.horizontal, 8)
            .frame(minWidth: 22)
            .frame(height: 19)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.charcoal.opacity(0.92)))
    }
}

/// Press and hold to stop: a ring draws round the square for 0.6 s; letting go
/// early or dragging away springs it back, so a stray click can't end a take.
struct HoldRing: View {
    let model: MenuBarModel
    private let size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: model.holdProgress)
                .stroke(Palette.violet, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.primary.opacity(0.85))
                .frame(width: 6, height: 6)
        }
        .frame(width: size, height: size)
        .scaleEffect(model.holding && !Motion.reduceMotion ? 1.12 : 1)
        .animation(Motion.snappy(), value: model.holding)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !model.holding && hypot(v.translation.width, v.translation.height) < 12 {
                        model.holdBegan()
                    } else if hypot(v.translation.width, v.translation.height) > 12 {
                        model.holdEnded()
                    }
                }
                .onEnded { _ in model.holdEnded() }
        )
        .help("Hold to stop recording")
    }
}
