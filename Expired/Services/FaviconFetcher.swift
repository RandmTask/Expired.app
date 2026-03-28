import Foundation

struct FaviconFetcher {

    /// Accepts any of: "netflix.com", "www.netflix.com", "http://...", "https://..."
    static func fetch(from rawInput: String) async -> Data? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Normalise: strip trailing slashes, ensure scheme present
        var normalised = trimmed
        if !normalised.lowercased().hasPrefix("http://") && !normalised.lowercased().hasPrefix("https://") {
            normalised = "https://\(normalised)"
        }
        // Remove trailing path so we only use the root domain
        guard let components = URLComponents(string: normalised),
              let host = components.host, !host.isEmpty else {
            return nil
        }

        // Pre-check: App Store URLs — fetch actual app artwork via iTunes API
        if host == "apps.apple.com" || host == "itunes.apple.com" {
            if let appID = Self.appStoreID(from: normalised),
               let data = await fetchAppStoreArtwork(appID: appID), isImage(data) {
                return data
            }
            // If extraction failed, fall through to normal strategies
        }

        // Strategy 1: Google favicon service at high resolution (256px)
        if let data = await tryURL("https://www.google.com/s2/favicons?domain=\(host)&sz=256"), isImage(data) {
            return data
        }

        // Strategy 2: icon.horse — high-quality logo fetcher
        if let data = await tryURL("https://icon.horse/icon/\(host)?size=256"), isImage(data) {
            return data
        }

        // Strategy 3: Apple touch icon (often 180×180)
        if let data = await tryURL("https://\(host)/apple-touch-icon.png"), isImage(data) {
            return data
        }

        // Strategy 4: DuckDuckGo favicon service — reliable fallback
        if let data = await tryURL("https://icons.duckduckgo.com/ip3/\(host).ico"), isImage(data) {
            return data
        }

        // Strategy 5: Direct favicon.ico at root
        if let data = await tryURL("https://\(host)/favicon.ico"), isImage(data) {
            return data
        }

        return nil
    }

    private static func tryURL(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else {
            return nil
        }
        return data
    }

    /// Returns the app name from the iTunes lookup API for the given App Store app ID.
    static func fetchAppStoreName(appID: String) async -> String? {
        guard !appID.isEmpty,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(appID)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let trackName = first["trackName"] as? String else { return nil }
        return trackName
    }

    /// Extracts the numeric App Store app ID from an apps.apple.com URL, if present.
    static func appStoreID(from urlString: String) -> String? {
        guard let idRange = urlString.range(of: #"/id(\d+)"#, options: .regularExpression) else { return nil }
        let idSegment = String(urlString[idRange])   // e.g. "/id1136220934"
        let appID = String(idSegment.dropFirst(3))   // drop "/id"
        return appID.isEmpty ? nil : appID
    }

    /// Calls the iTunes lookup API and returns the 512px artwork for the given App Store app ID.
    private static func fetchAppStoreArtwork(appID: String) async -> Data? {
        guard !appID.isEmpty,
              let url = URL(string: "https://itunes.apple.com/lookup?id=\(appID)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        // Parse JSON to extract artworkUrl512
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let artworkURLString = first["artworkUrl512"] as? String,
              let artworkURL = URL(string: artworkURLString) else { return nil }
        return try? await URLSession.shared.data(from: artworkURL).0
    }

    /// Check magic bytes to confirm this is actually an image, not an HTML error page
    static func isImage(_ data: Data) -> Bool {
        guard data.count > 64 else { return false }
        let b = [UInt8](data.prefix(12))
        let isPNG  = b.count >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47
        let isJPEG = b.count >= 2 && b[0] == 0xFF && b[1] == 0xD8
        let isGIF  = b.count >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46
        let isICO  = b.count >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x01 && b[3] == 0x00
        let isWebP = b.count >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
                     && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50
        let isBMP  = b.count >= 2 && b[0] == 0x42 && b[1] == 0x4D
        return isPNG || isJPEG || isGIF || isICO || isWebP || isBMP
    }
}
