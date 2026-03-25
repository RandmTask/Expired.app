import Foundation

struct FaviconFetcher {
    static func fetch(from urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        guard let host = url.host ?? URL(string: "https://\(urlString)")?.host else { return nil }

        let candidates = [
            URL(string: "https://\(host)/favicon.ico"),
            URL(string: "http://\(host)/favicon.ico")
        ].compactMap { $0 }

        for candidate in candidates {
            if let data = try? await fetchData(from: candidate), !data.isEmpty {
                return data
            }
        }

        return nil
    }

    private static func fetchData(from url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return Data()
        }
        return data
    }
}
