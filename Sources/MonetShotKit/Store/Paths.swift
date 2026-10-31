import Foundation

/// Where the app keeps things. `MONETSHOT_HOME` overrides the root so tests
/// (and experiments) never touch the real config or logs.
public enum Paths {
    public static let appName = "MonetShot"

    public static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["MONETSHOT_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("support")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appName)")
    }

    public static var logFile: URL {
        if let override = ProcessInfo.processInfo.environment["MONETSHOT_HOME"] {
            return URL(fileURLWithPath: override).appendingPathComponent("logs/\(appName.lowercased()).log")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(appName)/\(appName.lowercased()).log")
    }

    /// The app was called Reel until October 2026. On first launch as
    /// MonetShot, the old recordings and settings move to the new folders
    /// (only when the new ones don't exist yet, so nothing is overwritten).
    public static func moveFromReel() {
        guard ProcessInfo.processInfo.environment["MONETSHOT_HOME"] == nil else { return }
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        for (old, new) in [("Movies/Reel", "Movies/MonetShot"),
                           ("Library/Application Support/Reel", "Library/Application Support/MonetShot")] {
            let from = home.appendingPathComponent(old), to = home.appendingPathComponent(new)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.moveItem(at: from, to: to)
                Log.info("moved \(old) to \(new)")
            } catch {
                Log.error("move \(old): \(error)")
            }
        }
    }

    public static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    public static var stateFile: URL { supportDir.appendingPathComponent("state.json") }
}
