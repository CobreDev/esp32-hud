import AppKit

/// Now-playing info from the Apple Music app.
///
/// * Track and state changes come from the `com.apple.Music.playerInfo` distributed
///   notification.
/// * Details (position, artwork, …) are fetched with AppleScript. The first fetch triggers
///   the macOS Automation consent prompt. If the user denies it, `availability` becomes
///   `.permissionDenied` and we stop asking until `refresh()` is called.
/// * We never script Music unless it is already running, so the app is never launched by us.
@MainActor
final class AppleMusicSource: NowPlayingSource {
    nonisolated static let bundleID = "com.apple.Music"

    private(set) var snapshot = NowPlayingSnapshot.empty
    var onChange: (() -> Void)?

    private let scriptQueue = DispatchQueue(label: "AppleMusicSource.script", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var resyncTimer: Timer?
    private var fetchInFlight = false
    private var fetchAgain = false
    private var artworkTrackID: String?
    private let artworkLookup = ArtworkLookup()
    private var artworkMisses: (id: String, count: Int) = ("", 0)
    private static let maxArtworkAttempts = 3

    // Error codes from the Apple Event Manager.
    private nonisolated static let errAEEventNotPermitted = -1743
    private nonisolated static let procNotFound = -600

    func start() {
        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(forName: Notification.Name("com.apple.Music.playerInfo"),
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })

        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == AppleMusicSource.bundleID else { return }
                MainActor.assumeIsolated { self?.refresh() }
            })
        }

        // Seeks don't always post a notification, so re-read the position now and then while playing.
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.snapshot.track?.state == .playing else { return }
                self.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        guard Self.isMusicRunning else {
            artworkTrackID = nil
            publish(NowPlayingSnapshot(availability: .notRunning))
            return
        }
        if fetchInFlight { fetchAgain = true; return }
        fetchInFlight = true

        let previousArtID = artworkTrackID
        scriptQueue.async { [weak self] in
            let result = Self.fetch(needArtworkUnless: previousArtID)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fetchInFlight = false
                    self.apply(result)
                    if self.fetchAgain { self.fetchAgain = false; self.refresh() }
                }
            }
        }
    }

    // MARK: - Result handling

    private nonisolated enum FetchResult {
        case denied
        case notRunning
        case failed(String)
        case stopped
        /// `artwork` is `.some` only when it was (re)fetched for a new track.
        case track(NowPlayingTrack, artwork: CGImage??)
    }

    private func apply(_ result: FetchResult) {
        var snap = snapshot
        switch result {
        case .denied:
            snap = NowPlayingSnapshot(availability: .permissionDenied)
        case .notRunning:
            artworkTrackID = nil
            snap = NowPlayingSnapshot(availability: .notRunning)
        case .failed(let message):
            snap = NowPlayingSnapshot(availability: .error(message))
        case .stopped:
            artworkTrackID = nil
            snap = NowPlayingSnapshot(availability: .idle)
        case .track(let track, let art):
            if snapshot.track?.id != track.id {   // new track: drop the old cover
                snap.artwork = nil
                snap.artworkID = nil
            }
            snap.availability = .active
            snap.track = track
            if let art {   // Music was asked for this track's artwork
                if let image = art {
                    artworkTrackID = track.id          // settled; don't ask again
                    snap.artwork = image
                    snap.artworkID = track.id
                } else {
                    // Streamed tracks often have no artwork yet when they start, and some never
                    // expose it. Look it up online right away, and keep asking Music on the next
                    // refreshes; a cover from Music replaces the online one.
                    let misses = (artworkMisses.id == track.id ? artworkMisses.count : 0) + 1
                    artworkMisses = (track.id, misses)
                    if misses == 1 { lookUpArtworkOnline(for: track) }
                    if misses >= Self.maxArtworkAttempts { artworkTrackID = track.id }
                }
            }
        }
        publish(snap)
    }

    /// Music has no artwork for this track (typically a streamed song that isn't in the
    /// library). Look it up online and swap it in if the same track is still playing.
    private func lookUpArtworkOnline(for track: NowPlayingTrack) {
        artworkLookup.artwork(title: track.title, artist: track.artist, album: track.album) { [weak self] image in
            guard let self, let image, self.snapshot.track?.id == track.id, self.snapshot.artwork == nil else { return }
            var snap = self.snapshot
            snap.artwork = image
            snap.artworkID = "online:\(track.id)"
            self.publish(snap)
        }
    }

    private func publish(_ snap: NowPlayingSnapshot) {
        snapshot = snap
        onChange?()
    }

    private static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - AppleScript (runs on scriptQueue)

    private nonisolated(unsafe) static let infoScript: NSAppleScript? = {
        let src = """
        tell application id "com.apple.Music"
            set hudState to (player state as string)
            if hudState is "stopped" then return {hudState}
            set hudName to ""
            set hudArtist to ""
            set hudAlbum to ""
            set hudDuration to 0
            set hudPosition to 0
            set hudID to ""
            try
                set hudTrack to current track
                set hudName to name of hudTrack
                set hudArtist to artist of hudTrack
                set hudAlbum to album of hudTrack
                set hudID to persistent ID of hudTrack
                set hudDuration to duration of hudTrack
            on error
                try
                    set hudName to current stream title
                end try
            end try
            try
                set hudPosition to player position
            end try
            return {hudState, hudName, hudArtist, hudAlbum, hudDuration, hudPosition, hudID}
        end tell
        """
        return compiled(src)
    }()

    private nonisolated(unsafe) static let artworkScript: NSAppleScript? = {
        let src = """
        tell application id "com.apple.Music"
            try
                return raw data of artwork 1 of current track
            end try
            return missing value
        end tell
        """
        return compiled(src)
    }()

    /// Returns nil (and logs) if the script doesn't compile, so the error is visible instead of
    /// every run failing.
    private nonisolated static func compiled(_ src: String) -> NSAppleScript? {
        let s = NSAppleScript(source: src)
        var err: NSDictionary?
        guard s?.compileAndReturnError(&err) == true else {
            NSLog("MacHUD: AppleScript compile failed: \(err ?? [:])")
            return nil
        }
        return s
    }

    private nonisolated static func fetch(needArtworkUnless knownArtTrackID: String?) -> FetchResult {
        guard let script = infoScript else { return .failed("Script compile failed") }
        var err: NSDictionary?
        let now = Date()
        let desc = script.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == errAEEventNotPermitted { return .denied }
            if code == procNotFound { return .notRunning }
            let message = (err[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
            NSLog("MacHUD: Music script failed (\(code)): \(message)")
            return .failed(message)
        }

        func str(_ i: Int) -> String { desc.atIndex(i)?.stringValue ?? "" }
        func num(_ i: Int) -> Double { Double(str(i).replacingOccurrences(of: ",", with: ".")) ?? 0 }

        let state = str(1)
        guard desc.numberOfItems >= 7, state == "playing" || state == "paused"
                || state == "fast forwarding" || state == "rewinding" else { return .stopped }

        let title = str(2)
        let id = str(7).isEmpty ? "stream:\(title)" : str(7)
        let track = NowPlayingTrack(
            id: id, title: title, artist: str(3), album: str(4),
            duration: num(5), state: state == "paused" ? .paused : .playing,
            position: num(6), positionDate: now)

        var art: CGImage?? = nil
        if id != knownArtTrackID {
            art = .some(fetchArtwork())
        }
        return .track(track, artwork: art)
    }

    private nonisolated static func fetchArtwork() -> CGImage? {
        guard let script = artworkScript else { return nil }
        var err: NSDictionary?
        let desc = script.executeAndReturnError(&err)
        guard err == nil, desc.descriptorType != typeNull else { return nil }
        let data = desc.data
        guard !data.isEmpty, let image = NSImage(data: data) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
