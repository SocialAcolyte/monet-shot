import Foundation

/// Plain-text log at ~/Library/Logs/<App>/<app>.log, one line per event with
/// an ISO timestamp. Readable with `tail -f`, which is the whole point.
public enum Log {
    private static let queue = DispatchQueue(label: "log")
    nonisolated(unsafe) private static var handle: FileHandle? = {
        let url = Paths.logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    public static func info(_ message: String) { write("info", message) }
    public static func error(_ message: String) { write("error", message) }

    private static func write(_ level: String, _ message: String) {
        let line = "\(Date().ISO8601Format()) [\(level)] \(message)\n"
        queue.async { handle?.write(Data(line.utf8)) }
    }
}
