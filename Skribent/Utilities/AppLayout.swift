import CoreGraphics

/// Top-level layout dimensions reused across windows / split-views. Named `AppLayout` (not just
/// `Layout`) because SwiftUI ships a `Layout` protocol for custom layouts and the bare name
/// would collide at call sites that say `some Layout`.
enum AppLayout {
    /// `NavigationSplitView` sidebar minimum / ideal widths. Below the min the sidebar starts
    /// truncating list rows ("Nahrávka 2026-…" → "Nahrá…").
    static let sidebarMinWidth: CGFloat = 240
    static let sidebarIdealWidth: CGFloat = 280

    /// Outer `WindowGroup` minimum frame. Below these dims the chip flow + transport bar wrap
    /// awkwardly; we'd rather force the user to keep at least this much room.
    static let windowMinWidth: CGFloat = 980
    static let windowMinHeight: CGFloat = 600
}
