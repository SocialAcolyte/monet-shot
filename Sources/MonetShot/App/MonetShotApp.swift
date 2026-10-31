import AppKit
import MonetShotKit
import SwiftUI

/// Menu bar app. The bar item records; each finished recording opens in its
/// own editor window. The SwiftUI scene is the empty `Settings` that `App`
/// requires; every window is owned by AppKit here.
struct MonetShotApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MenuBarModel()
    private var statusItem: StatusItemController?
    private var editors: [URL: EditorWindow] = [:]
    private var home: HomeWindow?
    private var homeWasOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Paths.moveFromReel()
        Log.info("launched \(Bundle.main.bundleIdentifier ?? "unbundled")")
        model.openEditor = { [weak self] url in self?.open(url) }
        model.takeFinished = { [weak self] folder, clips in
            guard let self else { return }
            if let editor = editors[folder.standardizedFileURL] {
                editor.model.takeRecorded(clips: clips)
                editor.show()
            } else {
                open(folder)
            }
        }
        model.hideWindows = { [weak self] hide in
            self?.editors.values.forEach { hide ? $0.window.orderOut(nil) : $0.window.orderFront(nil) }
            if hide { self?.home?.window.orderOut(nil) } else if self?.home?.window.isVisible == false, self?.homeWasOpen == true { self?.home?.window.orderFront(nil) }
        }
        statusItem = StatusItemController(model: model, library: Library(), openHome: { [weak self] in self?.showHome() })
        let env = ProcessInfo.processInfo.environment
        if env["MONETSHOT_SNAPSHOT"] == nil && env["MONETSHOT_SNAPSHOT_BAR"] == nil && env["MONETSHOT_SNAPSHOT_HOME"] == nil {
            showHome()   // launched by hand (there's no login item): show the recordings
        }
        if let out = env["MONETSHOT_SNAPSHOT_HOME"] { snapshotHome(to: out) }
        if let out = ProcessInfo.processInfo.environment["MONETSHOT_SNAPSHOT"] { snapshot(to: out) }
        if let out = ProcessInfo.processInfo.environment["MONETSHOT_SNAPSHOT_BAR"] { snapshotBar(to: out) }
    }

    /// Developer aid: MONETSHOT_SNAPSHOT=<out.png> MONETSHOT_SNAPSHOT_OPEN=<rec.reel>
    /// [MONETSHOT_SNAPSHOT_TIME=<s>] [MONETSHOT_SNAPSHOT_SELECT=<index>] opens the
    /// editor, draws its window into a PNG and quits. The preview shows a
    /// rendered still, since an offscreen capture can't see a player layer.
    private func snapshot(to out: String) {
        let env = ProcessInfo.processInfo.environment
        guard let rec = env["MONETSHOT_SNAPSHOT_OPEN"] else { return }
        let url = URL(fileURLWithPath: rec).standardizedFileURL
        open(url)
        guard let editor = editors[url] else { exit(1) }
        let t = Double(env["MONETSHOT_SNAPSHOT_TIME"] ?? "") ?? 1
        // MONETSHOT_SNAPSHOT_SIZE=<w>x<h> to see more of the inspector.
        if let size = env["MONETSHOT_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            editor.window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Double(env["MONETSHOT_SNAPSHOT_WAIT"] ?? "") ?? 2.5))
            editor.model.seek(to: t)
            if let i = Int(env["MONETSHOT_SNAPSHOT_SELECT"] ?? ""), editor.model.doc.segments.indices.contains(i) {
                editor.model.select(editor.model.doc.segments[i].id)
            }
            if let i = Int(env["MONETSHOT_SNAPSHOT_CLIP"] ?? "") { editor.model.selectClip(i) }
            // MONETSHOT_SNAPSHOT_FRAMING=blur|crop opens framing (selecting the last blur).
            if let tool = env["MONETSHOT_SNAPSHOT_FRAMING"] {
                editor.model.openFraming(tool == "crop" ? .crop : .blur)
                if tool == "blur", let last = editor.model.doc.blurs.last { editor.model.selectBlur(last.id) }
            }
            if env["MONETSHOT_SNAPSHOT_MUSIC"] != nil {
                editor.model.openMusic()
                try? await Task.sleep(for: .seconds(2))
                if let first = editor.model.musicBrowser.tracks.dropFirst(2).first { editor.model.musicBrowser.togglePreview(first) }
                try? await Task.sleep(for: .seconds(4))
            }
            editor.model.stillFrame = try? await Composer.frame(editor.model.shownProject, at: t)
            try? await Task.sleep(for: .seconds(0.8))
            guard let view = editor.window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            Log.info("snapshot written: \(out)")
            exit(0)
        }
    }

    /// Developer aid: draws the menu bar item in each state, light and dark
    /// bars, into one PNG, then quits.
    private func snapshotBar(to out: String) {
        let demo = MenuBarModel()
        let states: [(MenuBarModel.Phase, Double, Bool)] = [
            (.idle, 0, false), (.countdown(2), 0, false), (.recording(since: Date().addingTimeInterval(-47)), 0, false),
            (.recording(since: Date().addingTimeInterval(-47)), 0, true),
            (.recording(since: Date().addingTimeInterval(-47)), 0.55, false), (.saving, 0, false),
        ]
        var rows: [NSImage] = []
        for dark in [false, true] {
            for (phase, hold, paused) in states {
                demo.debugShow(phase, hold: hold, paused: paused)
                let view = StatusRootView(model: demo)
                    .padding(.horizontal, 10)
                    .frame(width: 170, height: 26, alignment: .leading)
                    .background(dark ? Color(hex: 0x2A2A2C) : Color(hex: 0xECECEC))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: view)
                r.scale = 3
                if let img = r.nsImage { rows.append(img) }
            }
        }
        let w = rows.map(\.size.width).max() ?? 0, h = rows.reduce(0) { $0 + $1.size.height + 4 }
        let sheet = NSImage(size: NSSize(width: w * 2 + 8, height: h / 2 + 4))
        sheet.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        for (i, img) in rows.enumerated() {
            let col = i / states.count, row = i % states.count
            img.draw(at: NSPoint(x: CGFloat(col) * (w + 8), y: sheet.size.height - CGFloat(row + 1) * (img.size.height + 4)), from: .zero, operation: .sourceOver, fraction: 1)
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        exit(0)
    }

    func showHome() {
        if home == nil {
            let h = HomeWindow()
            h.model.open = { [weak self] url in self?.open(url) }
            h.model.record = { [weak self] in self?.model.tap() }
            h.onClose = { [weak self] in
                self?.homeWasOpen = false
                self?.settlePolicy()
            }
            home = h
        }
        homeWasOpen = true
        home?.show()
    }

    /// MonetShot shows in the Dock only while one of its windows is open.
    private func settlePolicy() {
        let anyOpen = !editors.isEmpty || home?.window.isVisible == true
        NSApp.setActivationPolicy(anyOpen ? .regular : .accessory)
    }

    /// Clicking MonetShot in Finder or the Dock while it runs shows the recordings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showHome() }
        return true
    }

    /// Developer aid: MONETSHOT_SNAPSHOT_HOME=<out.png> draws the home window and quits.
    private func snapshotHome(to out: String) {
        showHome()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard let view = home?.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }

    /// Double-clicked `.reel` packages in Finder land here.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.isRecording { model.stopRecording() }
        editors.values.forEach { $0.model.close() }
        Log.info("terminated")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func open(_ url: URL) {
        let key = url.standardizedFileURL
        if let existing = editors[key] { existing.show(); return }
        do {
            let project = try Project.load(key)
            let editor = EditorWindow(project: project)
            editor.model.onRecordTake = { [weak self] folder in self?.model.recordTake(into: folder) }
            editor.onClose = { [weak self] in
                self?.editors[key] = nil
                self?.home?.model.refresh()
                self?.settlePolicy()
            }
            editors[key] = editor
            editor.show()
        } catch {
            Log.error("open \(url.lastPathComponent): \(error)")
            let alert = NSAlert()
            alert.messageText = "MonetShot couldn't open that recording"
            alert.informativeText = "\(error)"
            NSApp.activate()
            alert.runModal()
        }
    }
}
