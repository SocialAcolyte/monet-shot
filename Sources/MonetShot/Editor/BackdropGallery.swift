import AppKit
import Foundation
import MonetShotKit

/// The paintings that come with MonetShot for the picture backdrop: all public
/// domain or CC0, listed with their credits in `Backdrops/credits.json`.
/// The installed app carries them in its Resources; a development run reads
/// them from the repo.
enum BackdropGallery {
    struct Painting: Decodable, Identifiable, Hashable {
        let file: String
        let title: String
        let artist: String
        let licence: String
        let source: String
        var id: String { file }
        var url: URL { BackdropGallery.folder!.appendingPathComponent(file) }
        var thumbURL: URL { BackdropGallery.folder!.appendingPathComponent("thumbs").appendingPathComponent(file) }
        /// The name the picture is copied under into a recording, so the
        /// gallery can tell which one is in use.
        var copyName: String { "backdrop-\(file)" }
    }

    static let folder: URL? = {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Backdrops")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Backdrops")
        return [bundled, repo].compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("credits.json").path) }
    }()

    static let paintings: [Painting] = {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent("credits.json")),
              let list = try? JSONDecoder().decode([Painting].self, from: data) else {
            Log.error("backdrop gallery: none found")
            return []
        }
        return list
    }()

    nonisolated(unsafe) private static var thumbs: [String: NSImage] = [:]

    @MainActor static func thumb(_ p: Painting) -> NSImage? {
        if let hit = thumbs[p.file] { return hit }
        let img = NSImage(contentsOf: p.thumbURL)
        thumbs[p.file] = img
        return img
    }
}
