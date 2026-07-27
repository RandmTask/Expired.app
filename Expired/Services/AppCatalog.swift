import Foundation

struct AppCatalog {
    struct LocalIconMatch: Hashable {
        var name: String
        var appStoreURL: String
        var iconData: Data
    }

    private struct Entry: Decodable {
        let name: String
        let appStoreId: String
        let category: String
        let iconFilename: String?
        let aliases: [String]?

        var lookupNames: [String] {
            [name] + (aliases ?? [])
        }
    }

    private static let entries: [Entry] = {
        guard let url = Bundle.main.url(forResource: "AppCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return decoded
    }()

    struct SearchMatch: Identifiable, Hashable {
        var id: String { appStoreId }
        var name: String
        var appStoreId: String
        var category: String
        var iconData: Data?
    }

    /// Fuzzy multi-result lookup for the unified Add Item search (unlike
    /// `localIconMatch`, doesn't require a bundled icon to match).
    static func search(_ query: String, limit: Int = 6) -> [SearchMatch] {
        let queryKey = canonicalName(query)
        guard queryKey.count >= 2 else { return [] }

        let scored: [(SearchMatch, Bool)] = entries.compactMap { entry in
            let keys = entry.lookupNames.map { canonicalName($0) }
            guard keys.contains(where: { $0.contains(queryKey) }) else { return nil }
            let startsWith = keys.contains { $0.hasPrefix(queryKey) }
            let match = SearchMatch(
                name: entry.name,
                appStoreId: entry.appStoreId,
                category: entry.category,
                iconData: entry.iconFilename.flatMap { localIconData(filename: $0) }
            )
            return (match, startsWith)
        }

        return scored
            .sorted { $0.1 && !$1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// Exact-match lookup against the catalog's canonical name/aliases — used to decide
    /// whether a saved item's name is safe to report to the anonymous service-popularity
    /// counter (never sends arbitrary free-text a user typed). Returns the catalog's
    /// canonical display name (not the alias that matched) so counts aren't split across
    /// spelling variants.
    static func knownServiceName(for query: String) -> String? {
        let queryKey = canonicalName(query)
        guard !queryKey.isEmpty,
              let entry = entries.first(where: { entry in
                  entry.lookupNames.contains { canonicalName($0) == queryKey }
              }) else {
            return nil
        }
        return entry.name
    }

    static func localIconMatch(for query: String) -> LocalIconMatch? {
        let queryKey = canonicalName(query)
        guard !queryKey.isEmpty,
              let entry = entries.first(where: { entry in
                  entry.lookupNames.contains { canonicalName($0) == queryKey }
              }),
              let iconFilename = entry.iconFilename,
              let iconData = localIconData(filename: iconFilename) else {
            return nil
        }

        return LocalIconMatch(
            name: entry.name,
            appStoreURL: "https://apps.apple.com/app/id\(entry.appStoreId)",
            iconData: iconData
        )
    }

    private static func localIconData(filename: String) -> Data? {
        let nsFilename = filename as NSString
        let resource = nsFilename.deletingPathExtension
        let ext = nsFilename.pathExtension
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext.isEmpty ? nil : ext),
              let data = try? Data(contentsOf: url),
              FaviconFetcher.isImage(data) else {
            return nil
        }
        return data
    }

    private static func canonicalName(_ value: String) -> String {
        let stopWords: Set<String> = [
            "app", "apps", "subscription", "package", "premium", "plus",
            "pro", "student", "annual", "yearly", "monthly", "storage",
            "with", "plan", "trial", "free", "tb", "gb", "mb"
        ]

        return value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { token -> String? in
                let letters = token.filter(\.isLetter)
                guard !letters.isEmpty, !stopWords.contains(letters) else { return nil }
                return letters
            }
            .joined()
    }
}
