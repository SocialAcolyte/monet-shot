import Foundation

/// What the user chose. Every field has a default and decoding tolerates
/// missing keys, so adding a setting never breaks an existing config file.
public struct Config: Codable, Equatable, Sendable {
    public var enabled = true
    public var refreshSeconds = 60
    public var showInMenuBarText = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        refreshSeconds = max(5, try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? d.refreshSeconds)
        showInMenuBarText = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBarText) ?? d.showInMenuBarText
    }
}
