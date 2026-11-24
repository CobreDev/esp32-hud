import Foundation

/// What the notification screen shows.
struct NotificationCard: Equatable {
    var appName: String
    var title: String
    var body: String
    /// Identifies the icon image, so the scene changes when the icon does. Nil = no icon found.
    var iconID: String?
}
