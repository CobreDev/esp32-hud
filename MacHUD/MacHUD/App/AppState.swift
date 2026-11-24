import AppKit
import Combine
import ServiceManagement

/// Glue between the now-playing source, the renderer and the serial link.
@MainActor
final class AppState: ObservableObject {
    // UI state
    @Published private(set) var linkStatus: SerialLink.Status = .notFound
    @Published private(set) var sourceAvailability: NowPlayingSnapshot.Availability = .notRunning
    @Published private(set) var weatherStatus: WeatherProvider.Status = .locating
    @Published private(set) var notificationStatus: NotificationWatcher.Status = .needsPermission
    @Published private(set) var wallpaperStatus: WallpaperProvider.Status = .loading
    /// The screen currently on the display, whether chosen automatically or pinned.
    @Published private(set) var activeScreen: Screen = .dashboard
    /// Automatic, or one screen pinned by the user. Persisted.
    @Published var screenChoice: ScreenChoice {
        didSet {
            guard screenChoice != oldValue else { return }
            UserDefaults.standard.set(screenChoice.rawValue, forKey: Self.screenChoiceKey)
            update()
        }
    }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var hudEnabled: Bool {
        didSet {
            guard hudEnabled != oldValue else { return }
            UserDefaults.standard.set(hudEnabled, forKey: Self.enabledKey)
            link.setDisplayOn(hudEnabled)
            if hudEnabled, let jpeg = lastJPEG { link.submitFrame(jpeg) }
        }
    }

    /// Changes every animation frame. Kept out of AppState's own @Published properties so
    /// views that only care about status (like the menu bar icon) aren't redrawn at 15 Hz.
    let framePreview = FramePreview()
    let source: NowPlayingSource
    private let renderer = HUDRenderer()
    private let link = SerialLink()

    private var lastScene: HUDScene?
    private var lastJPEG: Data?
    private var timer: Timer?
    private var timerIsFast = false

    // Animation state
    private var lastContent: HUDScene?          // scene without progress, to detect content changes
    private var shownFrame: CGImage?            // what is on screen now (possibly mid-fade)
    private var fade: (from: CGImage, start: Date)?
    private var ring = RingAnimator()
    private var marquee = Marquee()
    private let battery = BatteryMonitor()
    private let weather = WeatherProvider()
    private let notifications = NotificationWatcher()
    private let wallpaper = WallpaperProvider()
    private var shownNotification: (card: NotificationCard, icon: CGImage?, until: Date)?

    /// How long a notification stays on the display.
    private static let notificationSeconds: TimeInterval = 8

    /// After music pauses, the Music screen stays this long (5 minutes) before the dashboard returns.
    private static let pauseLinger: TimeInterval = 5 * 60
    private var lastPlayingAt = Date.distantPast
    private var artSpring = Spring(response: 0.42, dampingFraction: 0.68)
    private var lastTick = Date()

    /// Animation frame rate. The device draws a frame in ~66 ms, and the serial link drops
    /// stale frames, so rendering a bit faster than the device just keeps it saturated.
    private static let fastInterval: TimeInterval = 1.0 / 15
    private static let slowInterval: TimeInterval = 1.0
    private static let fadeDuration: TimeInterval = 0.25

    private static let enabledKey = "hudEnabled"
    private static let screenChoiceKey = "screenChoice"

    init(source: NowPlayingSource? = nil) {
        let source = source ?? AppleMusicSource()
        self.source = source
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        hudEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        screenChoice = UserDefaults.standard.string(forKey: Self.screenChoiceKey)
            .flatMap(ScreenChoice.init(rawValue:)) ?? .auto

        link.onStatusChange = { [weak self] status in
            MainActor.assumeIsolated { self?.linkStatus = status }
        }
        link.setDisplayOn(hudEnabled)
        link.start()

        source.onChange = { [weak self] in self?.update() }
        source.start()

        weather.onChange = { [weak self] in
            guard let self else { return }
            self.weatherStatus = self.weather.status
            self.update()
        }
        weather.start()

        notifications.onStatusChange = { [weak self] in
            guard let self else { return }
            self.notificationStatus = self.notifications.status
        }
        notifications.onNotification = { [weak self] card, icon in
            guard let self else { return }
            self.shownNotification = (card, icon, Date().addingTimeInterval(Self.notificationSeconds))
            self.update()
        }
        notifications.start()
        notificationStatus = notifications.status

        wallpaper.onChange = { [weak self] in
            guard let self else { return }
            self.wallpaperStatus = self.wallpaper.status
            self.update()
        }
        wallpaper.start()
        wallpaperStatus = wallpaper.status

        scheduleTimer(fast: false)
        update()
    }

    /// 15 Hz while something moves (playing, fading, ring sweeping), 1 Hz otherwise
    /// (enough for the clock). update() only renders when the frame would change.
    private func scheduleTimer(fast: Bool) {
        if timer != nil, fast == timerIsFast { return }
        timer?.invalidate()
        timerIsFast = fast
        let interval = fast ? Self.fastInterval : Self.slowInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Rendering pipeline

    func update() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let snap = source.snapshot
        if sourceAvailability != snap.availability { sourceAvailability = snap.availability }

        var scene = makeScene(snap, now: now)

        // Ease the ring on jumps (seek, track change); follow normal playback exactly.
        var isPlaying = false
        var scrolling = false
        if case let .track(title, artist, playing, progress, artID) = scene.content {
            isPlaying = playing
            let duration = snap.track?.duration ?? 0
            let shown = progress.map { ring.step(toward: $0, dt: dt, duration: duration) }
            // Quantise to ~1/4 px of ring travel: no new frame unless something visibly moved.
            let q = shown.map { ($0 * 2880).rounded() / 2880 }
            scene = HUDScene(content: .track(title: title, artist: artist, isPlaying: playing,
                                             progress: q, artworkID: artID))

            // Long title / artist scroll while playing; they rest at the start when paused.
            let loops = renderer.marqueeLoopLengths(title: title, artist: artist)
            let offsets = marquee.offsets(key: "\(title)\u{1F}\(artist)", playing: playing,
                                          titleLoop: loops.title, artistLoop: loops.artist, now: now)
            scene.titleScroll = offsets.title
            scene.artistScroll = offsets.artist
            scrolling = playing && (loops.title != nil || loops.artist != nil)

            // Play/pause: artwork springs between full size and a smaller "paused" size.
            let scale = artSpring.step(toward: playing ? 1 : Double(HUDScene.pausedArtScale), dt: dt)
            scene.artScale = CGFloat((scale * 400).rounded() / 400)
        } else {
            ring.reset()
            marquee.reset()
            artSpring.reset()
        }

        // Content changed (track, play state, screen, clock minute) -> cross-fade.
        let content = scene.withoutProgress
        if content != lastContent {
            if lastContent != nil, let shownFrame { fade = (shownFrame, now) }
            lastContent = content
        }

        scheduleTimer(fast: isPlaying || scrolling || fade != nil || ring.isAnimating || artSpring.isMoving)

        guard scene != lastScene || fade != nil else { return }
        lastScene = scene

        // For the notification screen the "artwork" slot carries the sending app's icon.
        // On the dashboard it carries the wallpaper.
        let artwork: CGImage?
        switch activeScreen {
        case .notification: artwork = shownNotification?.icon
        case .dashboard: artwork = wallpaper.current?.image
        default: artwork = snap.artwork
        }
        guard var image = renderer.render(scene, artwork: artwork) else { return }
        if let f = fade {
            let t = now.timeIntervalSince(f.start) / Self.fadeDuration
            if t >= 1 {
                fade = nil
            } else if let blended = renderer.crossfade(from: f.from, to: image, t: Self.easeInOut(t)) {
                image = blended
            }
        }
        shownFrame = image

        guard let jpeg = HUDRenderer.jpegData(image, quality: 0.93) else { return }
        lastJPEG = jpeg
        // Preview shows the exact bytes the device gets (decoded from the JPEG).
        framePreview.update(jpeg: jpeg)
        if hudEnabled { link.submitFrame(jpeg) }
    }

    private static func easeInOut(_ t: Double) -> CGFloat {
        let t = min(max(t, 0), 1)
        return CGFloat(t * t * (3 - 2 * t))
    }

    /// Which screen to show right now.
    ///
    /// Automatic: music playing (or paused within the last 5 minutes) -> Music; otherwise the Dashboard.
    private func chooseScreen(track: NowPlayingTrack?, now: Date) -> Screen {
        if track?.state == .playing { lastPlayingAt = now }
        switch screenChoice {
        case .auto:
            if let n = shownNotification, now < n.until { return .notification }
            if let track, track.state == .playing || now.timeIntervalSince(lastPlayingAt) < Self.pauseLinger {
                return .music
            }
            return .dashboard
        case .dashboard: return .dashboard
        case .weather: return weather.current != nil ? .weather : .dashboard
        case .music: return track != nil ? .music : .dashboard
        }
    }

    private func makeScene(_ snap: NowPlayingSnapshot, now: Date) -> HUDScene {
        let track = snap.availability == .active ? snap.track : nil
        let screen = chooseScreen(track: track, now: now)
        if activeScreen != screen { activeScreen = screen }

        switch screen {
        case .music:
            if let t = track {
                return HUDScene(content: .track(
                    title: t.title, artist: t.artist, isPlaying: t.state == .playing,
                    progress: t.duration > 0 ? t.elapsed(at: now) / t.duration : nil,
                    artworkID: snap.artworkID))
            }
        case .weather:
            if let forecast = weather.current { return HUDScene(content: .weather(forecast.card)) }
        case .notification:
            if let n = shownNotification { return HUDScene(content: .notification(n.card)) }
        case .dashboard:
            break
        }

        // Dashboard. Only mention Music when something needs the user's attention.
        let subtitle: String
        switch snap.availability {
        case .permissionDenied: subtitle = "Allow Music"
        case .error: subtitle = "Music unavailable"
        case .notRunning, .idle, .active: subtitle = ""
        }
        return HUDScene(content: .clock(
            time: Self.timeFormatter.string(from: now),
            date: Self.dateFormatter.string(from: now),
            minute: Calendar.current.component(.minute, from: now),
            battery: battery.current(now: now),
            weather: weather.current?.chip,
            wallpaperID: wallpaper.current?.id,
            subtitle: subtitle))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f
    }()

    // MARK: - Actions

    func releasePort() { link.releasePort() }
    func reconnect() { link.reconnect() }

    func retryMusicAccess() { source.refresh() }
    func requestLocationAccess() { weather.requestAccess() }
    func requestNotificationAccess() { notifications.requestAccess() }
    func requestWallpaperAccess() { wallpaper.requestAccess() }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("MacHUD: launch at login change failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginNeedsApproval = status == .requiresApproval
    }
}

/// Smooths the progress ring. Normal playback (and small corrections from re-reading the
/// position) is followed exactly; larger jumps (seek, new track) glide there over ~0.4 s.
struct RingAnimator {
    private var shown: Double?
    private(set) var isAnimating = false

    /// Time constant of the exponential glide.
    private let tau: TimeInterval = 0.09
    /// Jumps smaller than this many seconds of playback snap instead of gliding.
    private let snapSeconds: Double = 0.75

    mutating func step(toward target: Double, dt: TimeInterval, duration: TimeInterval) -> Double {
        guard let current = shown else { shown = target; return target }
        let snapThreshold = duration > 0 ? snapSeconds / duration : 0.005
        let diff = target - current
        if abs(diff) <= snapThreshold && !isAnimating || abs(diff) < 0.0005 {
            isAnimating = false
            shown = target
        } else {
            isAnimating = true
            let k = 1 - exp(-max(dt, 0) / tau)
            shown = current + diff * k
        }
        return shown!
    }

    mutating func reset() {
        shown = nil
        isAnimating = false
    }
}

/// The latest frame, for the popover preview.
@MainActor
final class FramePreview: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var bytes = 0

    func update(jpeg: Data) {
        image = NSImage(data: jpeg)
        bytes = jpeg.count
    }
}

/// Scroll positions for text that doesn't fit: rest at the start, then scroll left one full
/// loop (until the repeated copy is exactly where the text started), rest again, repeat.
struct Marquee {
    /// Scroll speed in px/s. ~10 fps on the device gives ~3 px steps, which still reads smoothly.
    var speed: CGFloat = 28
    /// Pause at the start of each loop.
    var rest: TimeInterval = 2.5

    private var key: String?
    private var elapsed: TimeInterval = 0   // scroll time; only advances while playing
    private var lastNow: Date?

    mutating func offsets(key: String, playing: Bool, titleLoop: CGFloat?, artistLoop: CGFloat?,
                          now: Date) -> (title: CGFloat, artist: CGFloat) {
        if key != self.key {          // new track: start over
            self.key = key
            elapsed = 0
        } else if playing, let lastNow {
            elapsed += now.timeIntervalSince(lastNow)
        }
        lastNow = now                 // paused: text holds where it is
        return (offset(elapsed, loop: titleLoop), offset(elapsed, loop: artistLoop))
    }

    private func offset(_ t: TimeInterval, loop: CGFloat?) -> CGFloat {
        guard let loop, loop > 0 else { return 0 }
        let travel = TimeInterval(loop / speed)
        let phase = t.truncatingRemainder(dividingBy: rest + travel)
        guard phase > rest else { return 0 }
        return (CGFloat(phase - rest) * speed).rounded()   // whole pixels: fewer, crisper frames
    }

    mutating func reset() { key = nil; lastNow = nil }
}

/// A damped spring, parameterised like SwiftUI's `.spring(response:dampingFraction:)`.
struct Spring {
    let response: Double
    let dampingFraction: Double
    private var value: Double?
    private var velocity: Double = 0
    private(set) var isMoving = false

    init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// Advances the spring by `dt` seconds toward `target` and returns the new value.
    /// The first call jumps straight to the target (no animation on appear).
    mutating func step(toward target: Double, dt: TimeInterval) -> Double {
        guard var x = value else { value = target; return target }
        let omega = 2 * Double.pi / response
        let stiffness = omega * omega
        let damping = 2 * dampingFraction * omega
        // Small fixed sub-steps keep the integration stable at any frame rate.
        var remaining = min(max(dt, 0), 0.25)
        while remaining > 0 {
            let h = min(remaining, 1.0 / 240)
            velocity += (-stiffness * (x - target) - damping * velocity) * h
            x += velocity * h
            remaining -= h
        }
        if abs(x - target) < 0.0005 && abs(velocity) < 0.005 {
            x = target
            velocity = 0
            isMoving = false
        } else {
            isMoving = true
        }
        value = x
        return x
    }

    mutating func reset() {
        value = nil
        velocity = 0
        isMoving = false
    }
}

/// Opens a pane of System Settings > Privacy & Security.
enum SystemSettings {
    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
