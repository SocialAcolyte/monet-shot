import AVFoundation
import MonetShotKit
import SwiftUI

/// The live camera over the preview while recording yourself: in its bubble,
/// exactly where the render will put it, or filling the frame for a clip of
/// just you. Counts in with big soft numerals.
struct CameraOverlay: View {
    let model: EditorModel
    /// Shown points per canvas pixel.
    let scale: CGFloat

    var body: some View {
        let r = model.renderer
        let look = model.doc.cameraLook
        ZStack {
            if model.cameraAlone {
                CameraPreview(mirror: look.mirror)
            } else {
                let b = r.bubbleRect
                let h = b.height * scale
                let shape = RoundedRectangle(cornerRadius: look.shape == .circle ? h / 2 : h * 0.2, style: .continuous)
                CameraPreview(mirror: look.mirror)
                    .frame(width: b.width * scale, height: h)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.96), lineWidth: max(1.5, h * 0.018)))
                    .shadow(color: .black.opacity(0.35), radius: h * 0.06, y: h * 0.03)
                    .position(x: b.midX * scale, y: (r.canvas.height - b.midY) * scale)
            }
            if case .countdown(let n) = model.cameraPhase {
                Text("\(n)")
                    .font(.system(size: 120, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 18)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.snappy(), value: n)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Replaces the transport while the camera is out.
struct CameraBar: View {
    let model: EditorModel

    private var recording: Bool {
        if case .recording = model.cameraPhase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.closeCamera) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(PillButtonStyle())
            .help("Put the camera away (Esc)")

            Picker("", selection: Binding(get: { model.cameraAlone }, set: { model.cameraAlone = $0 })) {
                Text("Over the video").tag(false)
                Text("Just me").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.cameraPhase != .ready)
            .help("Talk over the video as it plays, or record a clip of just you (added at the end)")

            Menu {
                ForEach(CameraRecorder.cameras, id: \.uniqueID) { cam in
                    Button(cam.localizedName) { CameraRecorder.shared.use(cam) }
                }
            } label: {
                Label(CameraRecorder.shared.device?.localizedName ?? "Camera", systemImage: "web.camera")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.moonWhite)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.midnight))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(model.cameraPhase != .ready)

            Spacer()

            status

            Button(action: model.toggleCameraRecording) {
                HStack(spacing: 7) {
                    if recording {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.white).frame(width: 10, height: 10)
                    } else {
                        Circle().fill(Color.white).frame(width: 10, height: 10)
                    }
                    Text(recording ? "Stop" : "Record")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(Capsule().fill(Palette.clay))
            }
            .buttonStyle(.plain)
            .disabled(model.cameraPhase == .saving)
            .help(recording ? "Stop (Space)" : "Start after a 3-second count (Space)")
        }
    }

    @ViewBuilder private var status: some View {
        switch model.cameraPhase {
        case .recording(let since):
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                HStack(spacing: 6) {
                    Circle().fill(Palette.clay).frame(width: 7, height: 7)
                    Text(TransportBar.stamp(ctx.date.timeIntervalSince(since)))
                        .monospacedDigit()
                }
            }
        case .countdown: Text("Get ready…")
        case .saving: Text("Saving…")
        default: Text(model.cameraAlone ? "Space to record a clip of you" : "Space to talk over the video from the playhead")
        }
    }
}
