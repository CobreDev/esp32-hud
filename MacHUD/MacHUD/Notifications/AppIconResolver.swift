import AppKit

/// Finds an installed app's icon from its display name, e.g. "Messages" -> Messages.app's icon.
/// (A banner shows the app by name; the icon comes from the app's own bundle.)
@MainActor
final class AppIconResolver {
    struct Match {
        var name: String
        var icon: CGImage
    }

    private var index: [String: URL]?
    private var cache: [String: Match] = [:]

    private static let searchFolders = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities", NSHomeDirectory() + "/Applications",
    ]

    /// The app named `name` (case-insensitive), or nil if no installed app has that name.
    func match(named name: String) -> Match? {
        let key = Self.normalise(name)
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        if index == nil { index = buildIndex() }
        guard let url = index?[key], let icon = Self.icon(at: url) else { return nil }
        let match = Match(name: name, icon: icon)
        cache[key] = match
        return match
    }

    private static func normalise(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func buildIndex() -> [String: URL] {
        var out = [String: URL]()
        func add(_ name: String?, _ url: URL) {
            guard let name, !name.isEmpty else { return }
            let key = Self.normalise(name)
            if out[key] == nil { out[key] = url }
        }
        // Apps that are running right now come first, so they win ties between duplicates.
        for app in NSWorkspace.shared.runningApplications {
            if let url = app.bundleURL, url.pathExtension == "app" { add(app.localizedName, url) }
        }
        for folder in Self.searchFolders {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                add(url.deletingPathExtension().lastPathComponent, url)
                let info = Bundle(url: url)
                add(info?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, url)
                add(info?.object(forInfoDictionaryKey: "CFBundleName") as? String, url)
            }
        }
        return out
    }

    private static func icon(at url: URL) -> CGImage? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        var rect = CGRect(x: 0, y: 0, width: 128, height: 128)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
