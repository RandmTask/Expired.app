import SwiftUI

/// Guided "Add Item" capture hub — three routes (Search / Screenshot / Manual) that
/// all converge on `AddEditSubscriptionView`'s review step. Reports the chosen route
/// back to `HomeView` rather than presenting `AddEditSubscriptionView` itself, so the
/// hub sheet and the review sheet never nest.
struct AddItemHubView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PurchaseManager.self) private var purchaseManager

    let onSelectManual: () -> Void
    let onSelectScreenshot: () -> Void
    let onSelectPrefill: (AddEditPrefill) -> Void
    let onRequirePaywall: () -> Void

    @State private var searchText = ""
    @State private var catalogMatches: [AppCatalog.SearchMatch] = []
    @State private var appStoreResults: [AppStoreResult] = []
    @State private var isSearchingAppStore = false
    @State private var searchTask: Task<Void, Never>?
    @State private var resolvingID: String?

    private struct AppStoreResult: Codable, Identifiable, Hashable {
        let trackId: Int
        let trackName: String
        let trackViewUrl: String
        let primaryGenreName: String?
        let artworkUrl512: String?
        let artworkUrl100: String?
        var id: Int { trackId }
    }

    private struct AppStoreResponse: Codable {
        let results: [AppStoreResult]
    }

    private var regionCode: String { AppCatalog.regionCode }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var looksLikeURL: Bool {
        let t = trimmedSearch
        guard !t.isEmpty, !t.contains(" ") else { return false }
        if t.lowercased().hasPrefix("http") { return true }
        let parts = t.split(separator: ".")
        return parts.count >= 2 && !t.hasSuffix(".")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search apps or paste a URL", text: $searchText)
#if os(iOS)
                            .textInputAutocapitalization(.never)
#endif
                            .autocorrectionDisabled()
                        if isSearchingAppStore {
                            ProgressView().scaleEffect(0.8)
                        }
                    }
                    .onChange(of: searchText) { _, newValue in
                        scheduleSearch(newValue)
                    }

                    if looksLikeURL {
                        urlRow
                        aiURLRow
                    }

                    ForEach(catalogMatches) { match in
                        catalogRow(match)
                    }

                    ForEach(appStoreResults) { result in
                        appStoreRow(result)
                    }
                }

                Section {
                    Button {
                        Haptics.fire(.light)
                        onSelectScreenshot()
                    } label: {
                        hubRowLabel("Screenshot Import", icon: "doc.viewfinder")
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.fire(.light)
                        onSelectManual()
                    } label: {
                        hubRowLabel("Enter Manually", icon: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func hubRowLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 22, alignment: .center)
                .foregroundStyle(.blue)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var urlRow: some View {
        Button {
            Haptics.fire(.light)
            resolveURLPrefill()
        } label: {
            HStack(spacing: 12) {
                if resolvingID == "url" {
                    ProgressView().scaleEffect(0.8)
                        .frame(width: 22)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, alignment: .center)
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use “\(trimmedSearch)”")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Fetch icon and name from this URL")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
    }

    /// Pro-gated companion to `urlRow` — same URL, but reads the page server-side
    /// via `ai-proxy` for name + price + currency + billing cycle instead of just
    /// favicon + host-guessed name. Falls back to `resolveURLPrefill()` (the free,
    /// no-AI route) silently on any failure.
    private var aiURLRow: some View {
        Button {
            guard purchaseManager.isPremium else {
                Haptics.fire(.warning)
                onRequirePaywall()
                return
            }
            Haptics.fire(.light)
            resolveURLPrefillWithAI()
        } label: {
            HStack(spacing: 12) {
                if resolvingID == "url-ai" {
                    ProgressView().scaleEffect(0.8)
                        .frame(width: 22)
                } else {
                    Image(systemName: purchaseManager.isPremium ? "sparkles" : "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, alignment: .center)
                        .foregroundStyle(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read Page with AI")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Also extracts price and billing cycle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
    }

    @ViewBuilder
    private func catalogRow(_ match: AppCatalog.SearchMatch) -> some View {
        Button {
            Haptics.fire(.light)
            resolveCatalogMatch(match)
        } label: {
            HStack(spacing: 12) {
                resultIcon(data: match.iconData, name: match.name, isLoading: resolvingID == match.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(match.category)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
    }

    @ViewBuilder
    private func appStoreRow(_ result: AppStoreResult) -> some View {
        Button {
            Haptics.fire(.light)
            resolveAppStoreResult(result)
        } label: {
            HStack(spacing: 12) {
                resultIcon(data: nil, urlString: result.artworkUrl100, name: result.trackName, isLoading: resolvingID == String(result.trackId))
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.trackName)
                        .font(.system(size: 15, weight: .semibold))
                    if let genre = result.primaryGenreName {
                        Text(genre)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
    }

    @ViewBuilder
    private func resultIcon(data: Data?, urlString: String? = nil, name: String, isLoading: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
            if isLoading {
                ProgressView().scaleEffect(0.7)
            } else if let data, let platformImage = platformImage(from: data) {
                Image(platformImage: platformImage).resizable().scaledToFill()
            } else if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Text(initials(from: name))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(initials(from: name))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func initials(from title: String) -> String {
        title.split(separator: " ").prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }

    // MARK: - Search

    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        catalogMatches = AppCatalog.search(trimmed)
        guard trimmed.count >= 3 else {
            appStoreResults = []
            isSearchingAppStore = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearchingAppStore = true }
            let results = await searchAppStore(trimmed)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appStoreResults = results
                isSearchingAppStore = false
            }
        }
    }

    private func searchAppStore(_ query: String) async -> [AppStoreResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=software&limit=8&country=\(regionCode)")
        else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(AppStoreResponse.self, from: data)
        else { return [] }
        return decoded.results
    }

    // MARK: - Resolving a selection into a prefill

    private func resolveCatalogMatch(_ match: AppCatalog.SearchMatch) {
        resolvingID = match.id
        Task {
            let details = await lookupArtwork(appStoreId: match.appStoreId)
            await MainActor.run {
                resolvingID = nil
                onSelectPrefill(AddEditPrefill(
                    name: match.name,
                    url: details.trackViewUrl ?? "https://apps.apple.com/app/id\(match.appStoreId)",
                    iconData: match.iconData ?? details.artwork,
                    iconSource: (match.iconData ?? details.artwork) != nil ? .customImage : .system,
                    categoryRaw: match.category
                ))
            }
        }
    }

    private func resolveAppStoreResult(_ result: AppStoreResult) {
        resolvingID = String(result.trackId)
        Task {
            let artworkURLString = result.artworkUrl512 ?? result.artworkUrl100
            let artwork = await fetchArtwork(urlString: artworkURLString)
            let categoryRaw = AppCatalog.search(result.trackName, limit: 1).first?.category
            await MainActor.run {
                resolvingID = nil
                onSelectPrefill(AddEditPrefill(
                    name: result.trackName,
                    url: result.trackViewUrl,
                    iconData: artwork,
                    iconSource: artwork != nil ? .customImage : .system,
                    categoryRaw: categoryRaw
                ))
            }
        }
    }

    private func resolveURLPrefill() {
        resolvingID = "url"
        let trimmed = trimmedSearch
        Task {
            let normalized = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)"
            var name = ""
            if let host = URLComponents(string: normalized)?.host,
               (host == "apps.apple.com" || host == "itunes.apple.com"),
               let appID = FaviconFetcher.appStoreID(from: normalized) {
                name = await FaviconFetcher.fetchAppStoreName(appID: appID) ?? ""
            } else if let host = URLComponents(string: normalized)?.host {
                name = Self.guessName(fromHost: host)
            }
            let icon = await FaviconFetcher.fetch(from: trimmed)
            let categoryRaw = name.isEmpty ? nil : AppCatalog.search(name, limit: 1).first?.category
            await MainActor.run {
                resolvingID = nil
                onSelectPrefill(AddEditPrefill(
                    name: name,
                    url: trimmed,
                    iconData: icon,
                    iconSource: icon != nil ? .favicon : .system,
                    categoryRaw: categoryRaw
                ))
            }
        }
    }

    private func resolveURLPrefillWithAI() {
        resolvingID = "url-ai"
        let trimmed = trimmedSearch
        Task {
            do {
                let result = try await URLLookupAnalyzer.lookup(url: trimmed)
                let name = (result.name?.isEmpty == false ? result.name : nil) ?? Self.guessName(
                    fromHost: URLComponents(string: trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)")?.host ?? trimmed
                )
                let icon = await FaviconFetcher.fetch(from: trimmed)
                let categoryRaw = AppCatalog.search(name, limit: 1).first?.category
                await MainActor.run {
                    resolvingID = nil
                    onSelectPrefill(AddEditPrefill(
                        name: name,
                        url: trimmed,
                        iconData: icon,
                        iconSource: icon != nil ? .favicon : .system,
                        categoryRaw: categoryRaw,
                        cost: result.cost,
                        currency: result.currency,
                        billingCycle: result.billingCycle
                    ))
                }
            } catch {
                // Silent fallback to the free no-AI URL route (locked decision).
                resolveURLPrefill()
            }
        }
    }

    private func lookupArtwork(appStoreId: String) async -> (artwork: Data?, trackViewUrl: String?) {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(appStoreId)&country=\(regionCode)") else {
            return (nil, nil)
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(AppStoreResponse.self, from: data),
              let first = decoded.results.first
        else { return (nil, nil) }
        let artwork = await fetchArtwork(urlString: first.artworkUrl512 ?? first.artworkUrl100)
        return (artwork, first.trackViewUrl)
    }

    private func fetchArtwork(urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url), FaviconFetcher.isImage(data) else { return nil }
        return data
    }

    private static func guessName(fromHost host: String) -> String {
        var h = host
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let base = h.split(separator: ".").first.map(String.init) ?? h
        guard let first = base.first else { return base }
        return first.uppercased() + base.dropFirst()
    }
}
