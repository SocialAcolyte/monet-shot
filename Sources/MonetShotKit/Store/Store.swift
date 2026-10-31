import Foundation

/// Reads and writes the two files the app owns:
/// - config.json: what the user chose (Settings). Survives everything.
/// - state.json: what the app has changed on the system right now (a
///   journal). Written BEFORE making a change, cleared after undoing it, so a
///   crash or force-quit can always be reconciled on next launch.
/// Writes are atomic (temp file + rename) and owner-only (0600).
public struct Store: Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public static func live() -> Store { Store(dir: Paths.supportDir) }

    public func loadConfig() -> Config { load(Config.self, "config.json") ?? Config() }
    public func save(_ config: Config) { save(config, "config.json") }

    public func loadState() -> RuntimeState { load(RuntimeState.self, "state.json") ?? RuntimeState() }
    public func save(_ state: RuntimeState) { save(state, "state.json") }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder.app.decode(T.self, from: data) } catch {
            // A damaged file is kept aside for inspection, never silently lost.
            Log.error("\(name) unreadable (\(error)); moved aside, using defaults")
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("bad-\(Int(Date().timeIntervalSince1970))"))
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder.app.encode(value)
            let url = dir.appendingPathComponent(name)
            let tmp = dir.appendingPathComponent(".\(name).tmp")
            FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Log.error("could not save \(name): \(error)")
        }
    }
}

extension JSONEncoder {
    public static let app: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    public static let app: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
