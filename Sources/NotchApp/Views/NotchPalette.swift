import HerdrClient
import SwiftUI

/// The notch's semantic color system.
///
/// The source palette is specified in OKLCH. SwiftUI does not expose an OKLCH
/// initializer, so these constants are committed as sRGB gamut-mapped values
/// with their source coordinates recorded beside them.
enum NotchPalette {
    // MARK: Surfaces

    /// The physical notch silhouette. True black is intentional here; it is a
    /// void rather than an application surface.
    static let notchVoid = srgb(0x000000)
    /// Warm terminal-dark canvas proposed between the void and raised surface.
    /// Source: oklch(.17 .006 80).
    static let surface = srgb(0x110F0D)
    /// Source: oklch(.22 .008 80).
    static let elevated = srgb(0x1D1A16)
    static let hover = srgb(0x25221E)
    static let selected = srgb(0x2D2924)
    /// Source: oklch(.32 .008 80).
    static let hairline = srgb(0x35322E)

    // MARK: Text

    /// Herdr paper. Source: #f0eee9.
    static let primaryText = srgb(0xF0EEE9)
    /// Source: oklch(.66 .008 80).
    static let secondaryText = srgb(0x95928D)
    static let tertiaryText = secondaryText.opacity(0.62)
    static let disabledText = secondaryText.opacity(0.42)

    // MARK: Status

    /// Source: oklch(.74 .15 85).
    static let working = srgb(0xD6A20A)
    /// Source: oklch(.74 .15 30).
    static let blocked = srgb(0xFB8371)
    /// Source: oklch(.74 .15 150).
    static let done = srgb(0x5AC576)
    /// Source: oklch(.55 .008 80).
    static let idle = srgb(0x74716C)

    // MARK: Roles

    static let brandAccent = blocked
    static let action = primaryText
    static let critical = blocked
    static let success = done
    /// Updates remain informational and must not masquerade as agent status.
    static let updateAccent = primaryText.opacity(0.82)

    static func status(_ status: RollupStatus) -> Color {
        switch status {
        case .blocked: blocked
        case .working: working
        case .done: done
        case .idle: idle
        case .unknown: idle.opacity(0.62)
        }
    }

    private static func srgb(_ hex: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
