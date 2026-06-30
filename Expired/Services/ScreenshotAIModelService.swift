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

    /// Fetches the provider's available models via the Supabase `models` function (the
    /// server holds the key). `apiKey` is accepted for call-site compatibility but no
    /// longer used — the on-device key path is gone.
    static func listModels(provider: ScreenshotAIProvider, apiKey: String = "") async throws -> [String] {
        guard let proxyID = provider.proxyID else { throw ModelServiceError.unsupported }

        var request = try await SupabaseService.shared.authorizedFunctionRequest(BackendConfig.Function.models)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["provider": proxyID])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        switch provider {
        case .openAI:
            return dataArrayIDs(data).filter { $0.hasPrefix("gpt") || $0.hasPrefix("o") }
        case .gemini:
            return geminiGenerateContentModels(data)
        default:
            return dataArrayIDs(data)
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
}
