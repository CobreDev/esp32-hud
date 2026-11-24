import AppKit

/// One track as reported by a now-playing source.
struct NowPlayingTrack: Equatable {
    enum PlayState: Equatable { case playing, paused }

    var id: String            // stable per track (used to cache artwork)
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var state: PlayState
    /// Playback position at `positionDate`. Use `elapsed(at:)` for the live value.
    var position: TimeInterval
    var positionDate: Date

    func elapsed(at date: Date = Date()) -> TimeInterval {
        var t = position
        if state == .playing { t += date.timeIntervalSince(positionDate) }
        if duration > 0 { t = min(t, duration) }
        return max(0, t)
    }
}

/// What a source knows right now.
struct NowPlayingSnapshot {
    enum Availability: Equatable {
        case notRunning          // the player app isn't running
        case idle                // running, but nothing loaded / stopped
        case active              // `track` is valid
        case permissionDenied    // e.g. Automation permission refused
        case error(String)
    }

    var availability: Availability = .notRunning
    var track: NowPlayingTrack?
    var artwork: CGImage?
    /// Changes whenever `artwork` changes (nil if there is none).
    var artworkID: String?

    static let empty = NowPlayingSnapshot()
}

/// A provider of "now playing" information. Apple Music today. Spotify, system
/// stats and the like can be added later by conforming to this protocol.
@MainActor
protocol NowPlayingSource: AnyObject {
    var snapshot: NowPlayingSnapshot { get }
    /// Called on the main actor whenever `snapshot` changes.
    var onChange: (() -> Void)? { get set }
    func start()
    /// Re-query immediately (e.g. after the user granted a permission).
    func refresh()
}
