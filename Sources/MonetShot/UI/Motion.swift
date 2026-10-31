import AppKit
import SwiftUI

/// Every animation in MonetShot, in one place (after Insomnia's Motion). Springs
/// that settle; behind Reduce Motion each one becomes a short crossfade.
@MainActor
enum Motion {
    static let base: Animation = .spring(response: 0.35, dampingFraction: 0.72)
    static let snappy: Animation = .spring(response: 0.25, dampingFraction: 0.6)
    /// One digit roll of a 1 Hz clock; settles well inside a second.
    static let tick: Animation = .spring(response: 0.18, dampingFraction: 0.85)
    static let reduced: Animation = .easeInOut(duration: 0.15)
    /// How long the stop ring must be held.
    static let holdDuration: TimeInterval = 0.6

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func base(_ r: Bool = reduceMotion) -> Animation { r ? reduced : base }
    static func snappy(_ r: Bool = reduceMotion) -> Animation { r ? reduced : snappy }
    static func tick(_ r: Bool = reduceMotion) -> Animation { r ? reduced : tick }

    /// Scale-and-fade from the leading edge (a plain fade under Reduce Motion).
    static func reveal(_ r: Bool = reduceMotion) -> AnyTransition {
        r ? .opacity.animation(reduced)
          : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity).animation(base)
    }
}

/// Insomnia's soft charcoal palette, plus one earned colour: clay, which
/// only appears while recording.
enum Palette {
    static let charcoal = Color(hex: 0x17191B)
    static let panel = Color(hex: 0x1E2123)
    static let midnight = Color(hex: 0x303336)
    static let line = Color(hex: 0x3A3E41)
    static let moonWhite = Color(hex: 0xE6E3DD)
    static let dim = Color(hex: 0xE6E3DD).opacity(0.55)
    static let faint = Color(hex: 0xE6E3DD).opacity(0.32)
    /// Focus, selection, the playhead.
    static let violet = Color(hex: 0xA6BBC3)
    /// Recording.
    static let clay = Color(hex: 0xC96F4A)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
