import AppKit

/// Finds album artwork online when the player can't provide it, e.g. Apple Music songs that
/// are streamed without being in the library (Music reports those as "URL tracks" with no
/// artwork via AppleScript).
///
/// Uses Apple's public iTunes Search API (no key). Only the artist and title are sent.
/// Results, including misses, are cached in memory for the session.
@MainActor
final class ArtworkLookup {
    private var cache: [String: CGImage?] = [:]
    private var inFlight: Set<String> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies or on-disk cache
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// Calls `completion` on the main actor with the artwork (or nil if none was found).
    /// Does nothing while a lookup for the same key is already running.
    func artwork(title: String, artist: String, album: String,
                 completion: @escaping (CGImage?) -> Void) {
        let key = "\(artist)\u{1F}\(title)".lowercased()
        if let cached = cache[key] { completion(cached); return }
        guard !title.isEmpty, !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task { [session] in
            let image = await Self.lookup(title: title, artist: artist, album: album, session: session)
            self.inFlight.remove(key)
            if self.cache.count > 200 { self.cache.removeAll() }
            self.cache[key] = image
            completion(image)
        }
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    private nonisolated static func lookup(title: String, artist: String, album: String,
                                           session: URLSession) async -> CGImage? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return nil }

        // Prefer an exact title + artist match (and the same album if we know it).
        func norm(_ s: String?) -> String { (s ?? "").lowercased().trimmingCharacters(in: .whitespaces) }
        let t = norm(title), a = norm(artist), al = norm(album)
        let scored = response.results.compactMap { item -> (Int, String)? in
            guard let art = item.artworkUrl100 else { return nil }
            var score = 0
            if norm(item.trackName) == t { score += 4 } else if norm(item.trackName).hasPrefix(t) { score += 2 }
            if norm(item.artistName) == a { score += 3 } else if norm(item.artistName).contains(a) { score += 1 }
            if !al.isEmpty, norm(item.collectionName) == al { score += 2 }
            return (score, art)
        }
        // Require at least a title or artist match so we never show an unrelated cover.
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= 3 else { return nil }

        // The API returns a 100 px URL; the same path serves larger sizes.
        let big = best.1.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let imageURL = URL(string: big),
              let (imageData, _) = try? await session.data(from: imageURL),
              let image = NSImage(data: imageData)
        else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
