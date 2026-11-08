import AppKit
import Foundation
import MonetShotKit

/// One-shot modes that print and exit without starting the UI. They run the
/// same renderer as the editor, so a recording can be checked or exported
/// from a script:
///   MonetShot --auto   <rec.reel>                  replace auto zooms from the clicks
///   MonetShot --frame  <rec.reel> <seconds> <out.png>
///   MonetShot --render <rec.reel> <out.mp4>
///   MonetShot --format <rec.reel> <clean|fast|melancholic|cinematic>
///   MonetShot --version
enum CommandLineMode {
    struct Output { let text: String; let status: Int32 }

    static func run(_ args: [String]) -> Output? {
        switch args.first {
        case "--version":
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            return Output(text: v, status: 0)
        case "--auto" where args.count == 2:
            return blocking { try auto(URL(fileURLWithPath: args[1])) }
        case "--frame" where args.count == 4:
            guard let t = Double(args[2]) else { return usage }
            return blocking { try await frame(URL(fileURLWithPath: args[1]), at: t, to: URL(fileURLWithPath: args[3])) }
        case "--music" where args.count == 3:
            return blocking { try await music(URL(fileURLWithPath: args[1]), query: args[2]) }
        case "--add" where args.count >= 3:
            return blocking { try await add(URL(fileURLWithPath: args[1]), Array(args.dropFirst(2)).map { URL(fileURLWithPath: $0) }) }
        case "--format" where args.count == 3:
            return blocking { try format(URL(fileURLWithPath: args[1]), args[2]) }
        case "--render" where args.count == 3:
            return blocking { try await render(URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2])) }
        case let flag? where flag.hasPrefix("--"):
            // Never fall through to launching the app on a mistyped flag.
            return usage
        default:
            return nil
        }
    }

    private static let usage = Output(text: """
        usage: MonetShot --auto <rec.reel>
               MonetShot --frame <rec.reel> <seconds> <out.png>
               MonetShot --render <rec.reel> <out.mp4>
               MonetShot --music <rec.reel> <search>     put the first search result under the video
               MonetShot --add <rec.reel> <video|rec.reel>…  add footage as clips at the end
               MonetShot --format <rec.reel> <\(EditFormat.all.map(\.id).joined(separator: "|"))>  pace and look in one go
               MonetShot --version
        """, status: 2)

    /// Runs async work before AppKit starts. Never use top-level `await` in
    /// main.swift: it would starve every later main-actor task once the app runs.
    private static func blocking(_ work: @escaping @Sendable () async throws -> String) -> Output {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = Output(text: "", status: 1)
        Task.detached {
            do { result = Output(text: try await work(), status: 0) } catch { result = Output(text: "error: \(error)", status: 1) }
            done.signal()
        }
        done.wait()
        return result
    }

    private static func format(_ folder: URL, _ id: String) throws -> String {
        guard let f = EditFormat.named(id) else { return "no format \"\(id)\"; try \(EditFormat.all.map(\.id).joined(separator: ", "))" }
        var p = try Project.load(folder)
        p.edit = f.apply(to: p.edit, duration: p.meta.duration)
        try p.saveEdit()
        return "\(f.name): \(p.clips.count) clips at \(String(format: "%g", f.speed))x, \(String(format: "%.1f", TimeMap(clips: p.clips).duration))s"
    }

    private static func auto(_ folder: URL) throws -> String {
        var p = try Project.load(folder)
        p.edit.segments = SegmentEdits.reAuto(p.edit.segments, clicks: p.cursor.clicks, duration: p.meta.duration)
        try p.saveEdit()
        return p.edit.segments.map { String(format: "%.2f–%.2f ×%.1f%@", $0.start, $0.end, $0.scale, $0.auto ? " auto" : "") }
            .joined(separator: "\n")
    }

    private static func frame(_ folder: URL, at t: Double, to out: URL) async throws -> String {
        let image = try await Composer.frame(try Project.load(folder), at: t)
        let rep = NSBitmapImageRep(cgImage: image)
        try rep.representation(using: .png, properties: [:])?.write(to: out)
        return "\(image.width)x\(image.height) -> \(out.path)"
    }

    private static func music(_ folder: URL, query: String) async throws -> String {
        var p = try Project.load(folder)
        let found = try await MusicCatalog.search(query)
        guard let track = found.first else { return "no tracks for \(query)" }
        let file = try await MusicCatalog.download(track, into: folder)
        var choice = MusicChoice(track: track, file: file)
        // Fitted as the browser fits it: a downbeat in, the end fade from a phrase line.
        let r = Renderer(project: p)
        let place = MusicFit.place(grid: track.grid, songDuration: track.duration, length: r.map.duration, from: track.start,
                                   punchy: r.canvas.height > r.canvas.width)
        choice.offset = place.offset
        p.edit.music = choice
        try p.saveEdit()
        return "\(found.count) results; using \"\(track.title)\" by \(track.artist) (\(track.licenseLabel), \(Int(track.duration))s)"
            + String(format: " from %.2f s, end fade %.2f s", place.offset, place.outro)
    }

    private static func add(_ folder: URL, _ items: [URL]) async throws -> String {
        var p = try Project.load(folder)
        var clips = p.clips
        for url in items {
            if url.pathExtension == "reel" {
                _ = try Imports.recording(try Project.load(url), into: &p)
                clips = p.clips
            } else {
                let i = try await Imports.video(url, into: &p)
                clips.append(Clip(start: 0, end: p.duration(ofTake: i), take: i))
                p.edit.clips = clips
            }
        }
        try p.saveEdit()
        return "\(p.takes.count) takes, \(p.clips.count) clips, \(String(format: "%.1f", TimeMap(clips: p.clips).duration))s"
    }

    private static func render(_ folder: URL, to out: URL) async throws -> String {
        let p = try Project.load(folder)
        let start = Date()
        try await Composer.export(p, to: out)
        return String(format: "exported %@ in %.1fs", out.lastPathComponent, Date().timeIntervalSince(start))
    }
}
