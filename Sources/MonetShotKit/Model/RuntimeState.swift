import Foundation

/// The journal: every system change the app has made and not yet undone.
/// Add a case per kind of change your utility makes (a setting flipped, a
/// process paused, a file moved), with what is needed to put it back.
public struct RuntimeState: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var kind: String          // e.g. "pmset.disablesleep"
        public var restoreValue: String  // what to put back
        public var madeAt: Date
        public init(kind: String, restoreValue: String, madeAt: Date = Date()) {
            self.kind = kind; self.restoreValue = restoreValue; self.madeAt = Date(timeIntervalSince1970: madeAt.timeIntervalSince1970.rounded(.down)) // ISO 8601 keeps whole seconds
        }
    }
    public var changes: [Change] = []
    public var isClean: Bool { changes.isEmpty }
    public init() {}
}
