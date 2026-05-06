import SwiftUI

/// Semantic surface tokens. Replaces the ad-hoc `Color.gray.opacity(0.0X)` calls that were
/// scattered across views without any shared meaning. Switching the underlying tier here (e.g.
/// to a per-tier Asset Catalog color for dark mode) takes effect everywhere.
extension Color {
    /// Lightest tier — recorder cards, level-meter background.
    static let surfaceQuiet = Color.gray.opacity(0.05)

    /// Default content surface — banner background, transport rows.
    static let surface = Color.gray.opacity(0.08)

    /// Subtle separator / capsule fill.
    static let surfaceMuted = Color.gray.opacity(0.10)

    /// Bordered chip fill (slightly heavier than `surfaceMuted`).
    static let surfaceBorder = Color.gray.opacity(0.18)
}
