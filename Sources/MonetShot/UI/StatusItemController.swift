import AppKit
import MonetShotKit
import SwiftUI

/// Owns the menu bar item. As in Insomnia, SwiftUI draws inside the bar
/// itself (no popover): a left click on the mark records, the stop ring is
/// held to stop, and a right click opens a plain menu.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: MenuBarModel
    private let host: StatusHostingView
    private let library: Library
    private let openHome: () -> Void

    init(model: MenuBarModel, library: Library, openHome: @escaping () -> Void) {
        self.model = model
        self.library = library
        self.openHome = openHome
        host = StatusHostingView(rootView: StatusRootView(model: model))
        super.init()
        seedPositionIfNeeded()
        item.autosaveName = "MonetShotStatusItem"
        item.behavior = [.terminationOnRemoval]
        host.sizingOptions = [.intrinsicContentSize]
        host.onRightMouseDown = { [weak self] in self?.showMenu() }
        if let button = item.button {
            button.title = ""
            (button.cell as? NSButtonCell)?.highlightsBy = []   // no grey flash
            button.addSubview(host)
            host.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                host.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            ])
        }
        relayout()
        observePhase()
        Task { @MainActor [item] in
            try? await Task.sleep(for: .seconds(1))
            Log.info("status item: visible \(item.isVisible) frame \(item.button?.window?.frame ?? .zero)")
        }
    }

    /// The item's width is written once per layout change (each write makes
    /// the whole menu bar re-lay out), never per frame.
    private func relayout() {
        let w = ceil(host.fittingSize.width)
        if abs(item.length - w) > 0.5 { item.length = w }
    }

    private func observePhase() {
        withObservationTracking {
            _ = model.phase
            _ = model.problem
        } onChange: { [weak self] in
            Task { @MainActor in
                // Let SwiftUI lay out the new phase first, then size the slot to it.
                try? await Task.sleep(for: .milliseconds(10))
                self?.relayout()
                self?.observePhase()
            }
        }
    }

    /// New items on notch Macs land in the hidden overflow; start near the clock.
    private func seedPositionIfNeeded() {
        let key = "NSStatusItem Preferred Position MonetShotStatusItem"
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(40, forKey: key) }
    }

    private func showMenu() {
        let menu = NSMenu()
        if model.isRecording {
            menu.addItem(item(model.paused ? "Resume" : "Pause", #selector(pause)))
            let hint = NSMenuItem(title: "Double-tap Shift to pause or resume", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            menu.addItem(item("Stop Recording", #selector(stop)))
        } else {
            menu.addItem(item("Record…", #selector(record)))
            let cam = item("Record My Camera Too", #selector(toggleCamera))
            cam.state = CameraRecorder.withScreen ? .on : .off
            menu.addItem(cam)
            let tall = item("Record Vertical", #selector(toggleVertical))
            tall.state = RecordLayout.vertical ? .on : .off
            menu.addItem(tall)
            menu.addItem(microphoneItem())
        }
        menu.addItem(item("Open Monet Shot", #selector(home), key: "o"))
        menu.addItem(.separator())
        let recent = library.recent(limit: 6)
        if !recent.isEmpty {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for url in recent {
                let i = item(Library.title(for: url), #selector(openRecent(_:)))
                i.representedObject = url
                menu.addItem(i)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item("Open Recording…", #selector(openOther)))
        menu.addItem(item("Show Recordings in Finder", #selector(reveal)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Monet Shot", #selector(quit), key: "q"))
        if let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func record() { model.tap() }
    @objc private func toggleCamera() { CameraRecorder.withScreen.toggle() }
    @objc private func toggleVertical() { RecordLayout.vertical.toggle() }

    /// "Microphone ▸ Off / each mic": your voice, with or without the camera.
    private func microphoneItem() -> NSMenuItem {
        let sub = NSMenu()
        let chosen = VoiceRecorder.chosen?.uniqueID
        let off = item("Off", #selector(chooseMic(_:)))
        off.state = chosen == nil ? .on : .off
        sub.addItem(off)
        for mic in VoiceRecorder.microphones {
            let i = item(mic.localizedName, #selector(chooseMic(_:)))
            i.representedObject = mic.uniqueID
            i.state = mic.uniqueID == chosen ? .on : .off
            sub.addItem(i)
        }
        let top = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        top.submenu = sub
        return top
    }

    @objc private func chooseMic(_ sender: NSMenuItem) {
        VoiceRecorder.choice = sender.representedObject as? String
        if let mic = VoiceRecorder.chosen { CameraRecorder.shared.useMic(mic) }
    }
    @objc private func home() { openHome() }
    @objc private func stop() { model.stopRecording() }
    @objc private func pause() { model.togglePause() }
    @objc private func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { model.openEditor(url) }
    }
    @objc private func openOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Project.libraryDir
        panel.message = "Choose a .reel recording"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { model.openEditor(url) }
    }
    @objc private func reveal() {
        try? FileManager.default.createDirectory(at: Project.libraryDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Project.libraryDir)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Forwards right and control clicks to the menu; everything else reaches SwiftUI.
final class StatusHostingView: NSHostingView<StatusRootView> {
    var onRightMouseDown: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) { onRightMouseDown?() }
    override func mouseDown(with event: NSEvent) {
        event.modifierFlags.contains(.control) ? onRightMouseDown?() : super.mouseDown(with: event)
    }
}

/// The recordings folder, newest first.
@MainActor
struct Library {
    func recent(limit: Int) -> [URL] {
        let dir = Project.libraryDir
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "reel" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit).map { $0 }
    }

    /// "18 Oct, 14.02" from "2026-10-18 14.02.11.reel".
    static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        guard let d = f.date(from: String(name.prefix(19))) else { return name }
        let out = DateFormatter()
        out.dateFormat = "d MMM, HH:mm"
        return out.string(from: d)
    }
}
