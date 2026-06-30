import Foundation
import Vision

#if canImport(FoundationModels)
import FoundationModels
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ScreenshotAIProvider: String, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case openAI = "ChatGPT"
    case gemini = "Gemini"
    case deepSeek = "DeepSeek"
    case claude = "Claude"

    var id: String { rawValue }

    /// UI label — avoids using Apple's trademark "Apple Intelligence" in the picker.
    var displayName: String {
        self == .appleIntelligence ? "On-Device" : rawValue
    }

    /// Legacy UserDefaults key — retained only for the one-time Keychain migration.
    var apiKeyDefaultsKey: String {
        "screenshotAI.apiKey.\(rawValue)"
    }

    /// Keychain account name for this provider's API key (per-device, never synced).
    var keychainAccount: String {
        "screenshotAI.apiKey.\(rawValue)"
    }

    var requiresAPIKey: Bool {
        self != .appleIntelligence
    }

    /// Stable identifier the Supabase `ai-proxy` / `models` functions use to pick the
    /// provider endpoint and inject the server-held key. nil for the on-device path,
    /// which is never proxied (and stays free).
    var proxyID: String? {
        switch self {
        case .openAI: return "openai"
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .deepSeek: return "deepseek"
        case .appleIntelligence: return nil
        }
    }

    /// Last-resort offline fallback model per provider. NOT the only source of
    /// truth — `selectedModelID` prefers the user's live-picked override (see the
    /// model picker in Settings). End state per `_shared/ai-providers.md`: a
    /// server-side default via the release proxy. Model IDs rot every few months.
    var defaultModelID: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .deepSeek: return "deepseek-chat"
        case .claude: return "claude-3-5-haiku-latest"
        case .gemini: return "gemini-2.5-flash"
        case .appleIntelligence: return ""
        }
    }

    /// Whether the provider's chosen model accepts image input. Vision providers
    /// receive the screenshot directly; text-only providers get OCR lines.
    var supportsVision: Bool {
        switch self {
        case .openAI, .claude, .gemini: return true
        case .deepSeek, .appleIntelligence: return false
        }
    }

    /// UserDefaults key holding the user's chosen model override for this provider.
    var modelDefaultsKey: String { "screenshotAI.model.\(rawValue)" }

    /// THE single source of truth for which model to call: the user's live-picked
    /// override if set, else the hardcoded default. Every call site resolves the
    /// model through here so a stale default never reaches the network alone.
    var selectedModelID: String {
        let stored = (UserDefaults.standard.string(forKey: modelDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? defaultModelID : stored
    }

    func setSelectedModelID(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultModelID {
            UserDefaults.standard.removeObject(forKey: modelDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: modelDefaultsKey)
        }
    }
}

struct ScreenshotAISettings {
    static let providerKey = "screenshotAI.provider"

    var provider: ScreenshotAIProvider
    var apiKey: String
    var modelID: String

    static var current: ScreenshotAISettings {
        let defaults = UserDefaults.standard
        let providerRaw = defaults.string(forKey: providerKey) ?? ScreenshotAIProvider.appleIntelligence.rawValue
        let provider = ScreenshotAIProvider(rawValue: providerRaw) ?? .appleIntelligence
        return ScreenshotAISettings(
            provider: provider,
            apiKey: KeychainStore.get(provider.keychainAccount),
            modelID: provider.selectedModelID
        )
    }

    /// Moves any API keys left in UserDefaults (from before keys were stored in
    /// the Keychain) into the Keychain once, then clears the plaintext copies.
    /// Safe to call on every launch — it no-ops after the first run.
    static func migrateAPIKeysToKeychainIfNeeded() {
        let defaults = UserDefaults.standard
        let flagKey = "screenshotAI.keychainMigrated"
        guard !defaults.bool(forKey: flagKey) else { return }

        for provider in ScreenshotAIProvider.allCases where provider.requiresAPIKey {
            let legacy = (defaults.string(forKey: provider.apiKeyDefaultsKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !legacy.isEmpty {
                KeychainStore.set(legacy, for: provider.keychainAccount)
            }
            defaults.removeObject(forKey: provider.apiKeyDefaultsKey)
        }
        defaults.set(true, forKey: flagKey)
    }
}

struct ScreenshotSubscriptionDraft: Identifiable, Hashable {
    enum ImportAction: String, CaseIterable {
        case updateExisting = "Update"
        case addNew = "Add"
        case skip = "Skip"
    }

    enum DetectionStatus: String {
        case active = "Active"
        case expiring = "Expiring"
        case expired = "Expired"
    }

    let id = UUID()
    var name: String
    var plan: String?
    var renewalDate: Date?
    var cost: Double?
    var currency: String
    var status: DetectionStatus
    var confidence: Double
    var matchedItemID: UUID?
    var matchedItemName: String?
    var action: ImportAction

    var hasMatch: Bool { matchedItemID != nil }
}

#if canImport(FoundationModels)
/// Structured output for the on-device Apple Intelligence path. Guided output
/// constrains the model to this shape, removing the need to parse loose JSON.
@Generable
struct AIDetectedSubscription {
    @Guide(description: "Service or app name only — never a plan, tier, or pricing word")
    let name: String
    @Guide(description: "Plan or tier label such as 'Student' or 'Pro'; empty string if none")
    let plan: String
    @Guide(description: "Renewal or expiry date as YYYY-MM-DD; empty string if none shown")
    let date: String
    @Guide(description: "Numeric price without currency symbol; 0 if no price shown")
    let cost: Double
    @Guide(description: "Three-letter ISO currency code such as USD")
    let currency: String
    @Guide(description: "Exactly one of: Active, Expiring, Expired")
    let status: String
    @Guide(description: "Confidence from 0.0 to 1.0 that this is a real subscription")
    let confidence: Double
}

@Generable
struct AIDetectionResult {
    @Guide(description: "Every distinct subscription found, deduplicated")
    let subscriptions: [AIDetectedSubscription]
}
#endif

enum ScreenshotImportAnalyzer {
    enum AnalyzerError: LocalizedError {
        case appleIntelligenceUnavailable
        case httpError(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .appleIntelligenceUnavailable:
                return "Apple Intelligence isn't available on this device. Choose another analyzer in Settings, or add an API key."
            case .httpError(let status, let message):
                if let message, !message.isEmpty {
                    return "HTTP \(status): \(message)"
                }
                return "HTTP \(status)"
            }
        }
    }

    /// Performs the request and throws on a non-2xx status, surfacing the provider's
    /// error message when present. Without this, an invalid key or quota failure
    /// returns an error body that parses to empty drafts and silently degrades.
    private static func sendForData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw AnalyzerError.httpError(status: http.statusCode, message: providerErrorMessage(from: data))
        }
        return data
    }

    /// Sends a provider request `body` through the Supabase `ai-proxy` (server holds the
    /// key, gates Premium, rate-limits, kill-switch). The proxy passes the provider's
    /// response straight through, so the existing per-provider parsers work unchanged.
    private static func proxyForData(
        provider: ScreenshotAIProvider,
        model: String,
        body: [String: Any]
    ) async throws -> Data {
        guard let proxyID = provider.proxyID else {
            throw AnalyzerError.appleIntelligenceUnavailable
        }
        var request = try await SupabaseService.shared.authorizedFunctionRequest(BackendConfig.Function.aiProxy)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": proxyID,
            "model": model,
            "body": body
        ])
        return try await sendForData(request)
    }

    /// Extracts a human error message from a provider error payload.
    /// OpenAI / DeepSeek / Anthropic / Gemini all nest it under `error.message`.
    private static func providerErrorMessage(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let message = object["error"] as? String { return message }
        return nil
    }

    /// Result of an analysis pass. `warning` is non-nil when the chosen AI
    /// provider failed and the on-device heuristic was used instead — surfaced to
    /// the user so a silent fallback never masquerades as a real AI result.
    struct Result {
        var drafts: [ScreenshotSubscriptionDraft]
        var warning: String?
    }

    static func analyze(
        imageData: Data,
        existingItems: [SubscriptionItem],
        referenceDate: Date = Date()
    ) async throws -> Result {
        let settings = ScreenshotAISettings.current
        var warning: String?
        let drafts: [ScreenshotSubscriptionDraft]
        do {
            drafts = try await detect(imageData: imageData, settings: settings, referenceDate: referenceDate)
        } catch {
            // The selected AI path failed — degrade to the local heuristic, but
            // tell the user rather than passing off heuristic output as AI output.
            warning = fallbackWarning(for: settings.provider, error: error)
            drafts = parse(lines: try await ocrLines(from: imageData), referenceDate: referenceDate)
        }
        // Drop noise: a real subscription has at least a date or a price.
        let anchored = drafts.filter { $0.renewalDate != nil || $0.cost != nil }
        return Result(drafts: matchDuplicates(drafts: anchored, existingItems: existingItems), warning: warning)
    }

    /// Runs the provider chosen in Settings. Throws on failure (no internal
    /// fallback) so the caller can surface why the AI path didn't run.
    private static func detect(
        imageData: Data,
        settings: ScreenshotAISettings,
        referenceDate: Date
    ) async throws -> [ScreenshotSubscriptionDraft] {
        switch settings.provider {
        case .appleIntelligence:
            let lines = try await ocrLines(from: imageData)
            return try await parseWithAppleIntelligence(lines: lines, referenceDate: referenceDate)

        default:
            // The provider key now lives server-side: every remote call goes through the
            // Supabase proxy (Premium-gated, rate-limited). No on-device key to check.
            if settings.provider.supportsVision {
                // Vision models see the screenshot directly — visual grouping is
                // what disambiguates a plan ("Student") from its service.
                return try await parseWithRemoteVision(imageData: imageData, settings: settings, referenceDate: referenceDate)
            } else {
                let lines = try await ocrLines(from: imageData)
                return try await parseWithRemoteText(lines: lines, settings: settings, referenceDate: referenceDate)
            }
        }
    }

    private static func fallbackWarning(for provider: ScreenshotAIProvider, error: Error) -> String {
        if let analyzerError = error as? AnalyzerError {
            return analyzerError.localizedDescription + " Showing on-device results — review them carefully."
        }
        return "\(provider.rawValue) couldn't analyse the screenshot (\(error.localizedDescription)). Showing on-device results — review them carefully."
    }

    private static func ocrLines(from imageData: Data) async throws -> [String] {
        guard let cgImage = cgImage(from: imageData) else { return [] }
        return try await recognizeText(in: cgImage)
    }

    // MARK: - Shared prompt

    /// The structural understanding shared by every LLM path. Knowing the
    /// Apple Subscriptions screen is a sequence of name → plan → status → price
    /// blocks is what stops plan/tier lines from becoming phantom subscriptions.
    private static func analysisInstructions(referenceDate: Date) -> String {
        """
        You extract subscriptions from a screenshot of Apple's \
        Settings → [Apple Account] → Subscriptions screen (or the App Store \
        Subscriptions screen).

        STRUCTURE — the content is repeating blocks, top to bottom. Each \
        subscription is ONE block of consecutive lines in this order:
          1. Service name  — the app/service (e.g. "Apple Music", "ChatGPT")
          2. Plan/tier      — optional (e.g. "Student", "ChatGPT Plus", \
        "Clipboard AI Pro Yearly", "iCloud+ with 2 TB storage")
          3. Status line     — "Renews <date>", "Expiring <date>", "Expired <date>"
          4. Price           — optional (e.g. "$5.99")
        A new block begins only at the NEXT service name. One block = exactly one \
        subscription.

        HARD RULES
        - The service name is the FIRST line of a block only. A plan or tier line \
        is NEVER its own subscription. "Student", "PRO", "Premium", "Plus", \
        "...Yearly", "...Annual", "...with N TB storage", "<App> Subscription \
        Package" are PLANS — attach them to the service above, never emit alone.
        - Never emit a subscription whose name is a bare tier word \
        (Student/PRO/Premium/Plus/Basic/Standard).
        - Ignore UI chrome and OCR fragments: "Subscriptions", "Active", \
        "Inactive", "Sort", "Cancel", "Apply", "Detected", section headers, \
        truncated tokens like "SortT".
        - Merge near-duplicates that clearly refer to the same app \
        ("Zynotes" / "ZyNotes: Private Notes" → one item named "Zynotes").
        - status: "Renews" → Active; "Expiring" → Expiring; "Expired" → Expired.
        - Dates resolve to YYYY-MM-DD relative to the reference date. If the year \
        is missing, assume the next future occurrence. Empty if no date is shown.
        - confidence: 0.9+ only when name, status and date are present and \
        unambiguous; lower it honestly when inferring or fields are missing. \
        Never output a constant value.

        Reference date: \(isoDate(referenceDate)).
        """
    }

    /// Text-only / JSON wire variant of the prompt (DeepSeek, OCR fallback).
    private static func remoteTextPrompt(lines: [String], referenceDate: Date) -> String {
        analysisInstructions(referenceDate: referenceDate) + """


        Return ONLY a JSON array, no prose, in this shape:
        [{"name":"Service","plan":"plan or null","renewalDate":"YYYY-MM-DD or null","cost":12.34,"currency":"USD","status":"Active|Expiring|Expired","confidence":0.0}]

        OCR lines:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Vision variant — the model reads the image, so no OCR lines are sent.
    private static func remoteVisionPrompt(referenceDate: Date) -> String {
        analysisInstructions(referenceDate: referenceDate) + """


        Read the attached screenshot. Return ONLY a JSON array, no prose, in this shape:
        [{"name":"Service","plan":"plan or null","renewalDate":"YYYY-MM-DD or null","cost":12.34,"currency":"USD","status":"Active|Expiring|Expired","confidence":0.0}]
        """
    }

    // MARK: - Apple Intelligence (on-device)

    private static func parseWithAppleIntelligence(
        lines: [String],
        referenceDate: Date
    ) async throws -> [ScreenshotSubscriptionDraft] {
#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw AnalyzerError.appleIntelligenceUnavailable
        }
        let session = LanguageModelSession(instructions: analysisInstructions(referenceDate: referenceDate))
        let prompt = "OCR lines from the screenshot:\n" + lines.joined(separator: "\n")
        let response = try await session.respond(to: prompt, generating: AIDetectionResult.self)
        return response.content.subscriptions.compactMap { mapGenerated($0) }
#else
        throw AnalyzerError.appleIntelligenceUnavailable
#endif
    }

    // MARK: - Remote providers

    private static func parseWithRemoteText(
        lines: [String],
        settings: ScreenshotAISettings,
        referenceDate: Date
    ) async throws -> [ScreenshotSubscriptionDraft] {
        let prompt = remoteTextPrompt(lines: lines, referenceDate: referenceDate)
        let content = try await remoteTextResponse(prompt: prompt, settings: settings)
        return parseAIJSON(content)
    }

    private static func parseWithRemoteVision(
        imageData: Data,
        settings: ScreenshotAISettings,
        referenceDate: Date
    ) async throws -> [ScreenshotSubscriptionDraft] {
        let prompt = remoteVisionPrompt(referenceDate: referenceDate)
        let base64 = imageData.base64EncodedString()
        let mime = imageMimeType(imageData)
        let content: String
        switch settings.provider {
        case .openAI:
            content = try await openAIVisionResponse(prompt: prompt, base64: base64, mime: mime, settings: settings)
        case .claude:
            content = try await claudeVisionResponse(prompt: prompt, base64: base64, mime: mime, settings: settings)
        case .gemini:
            content = try await geminiVisionResponse(prompt: prompt, base64: base64, mime: mime, settings: settings)
        default:
            return []
        }
        return parseAIJSON(content)
    }

    private static func remoteTextResponse(prompt: String, settings: ScreenshotAISettings) async throws -> String {
        // OpenAI + DeepSeek share the chat-completions body shape; the proxy routes by provider.
        let body: [String: Any] = [
            "model": settings.modelID,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "You extract subscription data and return JSON only."],
                ["role": "user", "content": prompt]
            ]
        ]
        let data = try await proxyForData(provider: settings.provider, model: settings.modelID, body: body)
        return openAIContent(from: data)
    }

    private static func openAIVisionResponse(prompt: String, base64: String, mime: String, settings: ScreenshotAISettings) async throws -> String {
        let body: [String: Any] = [
            "model": settings.modelID,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "You extract subscription data and return JSON only."],
                ["role": "user", "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(base64)"]]
                ]]
            ]
        ]
        let data = try await proxyForData(provider: .openAI, model: settings.modelID, body: body)
        return openAIContent(from: data)
    }

    private static func claudeVisionResponse(prompt: String, base64: String, mime: String, settings: ScreenshotAISettings) async throws -> String {
        let body: [String: Any] = [
            "model": settings.modelID,
            "max_tokens": 1200,
            "temperature": 0,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": prompt],
                ["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]]
            ]]]
        ]
        let data = try await proxyForData(provider: .claude, model: settings.modelID, body: body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = object?["content"] as? [[String: Any]]
        return content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "[]"
    }

    private static func geminiVisionResponse(prompt: String, base64: String, mime: String, settings: ScreenshotAISettings) async throws -> String {
        // Gemini puts the model in the URL — the proxy builds that from the envelope's
        // `model`, so the body carries only contents + generationConfig.
        let body: [String: Any] = [
            "contents": [["parts": [
                ["text": prompt],
                ["inline_data": ["mime_type": mime, "data": base64]]
            ]]],
            "generationConfig": ["temperature": 0]
        ]
        let data = try await proxyForData(provider: .gemini, model: settings.modelID, body: body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "[]"
    }

    private static func openAIContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? "[]"
    }

    private static func imageMimeType(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    // MARK: - Wire decoding

    private struct AIDraft: Decodable {
        let name: String
        let plan: String?
        let renewalDate: String?
        let cost: Double?
        let currency: String?
        let status: String?
        let confidence: Double?
    }

    private static func parseAIJSON(_ content: String) -> [ScreenshotSubscriptionDraft] {
        let trimmed = extractJSONArray(from: content)
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AIDraft].self, from: data)
        else { return [] }

        return decoded.compactMap { draft in
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isTierWordOnly(name) else { return nil }
            return ScreenshotSubscriptionDraft(
                name: normalizedDisplayName(name),
                plan: cleanedPlan(draft.plan),
                renewalDate: draft.renewalDate.flatMap(parseISODate),
                cost: draft.cost.flatMap { $0 > 0 ? $0 : nil },
                currency: draft.currency?.uppercased() ?? "USD",
                status: detectionStatus(from: draft.status),
                confidence: min(max(draft.confidence ?? 0.8, 0), 1),
                matchedItemID: nil,
                matchedItemName: nil,
                action: .addNew
            )
        }
    }

#if canImport(FoundationModels)
    private static func mapGenerated(_ draft: AIDetectedSubscription) -> ScreenshotSubscriptionDraft? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isTierWordOnly(name) else { return nil }
        return ScreenshotSubscriptionDraft(
            name: normalizedDisplayName(name),
            plan: cleanedPlan(draft.plan),
            renewalDate: draft.date.isEmpty ? nil : parseISODate(draft.date),
            cost: draft.cost > 0 ? draft.cost : nil,
            currency: draft.currency.isEmpty ? "USD" : draft.currency.uppercased(),
            status: detectionStatus(from: draft.status),
            confidence: min(max(draft.confidence, 0), 1),
            matchedItemID: nil,
            matchedItemName: nil,
            action: .addNew
        )
    }
#endif

    /// Guard against a tier word slipping through as a name (e.g. "Student").
    private static func isTierWordOnly(_ name: String) -> Bool {
        let tierWords: Set<String> = ["student", "pro", "premium", "plus", "basic", "standard"]
        return tierWords.contains(name.lowercased())
    }

    private static func cleanedPlan(_ plan: String?) -> String? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !plan.isEmpty else { return nil }
        return plan
    }

    private static func extractJSONArray(from content: String) -> String {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"),
              start <= end
        else { return "[]" }
        return String(content[start...end])
    }

    private static func detectionStatus(from raw: String?) -> ScreenshotSubscriptionDraft.DetectionStatus {
        switch raw?.lowercased() {
        case "expired": return .expired
        case "expiring": return .expiring
        default: return .active
        }
    }

    nonisolated private static func parseISODate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func recognizeText(in cgImage: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap {
                    $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }

                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func parse(lines: [String], referenceDate: Date) -> [ScreenshotSubscriptionDraft] {
        var drafts: [ScreenshotSubscriptionDraft] = []
        let serviceLines = lines.enumerated().filter { _, line in
            looksLikeServiceName(line)
        }

        for (index, line) in serviceLines {
            let window = lines[index..<min(lines.count, index + 5)].map { $0 }
            let renewalLine = window.first { containsRenewalSignal($0) }
            let priceLine = window.first { extractPrice(from: $0) != nil }
            let price = priceLine.flatMap { extractPrice(from: $0) }
            let status = status(from: renewalLine)
            let date = renewalLine.flatMap { extractDate(from: $0, referenceDate: referenceDate) }
            let plan = window.dropFirst().first {
                !containsRenewalSignal($0) && extractPrice(from: $0) == nil && looksLikePlan($0)
            }

            guard renewalLine != nil || price != nil else { continue }

            drafts.append(
                ScreenshotSubscriptionDraft(
                    name: normalizedDisplayName(line),
                    plan: plan,
                    renewalDate: date,
                    cost: price?.amount,
                    currency: price?.currency ?? "USD",
                    status: status,
                    confidence: confidence(renewalLine: renewalLine, price: price),
                    matchedItemID: nil,
                    matchedItemName: nil,
                    action: .addNew
                )
            )
        }

        return unique(drafts)
    }

    private static func matchDuplicates(
        drafts: [ScreenshotSubscriptionDraft],
        existingItems: [SubscriptionItem]
    ) -> [ScreenshotSubscriptionDraft] {
        drafts.map { draft in
            var copy = draft
            if let match = bestMatch(for: draft, in: existingItems) {
                copy.matchedItemID = match.id
                copy.matchedItemName = match.name
                copy.action = .updateExisting
            } else if draft.confidence < 0.5 {
                // Low-confidence, unmatched rows default to Skip — the user opts
                // in rather than having questionable items added silently.
                copy.action = .skip
            }
            return copy
        }
    }

    private static func bestMatch(
        for draft: ScreenshotSubscriptionDraft,
        in existingItems: [SubscriptionItem]
    ) -> SubscriptionItem? {
        let draftKey = canonicalName(draft.name)
        let candidates = existingItems.filter { $0.itemType == .subscription }

        if let exact = candidates.first(where: { canonicalName($0.name) == draftKey }) {
            return exact
        }

        return candidates
            .map { item in (item, similarity(draftKey, canonicalName(item.name))) }
            .filter { $0.1 >= 0.72 }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func unique(_ drafts: [ScreenshotSubscriptionDraft]) -> [ScreenshotSubscriptionDraft] {
        var seen = Set<String>()
        var result: [ScreenshotSubscriptionDraft] = []
        for draft in drafts {
            let key = canonicalName(draft.name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(draft)
        }
        return result
    }

    private static func looksLikeServiceName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 80 else { return false }
        guard !containsRenewalSignal(trimmed), extractPrice(from: trimmed) == nil else { return false }
        let lower = trimmed.lowercased()
        let blocked = ["active", "inactive", "subscriptions", "settings", "sort", "search"]
        guard !blocked.contains(lower) else { return false }
        return trimmed.rangeOfCharacter(from: .letters) != nil
    }

    private static func looksLikePlan(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("plus") ||
            lower.contains("premium") ||
            lower.contains("student") ||
            lower.contains("yearly") ||
            lower.contains("monthly") ||
            lower.contains("subscription") ||
            lower.contains("storage") ||
            lower.contains("pro")
    }

    private static func containsRenewalSignal(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("renews") || lower.contains("expiring") || lower.contains("expired")
    }

    private static func status(from line: String?) -> ScreenshotSubscriptionDraft.DetectionStatus {
        let lower = line?.lowercased() ?? ""
        if lower.contains("expired") { return .expired }
        if lower.contains("expiring") { return .expiring }
        return .active
    }

    private static func confidence(
        renewalLine: String?,
        price: (amount: Double, currency: String)?
    ) -> Double {
        switch (renewalLine != nil, price != nil) {
        case (true, true): return 0.92
        case (true, false): return 0.78
        case (false, true): return 0.64
        case (false, false): return 0.4
        }
    }

    private static func extractPrice(from line: String) -> (amount: Double, currency: String)? {
        let pattern = #"(?:(A\$|US\$|\$|€|£)\s?)([0-9]+(?:\.[0-9]{1,2})?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let symbolRange = Range(match.range(at: 1), in: line),
              let amountRange = Range(match.range(at: 2), in: line),
              let amount = Double(line[amountRange])
        else { return nil }

        let currency: String
        switch String(line[symbolRange]) {
        case "A$": currency = "AUD"
        case "US$", "$": currency = "USD"
        case "€": currency = "EUR"
        case "£": currency = "GBP"
        default: currency = "USD"
        }
        return (amount, currency)
    }

    private static func extractDate(from line: String, referenceDate: Date) -> Date? {
        let months = DateFormatter().monthSymbols ?? []
        let escaped = months.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = #"(?:renews|expiring|expired)\s+("# + escaped + #")\s+([0-9]{1,2})(?:,\s*([0-9]{4}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let monthRange = Range(match.range(at: 1), in: line),
              let dayRange = Range(match.range(at: 2), in: line),
              let day = Int(line[dayRange])
        else { return nil }

        let monthName = String(line[monthRange]).lowercased()
        guard let monthIndex = months.firstIndex(where: { $0.lowercased() == monthName }) else { return nil }

        let cal = Calendar.current
        let year: Int
        if match.range(at: 3).location != NSNotFound,
           let yearRange = Range(match.range(at: 3), in: line),
           let parsedYear = Int(line[yearRange]) {
            year = parsedYear
        } else {
            var candidateYear = cal.component(.year, from: referenceDate)
            var comps = DateComponents(year: candidateYear, month: monthIndex + 1, day: day)
            if let candidate = cal.date(from: comps),
               candidate < cal.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate {
                candidateYear += 1
                comps.year = candidateYear
            }
            year = candidateYear
        }

        return cal.date(from: DateComponents(year: year, month: monthIndex + 1, day: day))
    }

    private static func normalizedDisplayName(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generic name normalisation for duplicate matching: lowercase, strip
    /// non-alphanumerics, and drop generic plan/marketing words. No app-specific
    /// special-cases — the analyzer now separates plan from service name, so a
    /// hardcoded swap table is no longer needed.
    static func canonicalName(_ value: String) -> String {
        let stopWords: Set<String> = [
            "pro", "premium", "student", "subscription", "package",
            "plus", "annual", "yearly", "monthly", "storage", "with"
        ]
        return value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
            .joined()
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        if lhs.contains(rhs) || rhs.contains(lhs) { return 0.9 }

        let distance = levenshtein(lhs, rhs)
        let maxLength = max(lhs.count, rhs.count)
        return 1 - (Double(distance) / Double(maxLength))
    }

    private static func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)

        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }

        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
            }
        }

        return matrix[a.count][b.count]
    }

    private static func cgImage(from data: Data) -> CGImage? {
#if os(iOS)
        return UIImage(data: data)?.cgImage
#elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
#endif
    }
}
