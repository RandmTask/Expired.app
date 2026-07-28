import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AppCatalog {
    struct LocalIconMatch: Hashable {
        var name: String
        var appStoreURL: String
        var iconData: Data
    }

    private struct Entry: Decodable {
        let name: String
        let appStoreId: String?
        let category: String
        let iconFilename: String?
        let aliases: [String]?
        /// Absent means global — the entry shows in every region's onboarding grid.
        let regions: [String]?
        /// Marks entries eligible for the R4 onboarding picker grid (search still
        /// returns every entry regardless of this flag).
        let onboarding: Bool?
        /// Raw `ItemType` string ("Document"/"Subscription"); absent = subscription.
        let itemType: String?
        /// SF Symbol name for non-app tiles (no `appStoreId`, no icon fetch).
        let symbolName: String?
        /// Explicit Asset Catalog image-set name, for web-only services that have no
        /// App Store app to key an icon off. Written by `bin/fetch-onboarding-icons.py`
        /// alongside `iconURL`; takes precedence over the `appStoreId` lookup.
        let iconAsset: String?

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

    /// A tile in the onboarding picker grid — covers both real App Store apps and
    /// the non-app tiles (Gym, Insurance, Passport…) that use an SF Symbol instead.
    struct OnboardingTile: Identifiable, Hashable {
        var id: String
        var name: String
        var category: String
        var appStoreId: String?
        var iconData: Data?
        var symbolName: String?
        var itemType: ItemType
        var isRegionMatch: Bool
    }

    /// Reads `appStoreRegion` from `UserDefaults` directly (the same key
    /// `AddItemHubView`'s `@AppStorage("appStoreRegion")` writes to) so every
    /// consumer of region logic reads one source instead of duplicating this
    /// fallback-to-locale computation.
    static var regionCode: String {
        let stored = UserDefaults.standard.string(forKey: "appStoreRegion") ?? "auto"
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "auto" {
            return Locale.current.region?.identifier.lowercased() ?? "us"
        }
        return trimmed.lowercased()
    }

    /// Tiles for the R4 onboarding grid: every `onboarding`-flagged, real App Store
    /// entry (no `symbolName`-only non-app tiles — Deon's call, 2026-07-27: the grid
    /// is "popular apps or websites", not a generic document picker) that is either
    /// global (no `regions`) or matches `region`. Region-matched entries sort first,
    /// then alphabetically — no category grouping, flat grid. `region` is an
    /// uppercase ISO country code (e.g. "AU") — defaults to `regionCode` uppercased.
    static func onboardingTiles(region: String? = nil) -> [OnboardingTile] {
        let regionKey = (region ?? regionCode).uppercased()

        return entries
            .filter { entry in
                guard entry.onboarding == true, entry.appStoreId != nil else { return false }
                // Absent `regions` = global, always included. Region filters the
                // grid only — non-matching regional entries stay searchable via
                // `search(_:limit:)`, just not shown as onboarding tiles here.
                guard let regions = entry.regions else { return true }
                return regions.contains(regionKey)
            }
            .map { entry -> OnboardingTile in
                OnboardingTile(
                    id: entry.appStoreId ?? entry.name,
                    name: entry.name,
                    category: entry.category,
                    appStoreId: entry.appStoreId,
                    iconData: bundledIconData(for: entry),
                    symbolName: entry.symbolName,
                    itemType: entry.itemType.flatMap(ItemType.init(rawValue:)) ?? .subscription,
                    isRegionMatch: entry.regions != nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.isRegionMatch != rhs.isRegionMatch { return lhs.isRegionMatch && !rhs.isRegionMatch }
                return lhs.name < rhs.name
            }
    }

    /// Fuzzy multi-result lookup for the unified Add Item search (unlike
    /// `localIconMatch`, doesn't require a bundled icon to match). Region filtering
    /// never applies here — every region's entries stay searchable/findable.
    static func search(_ query: String, limit: Int = 6) -> [SearchMatch] {
        let queryKey = canonicalName(query)
        guard queryKey.count >= 2 else { return [] }

        let scored: [(SearchMatch, Bool)] = entries.compactMap { entry in
            guard let appStoreId = entry.appStoreId else { return nil }
            let keys = entry.lookupNames.map { canonicalName($0) }
            guard keys.contains(where: { $0.contains(queryKey) }) else { return nil }
            let startsWith = keys.contains { $0.hasPrefix(queryKey) }
            let match = SearchMatch(
                name: entry.name,
                appStoreId: appStoreId,
                category: entry.category,
                iconData: bundledIconData(for: entry)
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
              let appStoreId = entry.appStoreId,
              let iconData = bundledIconData(for: entry) else {
            return nil
        }

        return LocalIconMatch(
            name: entry.name,
            appStoreURL: "https://apps.apple.com/app/id\(appStoreId)",
            iconData: iconData
        )
    }

    /// Bundled icon for an entry, checked in order: an explicit `iconAsset` image set
    /// (web-sourced icons), an Asset Catalog image set named by `appStoreId` (what
    /// `bin/fetch-onboarding-icons.py` writes), then the loose-bundle `iconFilename`.
    /// The loose file is the last resort rather than the first so a freshly fetched,
    /// correctly-sized App Store icon always beats a hand-added legacy file.
    private static func bundledIconData(for entry: Entry) -> Data? {
        if let iconAsset = entry.iconAsset, let data = assetCatalogIconData(named: iconAsset) {
            return data
        }
        if let appStoreId = entry.appStoreId, let data = assetCatalogIconData(named: appStoreId) {
            return data
        }
        if let iconFilename = entry.iconFilename, let data = localIconData(filename: iconFilename) {
            return data
        }
        return nil
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

    private static func assetCatalogIconData(named name: String) -> Data? {
#if os(iOS)
        guard let image = UIImage(named: name) else { return nil }
        return image.pngData()
#elseif os(macOS)
        guard let image = NSImage(named: name),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
#else
        return nil
#endif
    }

    /// Exposed (not `private`) so the onboarding batch commit can dedupe selections
    /// against existing items by canonical name rather than raw string equality.
    static func canonicalName(_ value: String) -> String {
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
