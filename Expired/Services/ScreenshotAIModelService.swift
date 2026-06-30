import Foundation

/// Fetches the list of models a provider's key can actually use right now, so the
/// Settings model picker never strands the user on a stale hardcoded default.
/// Endpoint shapes are stable; model ID strings are not — always fetch, never guess.
enum ScreenshotAIModelService {
    enum ModelServiceError: LocalizedError {
        case unsupported
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "This provider doesn't expose a model list."
            case let .http(code, body):
                let detail = body.isEmpty ? "" : " — \(body.prefix(200))"
                return "Couldn't load models (HTTP \(code))\(detail)"
            }
        }
    }

    static func listModels(provider: ScreenshotAIProvider, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        switch provider {
        case .appleIntelligence:
            throw ModelServiceError.unsupported
        case .openAI:
            let data = try await httpGET("https://api.openai.com/v1/models", headers: ["Authorization": "Bearer \(key)"])
            return dataArrayIDs(data).filter { $0.hasPrefix("gpt") || $0.hasPrefix("o") }
        case .deepSeek:
            let data = try await httpGET("https://api.deepseek.com/models", headers: ["Authorization": "Bearer \(key)"])
            return dataArrayIDs(data)
        case .claude:
            let data = try await httpGET(
                "https://api.anthropic.com/v1/models?limit=100",
                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"]
            )
            return dataArrayIDs(data)
        case .gemini:
            let data = try await httpGET(
                "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)&pageSize=200",
                headers: [:]
            )
            return geminiGenerateContentModels(data)
        }
    }

    // MARK: - Decoding (each provider its own shape)

    /// `{ "data": [ { "id": "..." } ] }` — OpenAI, DeepSeek, Anthropic.
    private static func dataArrayIDs(_ data: Data) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = object?["data"] as? [[String: Any]] ?? []
        let ids = items.compactMap { $0["id"] as? String }
        return ids.sorted()
    }

    /// `{ "models": [ { "name": "models/...", "supportedGenerationMethods": [...] } ] }`
    private static func geminiGenerateContentModels(_ data: Data) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = object?["models"] as? [[String: Any]] ?? []
        let ids = items.compactMap { model -> String? in
            let methods = model["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent"), let name = model["name"] as? String else { return nil }
            return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        }
        return ids.sorted()
    }

    // MARK: - Shared GET

    private static func httpGET(_ urlString: String, headers: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ModelServiceError.http(-1, "bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
