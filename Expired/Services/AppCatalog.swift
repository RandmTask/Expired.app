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
