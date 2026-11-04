import AppKit
import MonetShotKit
import SwiftUI

/// One editor window per recording. While any editor is open MonetShot shows in
/// the Dock and the app switcher; when the last closes it goes back to being
/// a menu bar item only.
@MainActor
final class EditorWindow: NSObject, NSWindowDelegate {
    let model: EditorModel
    let window: NSWindow
    var onClose: () -> Void = {}
    private var keyMonitor: Any?

    init(project: Project) {
        model = EditorModel(project: project)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = model.title
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x17 / 255, green: 0x19 / 255, blue: 0x1B / 255, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 640)
        window.contentViewController = NSHostingController(rootView: EditorView(model: model))
        window.setFrameAutosaveName("MonetShotEditor")
        if window.frame.width < 980 { window.center() }
        window.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handleKey(e) ?? false } ? nil : e
        }
        Task { await model.load() }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.close()
        onClose()
    }

    /// Editor shortcuts; only while this window is key and no modifier but
    /// Shift is held (so ⌘-shortcuts reach the menus).
    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === window else { return false }
        // Typing in a field (the music search) keeps its keys.
        if window.firstResponder is NSText { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if mods == [.command], e.charactersIgnoringModifiers?.lowercased() == "z" {
            e.modifierFlags.contains(.shift) ? model.redo() : model.undo()
            return true
        }
        guard mods.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)
        // Recording yourself: space starts and stops, esc puts the camera away.
        if model.cameraPhase != .off {
            switch e.keyCode {
            case 49: model.toggleCameraRecording(); return true
            case 53: model.closeCamera(); return true
            default: return true
            }
        }
        // Framing: esc lets go of the box, then leaves; editing keys stay.
        if model.framing {
            switch e.keyCode {
            case 53:
                if model.selectedBlurID != nil { model.selectBlur(nil) } else { model.closeFraming() }
                return true
            case 49, 123, 124, 51, 117: break
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "b": model.closeFraming()
                case "r": model.frameTool = model.frameTool == .crop ? .blur : .crop
                default: break
                }
                return true
            }
        }
        switch e.keyCode {
        case 49: model.togglePlay(); return true                     // space
        case 123: model.step(frames: shift ? -60 : -1); return true  // ←
        case 124: model.step(frames: shift ? 60 : 1); return true    // →
        case 51, 117: model.deleteSelected(); return true            // delete, forward delete
        case 53: model.select(nil); model.selectClip(nil); return true   // esc
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "z": model.addZoom(); return true
        case "s": model.split(); return true
        case "m": model.openMusic(); return true
        case "a": model.reAuto(); return true
        case "c": model.openCamera(); return true
        case "b": model.openFraming(); return true
        case "t": model.addText(.title); return true
        default: return false
        }
    }
}
