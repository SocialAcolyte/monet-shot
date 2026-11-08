import MonetShotKit
import SwiftUI

/// While editing a tall video: where phone apps put their own buttons and
/// words (the top and bottom bands), drawn faintly over the preview so you
/// can keep what matters clear of them. Never in the export.
struct SafeAreaGuides: View {
    let canvas: CGSize
    let shown: CGSize

    var body: some View {
        let safe = safeArea(canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
        let k = shown.width / canvas.width
        let r = CGRect(x: safe.minX * k, y: safe.minY * k, width: safe.width * k, height: safe.height * k)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: shown))
                p.addRoundedRect(in: r, cornerSize: CGSize(width: 6, height: 6))
            }
            .fill(Color.black.opacity(0.16), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
