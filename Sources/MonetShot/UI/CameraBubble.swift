import AppKit
import SwiftUI

/// A round window of you in the screen's corner while the menu bar counts
/// in a recording with the camera, so you can check your hair. It goes away
/// when recording starts: the recording would see it.
@MainActor
final class CameraBubble {
    private var panel: NSPanel?

    func show() {
        guard panel == nil, let screen = NSScreen.main else { return }
        let size: CGFloat = 200
        let frame = NSRect(x: screen.visibleFrame.maxX - size - 28, y: screen.visibleFrame.minY + 28, width: size, height: size)
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView:
            CameraPreview(mirror: true)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 3))
                .frame(width: size, height: size))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
