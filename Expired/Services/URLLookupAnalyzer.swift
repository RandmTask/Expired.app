import Foundation

/// Server-side AI page reading for the Add Item hub's "Read Page with AI" route
/// (R2 Phase 2). Pro-gated by the shared `ai-proxy` entitlement check — same gate
/// as Screenshot Import — and shares its daily request cap. Any failure (network,
/// non-2xx, unparseable JSON) throws; the caller falls back to the no-AI URL route
/// rather than surfacing an error, per the locked decision to degrade silently.
enum URLLookupAnalyzer {
    struct Result {
        var name: String?
        var cost: Double?
        var currency: String?
        var billingCycle: BillingCycle?
    }

    enum AnalyzerError: Error {
        case httpError(status: Int)
        case emptyResult
    }

    static func lookup(url: String) async throws -> Result {
        var request = try await SupabaseService.shared.authorizedFunctionRequest(BackendConfig.Function.aiProxy)
        let payload: [String: Any] = ["mode": "auto", "url": url]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AnalyzerError.httpError(status: http.statusCode)
        }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providerID = object["provider"] as? String,
              let raw = object["raw"],
              let rawData = try? JSONSerialization.data(withJSONObject: raw)
        else { throw AnalyzerError.emptyResult }

        let content: String
        switch providerID {
        case "openai", "deepseek": content = openAIContent(from: rawData)
        case "claude": content = claudeContent(from: rawData)
        case "gemini": content = geminiContent(from: rawData)
        default: content = ""
        }

        guard let result = parseResult(content) else { throw AnalyzerError.emptyResult }
        return result
    }

    private static func parseResult(_ content: String) -> Result? {
        // Strip a ```json ... ``` fence if the model added one despite instructions.
        let cleaned = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cost = (object["price"] as? NSNumber)?.doubleValue
        let currency = (object["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cycle = (object["billingCycle"] as? String).flatMap(BillingCycle.init(wireValue:))

        guard (name?.isEmpty == false) || cost != nil else { return nil }
        return Result(
            name: name?.isEmpty == false ? name : nil,
            cost: cost,
            currency: (currency?.isEmpty == false) ? currency : nil,
            billingCycle: cycle
        )
    }

    private static func openAIContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    private static func claudeContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let content = object?["content"] as? [[String: Any]]
        return content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }

    private static func geminiContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
    }
}

private extension BillingCycle {
    init?(wireValue: String) {
        switch wireValue.lowercased() {
        case "weekly": self = .weekly
        case "monthly": self = .monthly
        case "yearly", "annual", "annually": self = .yearly
        default: return nil
        }
    }
}
