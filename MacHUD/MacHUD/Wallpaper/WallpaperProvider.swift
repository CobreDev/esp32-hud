import AppKit
import Photos

/// Finds the current desktop wallpaper image.
///
/// macOS keeps the wallpaper choice in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`.
/// If the wallpaper is a photo from the Photos app (the usual case on recent macOS), that file holds the
/// photo's asset ID, and the image itself is loaded through PhotoKit, which needs the Photos permission.
/// Otherwise `NSWorkspace.desktopImageURL` is used when it points at a real image file.
@MainActor
final class WallpaperProvider {
    enum Status: Equatable {
        case loading
        case ok
        case needsPermission   // Photos access not granted yet
        case denied
        case unavailable       // wallpaper isn't an image MacHUD can read (e.g. a video wallpaper)
    }

    private(set) var status: Status = .loading
    /// The wallpaper image and an ID that changes whenever the picture does.
    private(set) var current: (id: String, image: CGImage)?
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var lastStoreDate: Date?
    private var loadedKey: String?
    private var loading = false
    private var observers: [NSObjectProtocol] = []

    private static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")

    func start() {
        // The store file changes when the wallpaper does. Check it now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        })
        refresh(force: true)
    }

    /// Shows the Photos permission prompt (if it hasn't been answered yet).
    func requestAccess() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else {
            return refresh(force: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh(force: true) } }
        }
    }

    // MARK: - Loading

    private func refresh(force: Bool = false) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: Self.storeURL.path))?[.modificationDate] as? Date
        if !force, modified == lastStoreDate, status == .ok { return }
        lastStoreDate = modified
        guard !loading else { return }

        switch Self.chosenWallpaper() {
        case .photo(let assetID):
            loadPhoto(assetID: assetID)
        case .file(let url):
            guard loadedKey != url.path else { return }
            if let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                loadedKey = url.path
                finish(id: "file:\(url.path)", image: image, status: .ok)
            } else {
                finish(id: nil, image: nil, status: .unavailable)
            }
        case .none:
            finish(id: nil, image: nil, status: .unavailable)
        }
    }

    private func loadPhoto(assetID: String) {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            return set(.needsPermission)
        case .denied, .restricted:
            return set(.denied)
        default:
            break
        }
        guard loadedKey != assetID else { return }

        // Asset IDs in the wallpaper store are the bare UUID; PhotoKit's local identifiers add a suffix.
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [assetID + "/L0/001", assetID], options: nil)
        guard let asset = result.firstObject else {
            return finish(id: nil, image: nil, status: .unavailable)
        }
        loading = true
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true   // the photo may live in iCloud
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 720, height: 720),
                                              contentMode: .aspectFit, options: options) { image, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading = false
                    if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        self.loadedKey = assetID
                        self.finish(id: "photo:\(assetID)", image: cg, status: .ok)
                    } else if self.current == nil {
                        self.finish(id: nil, image: nil, status: .unavailable)
                    }
                }
            }
        }
    }

    private func finish(id: String?, image: CGImage?, status new: Status) {
        let newCurrent = id.flatMap { id in image.map { (id: id, image: $0) } }
        let changed = newCurrent?.id != current?.id || new != status
        current = newCurrent
        status = new
        if changed { onChange?() }
    }

    private func set(_ new: Status) {
        guard new != status else { return }
        status = new
        onChange?()
    }

    // MARK: - Reading the wallpaper choice

    private enum Choice {
        case photo(String)
        case file(URL)
        case none
    }

    private static func chosenWallpaper() -> Choice {
        if let data = try? Data(contentsOf: storeURL),
           let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let all = root["AllSpacesAndDisplays"] as? [String: Any],
           let desktop = all["Desktop"] as? [String: Any],
           let content = desktop["Content"] as? [String: Any],
           let choice = (content["Choices"] as? [[String: Any]])?.first,
           let config = choice["Configuration"] as? Data,
           let cfg = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any],
           (cfg["type"] as? String) == "asset", let id = cfg["identifier"] as? String {
            return .photo(id)
        }
        // A plain image file, if macOS reports one that isn't the stock default.
        if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
           !url.path.hasSuffix("DefaultDesktop.heic"), !url.hasDirectoryPath {
            return .file(url)
        }
        return .none
    }
}
