import Foundation

/// A screen the HUD can show.
enum Screen: String {
    case dashboard, weather, music, notification

    var title: String { rawValue.capitalized }
}

/// What the user picked in the popover: Auto, or one screen pinned.
enum ScreenChoice: String, CaseIterable, Identifiable {
    case auto, dashboard, weather, music

    var id: String { rawValue }

    var title: String { Screen(rawValue: rawValue)?.title ?? "Automatic" }
}
