import AppKit
import ApplicationServices

/// Notices notification banners by watching Notification Center's windows through the
/// Accessibility API. macOS has no public API for reading other apps' notifications, so this is
/// a best-effort approach: it needs the Accessibility permission, and it can stop working if a
/// macOS update changes how banners are built.
///
/// Debugging: `defaults write local.machud.MacHUD notificationDebug -bool YES` makes it save the
/// structure and text of each banner to `~/Library/Application Support/MacHUD/notification-debug.txt`.
@MainActor
final class NotificationWatcher {
    enum Status: Equatable {
        case needsPermission
        case watching
        case unavailable   // Notification Center isn't running
    }

    private(set) var status: Status = .needsPermission
    var onStatusChange: (() -> Void)?
    /// Called with the parsed banner and its app icon (if the app could be identified).
    var onNotification: ((NotificationCard, CGImage?) -> Void)?

    private let icons = AppIconResolver()
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var timer: Timer?
    private var scanTimer: Timer?
    private var lastScanKey = ""
    private var lastScanSummary = ""

    private static let notificationCenterID = "com.apple.notificationcenterui"

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Banners may be shown in a window that already exists, which sends no "created" event,
        // so also look at Notification Center's windows a couple of times a second.
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        scanTimer?.tolerance = 0.1
        // Ask at launch so MacHUD appears in the Accessibility list (macOS only lists apps that asked).
        if !AXIsProcessTrusted() { requestAccess() }
        debugLog("start: accessibility trusted = \(AXIsProcessTrusted())")
        poll()
    }

    /// Shows macOS's Accessibility prompt (if not yet granted).
    func requestAccess() {
        // The documented key for kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Attaching to Notification Center

    private func poll() {
        guard AXIsProcessTrusted() else {
            detach()
            return set(.needsPermission)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationCenterID).first
        else {
            detach()
            return set(.unavailable)
        }
        if observedPID != app.processIdentifier {
            attach(pid: app.processIdentifier)
            debugLog("attached to Notification Center pid \(app.processIdentifier), observer = \(observer != nil)")
        }
        set(observer == nil ? .unavailable : .watching)
    }

    private func attach(pid: pid_t) {
        detach()
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { watcher.bannerAppeared(element) } }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification] {
            AXObserverAddNotification(obs, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPID = pid
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    private func set(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatusChange?()
    }

    // MARK: - Reading a banner

    /// An event from Notification Center: look again right away and once more shortly after,
    /// since the content fills in just after a window appears.
    private func bannerAppeared(_ element: AXUIElement) {
        debugLog("event: \(Self.attribute(element, kAXRoleAttribute) as? String ?? "?")")
        for delay in [0.05, 0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.scan() }
            }
        }
    }

    /// A banner as macOS describes it: `AXNotificationCenterBanner`, whose description starts with the app's
    /// name ("Messages, Alex, Dinner tonight?"), containing text labelled title / subtitle / body.
    private struct Banner: Equatable {
        var app: String
        var title: String
        var subtitle: String
        var body: String
    }

    /// Looks for banners in Notification Center's windows and shows the newest when it changes.
    private func scan() {
        guard observedPID != 0, status == .watching else { return }
        let app = AXUIElementCreateApplication(observedPID)
        let windows = Self.elements(app, kAXWindowsAttribute)

        var banners = [Banner]()
        for window in windows { Self.findBanners(window, depth: 0, into: &banners) }

        if UserDefaults.standard.bool(forKey: "notificationDebug") {
            let summary = "windows=\(windows.count) banners=\(banners.map { "\($0.app) | \($0.title)" })"
            if summary != lastScanSummary {
                lastScanSummary = summary
                debugLog("scan: \(summary)")
            }
        }

        // Act only when the banners change, so one that stays up is shown once.
        let key = banners.map { "\($0.app)\u{1F}\($0.title)\u{1F}\($0.subtitle)\u{1F}\($0.body)" }.joined(separator: "\u{1E}")
        guard key != lastScanKey else { return }
        lastScanKey = key
        guard let banner = banners.first else { return }
        deliver(banner)
    }

    private static func findBanners(_ el: AXUIElement, depth: Int, into banners: inout [Banner]) {
        guard depth < 12 else { return }
        if let id = attribute(el, kAXIdentifierAttribute) as? String, id.hasPrefix("widget") { return }
        if (attribute(el, kAXSubroleAttribute) as? String) == "AXNotificationCenterBanner" {
            var parts = ["title": "", "subtitle": "", "body": ""]
            collectLabelled(el, depth: 0, into: &parts)
            let description = (attribute(el, kAXDescriptionAttribute) as? String) ?? ""
            let texts = [parts["title"]!, parts["subtitle"]!, parts["body"]!].filter { !$0.isEmpty }
            // The description is "<app>, <texts joined by ', '>": what is left in front is the app's name.
            let tail = ", " + texts.joined(separator: ", ")
            var app = description
            if description.hasSuffix(tail) { app = String(description.dropLast(tail.count)) }
            else if let comma = description.firstIndex(of: ",") { app = String(description[..<comma]) }
            if !texts.isEmpty {
                banners.append(Banner(app: app, title: parts["title"]!, subtitle: parts["subtitle"]!, body: parts["body"]!))
            }
            return
        }
        for child in children(of: el) {
            findBanners(child, depth: depth + 1, into: &banners)
        }
    }

    /// Fills in the text of the elements labelled title / subtitle / body inside a banner.
    private static func collectLabelled(_ el: AXUIElement, depth: Int, into parts: inout [String: String]) {
        guard depth < 8 else { return }
        if let id = attribute(el, kAXIdentifierAttribute) as? String, parts[id] != nil,
           let value = attribute(el, kAXValueAttribute) as? String {
            parts[id] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for child in children(of: el) {
            collectLabelled(child, depth: depth + 1, into: &parts)
        }
    }

    private func deliver(_ banner: Banner) {
        let match = icons.match(named: banner.app)
        let title = banner.title.isEmpty ? banner.body : banner.title
        var body = [banner.subtitle, banner.title.isEmpty ? "" : banner.body].filter { !$0.isEmpty }.joined(separator: " ")
        if title == banner.body { body = banner.subtitle }

        debugLog("deliver: app=\(banner.app) icon=\(match != nil)")
        let card = NotificationCard(appName: banner.app, title: title, body: body,
                                    iconID: match.map { "app:\($0.name)" })
        onNotification?(card, match?.icon)
    }

    private func debugLog(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "notificationDebug") else { return }
        Self.appendDebug("[\(Date())] \(message)\n")
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(el, name) as? [AXUIElement]) ?? []
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        elements(el, kAXChildrenAttribute)
    }

    // MARK: - Debug log

    private static func appendDebug(_ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacHUD")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notification-debug.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
