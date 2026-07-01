import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

#if canImport(FoundationModels)
import FoundationModels
#endif

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum ScreenshotAIProvider: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
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
        self != .appleIntelligence && self != .automatic
    }

    /// Stable identifier the Supabase `ai-proxy` / `models` functions use to pick the
    /// provider endpoint and inject the server-held key. nil for the on-device path
    /// (never proxied) and for Automatic (the server picks the cascade itself).
    var proxyID: String? {
        switch self {
        case .openAI: return "openai"
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .deepSeek: return "deepseek"
        case .appleIntelligence, .automatic: return nil
        }
    }

    /// Last-resort offline fallback model per provider. NOT the only source of
    /// truth — `selectedModelID` prefers the user's live-picked override (see the
    /// model picker in Settings). Automatic ignores this entirely: the cascade's
    /// model per provider is resolved server-side from `app_config`, editable
    /// without a release. Model IDs rot every few months.
    var defaultModelID: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .deepSeek: return "deepseek-chat"
        case .claude: return "claude-3-5-haiku-latest"
        case .gemini: return "gemini-2.5-flash"
        case .appleIntelligence, .automatic: return ""
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
        let providerRaw = defaults.string(forKey: providerKey) ?? ScreenshotAIProvider.automatic.rawValue
        let provider = ScreenshotAIProvider(rawValue: providerRaw) ?? .automatic
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
    var billingCycle: BillingCycle = .monthly
    var appStoreURL: String?
    var iconData: Data?
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

    /// Extracts a human error message from a provider error payload.
    /// OpenAI / DeepSeek / Anthropic / Gemini all nest it under `error.message`.
    /// The proxy's cascade failure additionally nests `error.tried`, naming every
    /// provider it attempted — surfaced so a real outage reads differently from
    /// "this wasn't a subscription screenshot".
    private static func providerErrorMessage(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String
            if let tried = error["tried"] as? [[String: Any]], !tried.isEmpty {
                let names = tried.compactMap { $0["provider"] as? String }
                if !names.isEmpty { return "\(names.joined(separator: ", ")) unreachable." }
            }
            return message
        }
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

    private struct RecognizedTextLine {
        let text: String
        let boundingBox: CGRect
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
        let recognizedLines = try? await recognizedTextLines(from: imageData)
        let localPurchaseDrafts: [ScreenshotSubscriptionDraft] = recognizedLines.map { lines in
            let reportProblemDrafts = parseReportProblemHistory(lines: lines, referenceDate: referenceDate)
            return reportProblemDrafts.isEmpty
                ? parsePurchaseHistory(lines: lines, referenceDate: referenceDate)
                : reportProblemDrafts
        } ?? []
        let detectedDrafts = localPurchaseDrafts.isEmpty
            ? repairPlanOnlyNames(in: drafts, recognizedLines: recognizedLines ?? [])
            : localPurchaseDrafts
        let priceRepaired = repairMissingPrices(in: detectedDrafts, recognizedLines: recognizedLines ?? [])
        // Drop noise: a real subscription has at least a date or a price.
        let anchored = deduplicatedRecurring(priceRepaired.filter { $0.renewalDate != nil || $0.cost != nil })
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

        case .automatic:
            // Try on-device first (free, private); only reach the proxy's cascade
            // (Gemini → DeepSeek, server-configured) if that fails or is unavailable.
            do {
                let lines = try await ocrLines(from: imageData)
                return try await parseWithAppleIntelligence(lines: lines, referenceDate: referenceDate)
            } catch {
                return try await parseWithProxy(mode: .auto, provider: nil, model: nil, imageData: imageData, referenceDate: referenceDate)
            }

        default:
            // Manual/debug override — forces one named provider through the proxy,
            // bypassing the cascade. The provider key lives server-side; no on-device
            // key to check.
            return try await parseWithProxy(mode: .forced, provider: settings.provider, model: settings.modelID, imageData: imageData, referenceDate: referenceDate)
        }
    }

    private static func fallbackWarning(for provider: ScreenshotAIProvider, error: Error) -> String {
        if let analyzerError = error as? AnalyzerError {
            if case .httpError(let status, _) = analyzerError, status == 402 {
                return "Expired Pro could not be verified by the AI server yet. Restore purchases, then try again. Showing on-device results — review them carefully."
            }
            return analyzerError.localizedDescription + " Showing on-device results — review them carefully."
        }
        return "\(provider.rawValue) couldn't analyse the screenshot (\(error.localizedDescription)). Showing on-device results — review them carefully."
    }

    private static func ocrLines(from imageData: Data) async throws -> [String] {
        try await recognizedTextLines(from: imageData).map(\.text)
    }

    private static func recognizedTextLines(from imageData: Data) async throws -> [RecognizedTextLine] {
        guard let cgImage = cgImage(from: imageData) else { return [] }
        return try await recognizeTextLines(in: cgImage)
    }

    // MARK: - Shared prompt

    /// The structural understanding shared by every LLM path. Knowing the
    /// Apple Subscriptions screen is a sequence of name → plan → status → price
    /// blocks is what stops plan/tier lines from becoming phantom subscriptions.
    private static func analysisInstructions(referenceDate: Date) -> String {
        """
        You extract subscriptions from a screenshot of Apple's \
        Settings → [Apple Account] → Subscriptions screen, the App Store \
        Subscriptions screen, or Apple Purchase History.

        STRUCTURE — the content is repeating blocks, top to bottom. Each \
        subscription-list item is ONE block of consecutive lines in this order:
          1. Service name  — the app/service (e.g. "Apple Music", "ChatGPT")
          2. Plan/tier      — optional (e.g. "Student", "ChatGPT Plus", \
        "Clipboard AI Pro Yearly", "iCloud+ with 2 TB storage")
          3. Status line     — "Renews <date>", "Expiring <date>", "Expired <date>"
          4. Price           — optional (e.g. "$5.99")
        A new block begins only at the NEXT service name. One block = exactly one \
        subscription.
        Prices are often right-aligned on the same visual row as the service block; \
        attach that right-column price to the current subscription even if OCR/model \
        reading order places it before or after nearby text.

        PURCHASE HISTORY STRUCTURE — the screen title is "Purchase History" and \
        rows are grouped under purchase dates. Each card has a product/service \
        name, the word "Subscription", a price, and a "Total" row. These rows are \
        historical receipts, so repeated monthly charges for the same service are \
        recurring duplicates. Emit ONLY the newest visible receipt for each unique \
        service. Use the purchase date plus the inferred billing cycle as \
        renewalDate where possible. Ignore "Total" rows.

        REPORT A PROBLEM STRUCTURE — reportaproblem.apple.com rows show:
          1. Plan/product name (e.g. "ChatGPT Plus", "Clipboard AI Pro Yearly")
          2. App/service name (e.g. "ChatGPT", "Clipboard AI - Paste Keyboard")
          3. Either "Renews <date>", "Expires: <date>", or a paid access range \
        like "Nov 1, 2025 - Dec 1, 2025"
          4. A right-column item price
        For this source, the app/service name is line 2 and the plan is line 1. \
        Preserve punctuation in app names, especially hyphens. Ignore free app \
        downloads and rows without a renewal/expiry/access-range line.

        HARD RULES
        - The service name is the FIRST line of a block only. A plan or tier line \
        is NEVER its own subscription. "Student", "PRO", "Premium", "Plus", \
        "...Yearly", "...Annual", "...with N TB storage", "<App> Subscription \
        Package" are PLANS — attach them to the service above, never emit alone.
        - Never emit a subscription whose name is a bare tier word \
        (Student/PRO/Premium/Plus/Basic/Standard).
        - Ignore UI chrome and OCR fragments: "Subscriptions", "Active", \
        "Inactive", "Purchase History", "Showing", "Sort", "Cancel", "Apply", \
        "Detected", section headers, search placeholders, "Total", truncated \
        tokens like "SortT".
        - Merge near-duplicates that clearly refer to the same app \
        ("Zynotes" / "ZyNotes: Private Notes" → one item named "Zynotes").
        - In Purchase History, silently drop recurring duplicates; never emit \
        Apple Music five times just because five receipts are visible.
        - status: "Renews" → Active; "Expiring"/"Expires" → Expiring; \
        "Expired" or a past date range → Expired.
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

    private enum ProxyMode: String {
        case auto, forced
    }

    /// The one remote call path, for both "Automatic" (server-side cascade, tries
    /// `app_config.ai_fallback_order` in sequence) and a forced single provider
    /// (manual override picker). The proxy now builds each provider's request body
    /// itself — see `providers.ts` `buildRequestBody` — since a cascade may need to
    /// try a second provider's shape without a client round trip in between. The
    /// client always sends both prompt variants + the image; the server picks
    /// whichever fits the provider it's actually calling.
    private static func parseWithProxy(
        mode: ProxyMode,
        provider: ScreenshotAIProvider?,
        model: String?,
        imageData: Data,
        referenceDate: Date
    ) async throws -> [ScreenshotSubscriptionDraft] {
        let lines = try await ocrLines(from: imageData)
        let visionPrompt = remoteVisionPrompt(referenceDate: referenceDate)
        let textPrompt = remoteTextPrompt(lines: lines, referenceDate: referenceDate)
        let upload = uploadImagePayload(from: imageData)

        var payload: [String: Any] = [
            "mode": mode.rawValue,
            "visionPrompt": visionPrompt,
            "textPrompt": textPrompt,
            "image": ["mime": upload.mime, "base64": upload.base64]
        ]
        if mode == .forced, let proxyID = provider?.proxyID {
            payload["provider"] = proxyID
            if let model, !model.isEmpty { payload["model"] = model }
        }

        var request = try await SupabaseService.shared.authorizedFunctionRequest(BackendConfig.Function.aiProxy)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await sendForData(request)
        return parseProxyResponse(data)
    }

    /// The proxy replies `{"provider": "<id>", "raw": <upstream JSON>}` — `raw` keeps
    /// each provider's native shape, so the extractor below still matches its own.
    private static func parseProxyResponse(_ data: Data) -> [ScreenshotSubscriptionDraft] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let providerID = object["provider"] as? String,
              let raw = object["raw"],
              let rawData = try? JSONSerialization.data(withJSONObject: raw)
        else { return [] }

        let content: String
        switch providerID {
        case "openai", "deepseek":
            content = openAIContent(from: rawData)
        case "claude":
            content = claudeContent(from: rawData)
        case "gemini":
            content = geminiContent(from: rawData)
        default:
            content = "[]"
        }
        return parseAIJSON(content)
    }

    private static func openAIContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? "[]"
    }

    private static func claudeContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let content = object?["content"] as? [[String: Any]]
        return content?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "[]"
    }

    private static func geminiContent(from data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]]
        let content = candidates?.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        return parts?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? "[]"
    }

    private static func imageMimeType(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    /// Vision-model providers price images roughly by pixel-tile count, so a
    /// full-resolution phone screenshot (often 1200×2600+) costs far more than the
    /// text actually needs — the source table this was scoped against showed a
    /// ~1024px-wide JPEG costing a fraction of a full-HD upload. This is the copy
    /// sent over the network only; on-device Vision-framework OCR (`ocrLines`,
    /// price/plan repair heuristics) still runs against the original full-res data.
    private static func uploadImagePayload(from imageData: Data) -> (mime: String, base64: String) {
        guard let cgImage = cgImage(from: imageData),
              let base64 = downscaledJPEGBase64(from: cgImage)
        else { return (imageMimeType(imageData), imageData.base64EncodedString()) }
        return ("image/jpeg", base64)
    }

    private static func downscaledJPEGBase64(
        from cgImage: CGImage,
        maxDimension: CGFloat = 1024,
        quality: CGFloat = 0.8
    ) -> String? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(1, Int(width * scale))
        let targetHeight = max(1, Int(height * scale))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaledImage = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaledImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data).base64EncodedString()
    }

    // MARK: - Wire decoding

    private struct FlexiblePrice: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let double = try? container.decode(Double.self) {
                value = double
                return
            }
            let raw = try container.decode(String.self)
            let normalized = raw
                .replacingOccurrences(of: ",", with: ".")
                .filter { $0.isNumber || $0 == "." }
            value = Double(normalized) ?? 0
        }
    }

    private struct AIDraft: Decodable {
        let name: String
        let plan: String?
        let renewalDate: String?
        let cost: FlexiblePrice?
        let price: FlexiblePrice?
        let currency: String?
        let status: String?
        let confidence: Double?

        var amount: Double? {
            cost?.value ?? price?.value
        }
    }

    private static func parseAIJSON(_ content: String) -> [ScreenshotSubscriptionDraft] {
        let trimmed = extractJSONArray(from: content)
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AIDraft].self, from: data)
        else { return [] }

        return decoded.compactMap { draft in
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isTierWordOnly(name) else { return nil }
            let amount = draft.amount
            return ScreenshotSubscriptionDraft(
                name: normalizedDisplayName(name),
                plan: cleanedPlan(draft.plan),
                renewalDate: draft.renewalDate.flatMap(parseISODate),
                cost: amount.flatMap { $0 > 0 ? $0 : nil },
                currency: draft.currency?.uppercased() ?? "USD",
                billingCycle: inferredBillingCycle(name: name, plan: draft.plan),
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
            billingCycle: inferredBillingCycle(name: name, plan: draft.plan),
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

    private static func recognizeTextLines(in cgImage: CGImage) async throws -> [RecognizedTextLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines: [RecognizedTextLine] = observations.compactMap { observation -> RecognizedTextLine? in
                    let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !text.isEmpty else { return nil }
                    return RecognizedTextLine(text: text, boundingBox: observation.boundingBox)
                }

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
                    billingCycle: inferredBillingCycle(name: line, plan: plan),
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

    private static func repairPlanOnlyNames(
        in drafts: [ScreenshotSubscriptionDraft],
        recognizedLines lines: [RecognizedTextLine]
    ) -> [ScreenshotSubscriptionDraft] {
        guard !lines.isEmpty else { return drafts }

        return drafts.map { draft in
            guard nameLooksLikePlanLine(draft.name, plan: draft.plan),
                  let planLine = matchingPlanLine(for: draft, lines: lines),
                  let serviceLine = nearestServiceLine(above: planLine, lines: lines) else {
                return draft
            }

            var repaired = draft
            repaired.name = normalizedServiceDisplayName(serviceLine.text)
            repaired.plan = cleanedPlan(draft.plan) ?? normalizedDisplayName(draft.name)
            repaired.billingCycle = inferredBillingCycle(name: repaired.name, plan: repaired.plan)
            return repaired
        }
    }

    private static func nameLooksLikePlanLine(_ name: String, plan: String?) -> Bool {
        let normalizedName = normalizedDisplayName(name).lowercased()
        let normalizedPlan = normalizedDisplayName(plan ?? "").lowercased()
        guard !normalizedName.isEmpty else { return false }
        if normalizedName == normalizedPlan { return true }
        return looksLikePlan(normalizedName) &&
            (normalizedName.contains("yearly") ||
             normalizedName.contains("annual") ||
             normalizedName.contains("monthly") ||
             normalizedName.contains("weekly") ||
             normalizedName.contains(" pro"))
    }

    private static func matchingPlanLine(
        for draft: ScreenshotSubscriptionDraft,
        lines: [RecognizedTextLine]
    ) -> RecognizedTextLine? {
        let names = [draft.name, draft.plan ?? ""]
            .map(normalizedDisplayName)
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }

        if let exact = lines.first(where: { line in
            let text = normalizedDisplayName(line.text)
            return names.contains { text.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }) {
            return exact
        }

        return lines
            .compactMap { line -> (line: RecognizedTextLine, score: Double)? in
                guard looksLikePlan(line.text) else { return nil }
                let score = names.map { similarity(canonicalName($0), canonicalName(line.text)) }.max() ?? 0
                return score >= 0.82 ? (line, score) : nil
            }
            .max { $0.score < $1.score }?
            .line
    }

    private static func nearestServiceLine(
        above planLine: RecognizedTextLine,
        lines: [RecognizedTextLine]
    ) -> RecognizedTextLine? {
        lines
            .filter { line in
                let verticalGap = line.boundingBox.midY - planLine.boundingBox.midY
                let sameColumn = abs(line.boundingBox.minX - planLine.boundingBox.minX) < 0.16 ||
                    abs(line.boundingBox.midX - planLine.boundingBox.midX) < 0.18
                return verticalGap > 0 &&
                    verticalGap < 0.10 &&
                    sameColumn &&
                    looksLikeServiceName(line.text) &&
                    !looksLikePlan(line.text) &&
                    !isTierWordOnly(normalizedDisplayName(line.text))
            }
            .min { lhs, rhs in
                lhs.boundingBox.midY - planLine.boundingBox.midY < rhs.boundingBox.midY - planLine.boundingBox.midY
            }
    }

    private static func parseReportProblemHistory(
        lines: [RecognizedTextLine],
        referenceDate: Date
    ) -> [ScreenshotSubscriptionDraft] {
        guard isReportProblemHistoryScreenshot(lines) else { return [] }

        let orderedLines = lines.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                return lhs.boundingBox.midY > rhs.boundingBox.midY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }
        let priceLines = orderedLines.compactMap { line -> (line: RecognizedTextLine, price: (amount: Double, currency: String))? in
            guard let price = extractPrice(from: line.text) else { return nil }
            return (line, price)
        }

        let drafts = orderedLines.compactMap { planLine -> ScreenshotSubscriptionDraft? in
            guard looksLikeReportProblemPlanLine(planLine.text),
                  let appLine = nearestReportProblemLine(below: planLine, in: orderedLines),
                  let statusLine = nearestReportProblemStatusLine(below: appLine, in: orderedLines),
                  let renewal = reportProblemRenewal(from: statusLine.text, referenceDate: referenceDate) else {
                return nil
            }

            let plan = normalizedDisplayName(planLine.text)
            let name = normalizedServiceDisplayName(appLine.text)
            guard !name.isEmpty, !isTierWordOnly(name) else { return nil }

            let price = reportProblemItemPrice(for: planLine, priceLines: priceLines)
            let cycle = reportProblemBillingCycle(plan: plan, statusLine: statusLine.text, renewalDate: renewal.date)

            return ScreenshotSubscriptionDraft(
                name: name,
                plan: plan == name ? nil : plan,
                renewalDate: renewal.date,
                cost: price.flatMap { $0.amount > 0 ? $0.amount : nil },
                currency: price?.currency ?? "USD",
                billingCycle: cycle,
                status: renewal.status,
                confidence: price == nil ? 0.82 : 0.92,
                matchedItemID: nil,
                matchedItemName: nil,
                action: .addNew
            )
        }

        return deduplicatedRecurring(drafts)
    }

    private static func isReportProblemHistoryScreenshot(_ lines: [RecognizedTextLine]) -> Bool {
        let lower = lines.map { $0.text.lowercased() }
        if lower.contains(where: { $0.contains("reportaproblem.apple.com") }) { return true }
        let hasDateHeadings = lines.contains { extractStandaloneDate(from: $0.text, referenceDate: Date()) != nil }
        let hasTotals = lower.contains { $0.hasPrefix("total ") || $0 == "total" }
        let hasReportProblemStatus = lower.contains { line in
            line.contains("renews ") ||
                line.contains("expires") ||
                extractDateRangeEnd(from: line, referenceDate: Date()) != nil
        }
        return hasDateHeadings && hasTotals && hasReportProblemStatus
    }

    private static func nearestReportProblemLine(
        below planLine: RecognizedTextLine,
        in lines: [RecognizedTextLine]
    ) -> RecognizedTextLine? {
        lines
            .filter { line in
                let verticalGap = planLine.boundingBox.midY - line.boundingBox.midY
                let sameColumn = abs(line.boundingBox.minX - planLine.boundingBox.minX) < 0.16 ||
                    abs(line.boundingBox.midX - planLine.boundingBox.midX) < 0.18
                return verticalGap > 0 &&
                    verticalGap < 0.075 &&
                    sameColumn &&
                    looksLikeReportProblemAppLine(line.text)
            }
            .min { lhs, rhs in
                planLine.boundingBox.midY - lhs.boundingBox.midY < planLine.boundingBox.midY - rhs.boundingBox.midY
            }
    }

    private static func nearestReportProblemStatusLine(
        below appLine: RecognizedTextLine,
        in lines: [RecognizedTextLine]
    ) -> RecognizedTextLine? {
        lines
            .filter { line in
                let verticalGap = appLine.boundingBox.midY - line.boundingBox.midY
                let sameColumn = abs(line.boundingBox.minX - appLine.boundingBox.minX) < 0.16 ||
                    abs(line.boundingBox.midX - appLine.boundingBox.midX) < 0.18
                return verticalGap > 0 &&
                    verticalGap < 0.085 &&
                    sameColumn &&
                    isReportProblemStatusLine(line.text)
            }
            .min { lhs, rhs in
                appLine.boundingBox.midY - lhs.boundingBox.midY < appLine.boundingBox.midY - rhs.boundingBox.midY
            }
    }

    private static func reportProblemRenewal(
        from line: String,
        referenceDate: Date
    ) -> (date: Date, status: ScreenshotSubscriptionDraft.DetectionStatus)? {
        if let date = extractDate(from: line, referenceDate: referenceDate) {
            return (date, status(from: line))
        }
        if let endDate = extractDateRangeEnd(from: line, referenceDate: referenceDate) {
            let status: ScreenshotSubscriptionDraft.DetectionStatus = endDate < Calendar.current.startOfDay(for: referenceDate)
                ? .expired
                : .expiring
            return (endDate, status)
        }
        return nil
    }

    private static func reportProblemItemPrice(
        for planLine: RecognizedTextLine,
        priceLines: [(line: RecognizedTextLine, price: (amount: Double, currency: String))]
    ) -> (amount: Double, currency: String)? {
        let planMidY = planLine.boundingBox.midY
        return priceLines
            .filter { candidate in
                let box = candidate.line.boundingBox
                return abs(box.midY - planMidY) <= 0.035 &&
                    (box.minX > planLine.boundingBox.maxX || box.midX > 0.58)
            }
            .sorted { lhs, rhs in
                abs(lhs.line.boundingBox.midY - planMidY) < abs(rhs.line.boundingBox.midY - planMidY)
            }
            .first?
            .price
    }

    private static func reportProblemBillingCycle(
        plan: String,
        statusLine: String,
        renewalDate: Date
    ) -> BillingCycle {
        if let range = extractDateRange(from: statusLine, referenceDate: renewalDate) {
            let days = Calendar.current.dateComponents([.day], from: range.start, to: range.end).day ?? 0
            if days >= 330 { return .yearly }
            if days <= 10 { return .weekly }
            return .monthly
        }
        return inferredBillingCycle(name: plan, plan: plan)
    }

    private static func parsePurchaseHistory(
        lines: [RecognizedTextLine],
        referenceDate: Date
    ) -> [ScreenshotSubscriptionDraft] {
        guard isPurchaseHistoryScreenshot(lines) else { return [] }

        let dateHeadings = lines.compactMap { line -> (line: RecognizedTextLine, date: Date)? in
            guard let date = extractStandaloneDate(from: line.text, referenceDate: referenceDate) else { return nil }
            return (line, date)
        }
        guard !dateHeadings.isEmpty else { return [] }

        let priceLines = lines.compactMap { line -> (line: RecognizedTextLine, price: (amount: Double, currency: String))? in
            guard let price = extractPrice(from: line.text) else { return nil }
            return (line, price)
        }

        let candidates = lines
            .filter { looksLikePurchaseHistoryItemName($0.text) }
            .sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.01 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }

        let drafts = candidates.compactMap { line -> ScreenshotSubscriptionDraft? in
            let rawName = normalizedDisplayName(line.text)
            guard !isGenericPurchaseHistoryName(rawName),
                  purchaseHistoryTypeIsSubscription(for: line, lines: lines),
                  let purchaseDate = purchaseDate(for: line, dateHeadings: dateHeadings),
                  let price = purchaseHistoryPrice(for: line, priceLines: priceLines) else {
                return nil
            }

            let normalized = purchaseHistoryNameAndPlan(from: rawName)
            let cycle = inferredBillingCycle(name: rawName, plan: normalized.plan)
            let renewalDate = renewalDate(fromPurchaseDate: purchaseDate, cycle: cycle, referenceDate: referenceDate)

            return ScreenshotSubscriptionDraft(
                name: normalized.name,
                plan: normalized.plan,
                renewalDate: renewalDate,
                cost: price.amount,
                currency: price.currency,
                billingCycle: cycle,
                status: .active,
                confidence: 0.84,
                matchedItemID: nil,
                matchedItemName: nil,
                action: .addNew
            )
        }

        return deduplicatedRecurring(drafts)
    }

    private static func purchaseHistoryTypeIsSubscription(
        for itemLine: RecognizedTextLine,
        lines: [RecognizedTextLine]
    ) -> Bool {
        lines.contains { line in
            let lower = normalizedDisplayName(line.text).lowercased()
            let verticalGap = itemLine.boundingBox.midY - line.boundingBox.midY
            let sameColumn = abs(line.boundingBox.minX - itemLine.boundingBox.minX) < 0.14 ||
                abs(line.boundingBox.midX - itemLine.boundingBox.midX) < 0.16
            return lower == "subscription" &&
                verticalGap > 0 &&
                verticalGap < 0.065 &&
                sameColumn
        }
    }

    private static func isPurchaseHistoryScreenshot(_ lines: [RecognizedTextLine]) -> Bool {
        let lowerLines = lines.map { $0.text.lowercased() }
        return lowerLines.contains(where: { $0.contains("purchase history") }) &&
            lowerLines.contains(where: { $0 == "total" || $0.hasPrefix("total ") })
    }

    private static func purchaseDate(
        for itemLine: RecognizedTextLine,
        dateHeadings: [(line: RecognizedTextLine, date: Date)]
    ) -> Date? {
        dateHeadings
            .filter { heading in
                heading.line.boundingBox.midY > itemLine.boundingBox.midY &&
                    abs(heading.line.boundingBox.midX - itemLine.boundingBox.midX) < 0.45
            }
            .min { lhs, rhs in
                lhs.line.boundingBox.midY - itemLine.boundingBox.midY < rhs.line.boundingBox.midY - itemLine.boundingBox.midY
            }?
            .date
    }

    private static func purchaseHistoryPrice(
        for itemLine: RecognizedTextLine,
        priceLines: [(line: RecognizedTextLine, price: (amount: Double, currency: String))]
    ) -> (amount: Double, currency: String)? {
        let itemMidY = itemLine.boundingBox.midY

        if let sameRow = priceLines
            .filter({ candidate in
                let box = candidate.line.boundingBox
                return abs(box.midY - itemMidY) <= 0.035 &&
                    (box.minX > itemLine.boundingBox.maxX || box.midX > 0.58)
            })
            .sorted(by: { lhs, rhs in
                abs(lhs.line.boundingBox.midY - itemMidY) < abs(rhs.line.boundingBox.midY - itemMidY)
            })
            .first {
            return sameRow.price
        }

        return priceLines
            .filter { candidate in
                let box = candidate.line.boundingBox
                return box.midY < itemMidY &&
                    itemMidY - box.midY <= 0.12 &&
                    box.midX > 0.58
            }
            .sorted { lhs, rhs in
                abs(lhs.line.boundingBox.midY - itemMidY) < abs(rhs.line.boundingBox.midY - itemMidY)
            }
            .first?
            .price
    }

    private static func purchaseHistoryNameAndPlan(from rawName: String) -> (name: String, plan: String?) {
        var name = rawName
        var plan: String?

        if name.lowercased().contains("icloud+") && name.lowercased().contains("storage") {
            return ("iCloud+", name)
        }

        if name.range(of: #"\s+subscription$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            name = name.replacingOccurrences(of: #"\s+subscription$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }

        if let range = name.range(of: #"\s*[-–]\s*(yearly|annual|monthly|weekly)$"#, options: [.regularExpression, .caseInsensitive]) {
            plan = String(name[range]).replacingOccurrences(of: #"\s*[-–]\s*"#, with: "", options: .regularExpression)
            name.removeSubrange(range)
        }

        return (normalizedDisplayName(name), plan.map(normalizedDisplayName))
    }

    private static func renewalDate(
        fromPurchaseDate purchaseDate: Date,
        cycle: BillingCycle,
        referenceDate: Date
    ) -> Date? {
        let calendar = Calendar.current
        let component: Calendar.Component
        let value: Int
        switch cycle {
        case .weekly:
            component = .weekOfYear
            value = 1
        case .yearly:
            component = .year
            value = 1
        case .oneOff:
            return purchaseDate
        case .monthly, .custom:
            component = .month
            value = 1
        }

        var date = purchaseDate
        repeat {
            guard let next = calendar.date(byAdding: component, value: value, to: date) else { return nil }
            date = next
        } while date < calendar.startOfDay(for: referenceDate)
        return date
    }

    private static func deduplicatedRecurring(_ drafts: [ScreenshotSubscriptionDraft]) -> [ScreenshotSubscriptionDraft] {
        var bestByKey: [String: ScreenshotSubscriptionDraft] = [:]
        for draft in drafts {
            let key = canonicalName(draft.name)
            guard !key.isEmpty else { continue }
            if let existing = bestByKey[key] {
                bestByKey[key] = newestOrMostComplete(existing, draft)
            } else {
                bestByKey[key] = draft
            }
        }
        return drafts.compactMap { draft in
            let key = canonicalName(draft.name)
            guard let best = bestByKey[key], best.id == draft.id else { return nil }
            return best
        }
    }

    private static func newestOrMostComplete(
        _ lhs: ScreenshotSubscriptionDraft,
        _ rhs: ScreenshotSubscriptionDraft
    ) -> ScreenshotSubscriptionDraft {
        switch (lhs.renewalDate, rhs.renewalDate) {
        case let (left?, right?):
            if left != right { return right > left ? rhs : lhs }
        case (nil, _?):
            return rhs
        case (_?, nil):
            return lhs
        case (nil, nil):
            break
        }

        switch (lhs.cost, rhs.cost) {
        case (nil, _?):
            return rhs
        case (_?, nil):
            return lhs
        default:
            return rhs.confidence > lhs.confidence ? rhs : lhs
        }
    }

    private static func repairMissingPrices(
        in drafts: [ScreenshotSubscriptionDraft],
        imageData: Data
    ) async -> [ScreenshotSubscriptionDraft] {
        guard drafts.contains(where: { $0.cost == nil }),
              let cgImage = cgImage(from: imageData),
              let lines = try? await recognizeTextLines(in: cgImage) else {
            return drafts
        }
        return repairMissingPrices(in: drafts, recognizedLines: lines)
    }

    private static func repairMissingPrices(
        in drafts: [ScreenshotSubscriptionDraft],
        recognizedLines lines: [RecognizedTextLine]
    ) -> [ScreenshotSubscriptionDraft] {
        let priceLines = lines.compactMap { line -> (line: RecognizedTextLine, price: (amount: Double, currency: String))? in
            guard let price = extractPrice(from: line.text) else { return nil }
            return (line, price)
        }
        guard !priceLines.isEmpty else { return drafts }

        var repaired = drafts
        for index in repaired.indices where repaired[index].cost == nil {
            let draft = repaired[index]

            if let inlinePrice = inlinePrice(for: draft, lines: lines) {
                repaired[index].cost = inlinePrice.amount
                repaired[index].currency = inlinePrice.currency
                continue
            }

            guard let serviceLine = bestServiceLine(for: draft, lines: lines) else { continue }
            let serviceMidY = serviceLine.boundingBox.midY
            let sameRowPrices = priceLines
                .filter { candidate in
                    let box = candidate.line.boundingBox
                    let sameRow = abs(box.midY - serviceMidY) <= 0.035
                    let rightColumn = box.minX > serviceLine.boundingBox.maxX || box.midX > 0.58
                    return sameRow && rightColumn
                }
                .sorted { lhs, rhs in
                    abs(lhs.line.boundingBox.midY - serviceMidY) < abs(rhs.line.boundingBox.midY - serviceMidY)
                }

            if let match = sameRowPrices.first {
                repaired[index].cost = match.price.amount
                repaired[index].currency = match.price.currency
            }
        }

        return repaired
    }

    private static func inlinePrice(
        for draft: ScreenshotSubscriptionDraft,
        lines: [RecognizedTextLine]
    ) -> (amount: Double, currency: String)? {
        lines.first { line in
            extractPrice(from: line.text) != nil && lineMatchesDraftName(line.text, draft: draft)
        }.flatMap { extractPrice(from: $0.text) }
    }

    private static func bestServiceLine(
        for draft: ScreenshotSubscriptionDraft,
        lines: [RecognizedTextLine]
    ) -> RecognizedTextLine? {
        lines
            .compactMap { line -> (line: RecognizedTextLine, score: Double)? in
                guard extractPrice(from: line.text) == nil,
                      !containsRenewalSignal(line.text) else {
                    return nil
                }
                let score = lineMatchScore(line.text, draft: draft)
                return score >= 0.72 ? (line, score) : nil
            }
            .max { $0.score < $1.score }?
            .line
    }

    private static func lineMatchesDraftName(_ line: String, draft: ScreenshotSubscriptionDraft) -> Bool {
        lineMatchScore(line, draft: draft) >= 0.72
    }

    private static func lineMatchScore(_ line: String, draft: ScreenshotSubscriptionDraft) -> Double {
        let lineKey = canonicalName(line)
        let draftKey = canonicalName(draft.name)
        guard !lineKey.isEmpty, !draftKey.isEmpty else { return 0 }
        if lineKey == draftKey { return 1 }
        if lineKey.contains(draftKey) || draftKey.contains(lineKey) { return 0.9 }
        return similarity(lineKey, draftKey)
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

    private static func looksLikePurchaseHistoryItemName(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 90 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        guard extractPrice(from: trimmed) == nil,
              extractStandaloneDate(from: trimmed, referenceDate: Date()) == nil else {
            return false
        }

        let lower = trimmed.lowercased()
        let blockedExact: Set<String> = [
            "purchase history", "subscription", "subscriptions", "total",
            "showing", "this year, paid", "name, price, or order id"
        ]
        if blockedExact.contains(lower) { return false }
        if lower.hasPrefix("showing:") { return false }
        if lower.contains("order id") { return false }
        if lower == "paid" || lower == "this year" { return false }
        return true
    }

    private static func looksLikeReportProblemPlanLine(_ line: String) -> Bool {
        let trimmed = normalizedDisplayName(line)
        guard trimmed.count >= 3, trimmed.count <= 100 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        guard extractPrice(from: trimmed) == nil,
              extractStandaloneDate(from: trimmed, referenceDate: Date()) == nil else {
            return false
        }

        let lower = trimmed.lowercased()
        if lower == "free" || lower == "total" || lower.hasPrefix("total ") { return false }
        if lower.contains("reportaproblem.apple.com") { return false }
        if lower.contains("purchase history") { return false }
        if lower.contains("showing:") || lower.contains("order id") { return false }
        if containsRenewalSignal(trimmed) || extractDateRangeEnd(from: trimmed, referenceDate: Date()) != nil { return false }
        return true
    }

    private static func looksLikeReportProblemAppLine(_ line: String) -> Bool {
        let trimmed = normalizedDisplayName(line)
        guard trimmed.count >= 2, trimmed.count <= 100 else { return false }
        guard trimmed.rangeOfCharacter(from: .letters) != nil else { return false }
        guard extractPrice(from: trimmed) == nil,
              extractStandaloneDate(from: trimmed, referenceDate: Date()) == nil else {
            return false
        }

        let lower = trimmed.lowercased()
        if lower == "free" || lower == "total" || lower.hasPrefix("total ") { return false }
        if lower.contains("reportaproblem.apple.com") { return false }
        if containsRenewalSignal(trimmed) || extractDateRangeEnd(from: trimmed, referenceDate: Date()) != nil { return false }
        return true
    }

    private static func isReportProblemStatusLine(_ line: String) -> Bool {
        containsRenewalSignal(line) || extractDateRangeEnd(from: line, referenceDate: Date()) != nil
    }

    private static func isGenericPurchaseHistoryName(_ name: String) -> Bool {
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = [
            "monthly subscription", "yearly subscription", "annual subscription",
            "weekly subscription", "subscription", "subscriptions"
        ]
        return generic.contains(key)
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

    private static func inferredBillingCycle(name: String, plan: String?) -> BillingCycle {
        let combined = [name, plan ?? ""].joined(separator: " ").lowercased()
        if combined.contains("annual") || combined.contains("yearly") || combined.contains("year") {
            return .yearly
        }
        if combined.contains("weekly") || combined.contains("week") {
            return .weekly
        }
        if combined.contains("one-time") || combined.contains("one time") || combined.contains("lifetime") {
            return .oneOff
        }
        return .monthly
    }

    private static func containsRenewalSignal(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("renews") ||
            lower.contains("expiring") ||
            lower.contains("expires") ||
            lower.contains("expired")
    }

    private static func status(from line: String?) -> ScreenshotSubscriptionDraft.DetectionStatus {
        let lower = line?.lowercased() ?? ""
        if lower.contains("expired") { return .expired }
        if lower.contains("expiring") || lower.contains("expires") { return .expiring }
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
        let pattern = #"(?:renews|expiring|expires:?|expired)\s+("# + escaped + #")\s+([0-9]{1,2})(?:,\s*([0-9]{4}))?"#
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

    private static func extractStandaloneDate(from line: String, referenceDate: Date) -> Date? {
        let formatter = DateFormatter()
        let monthNames = (formatter.monthSymbols ?? []) + (formatter.shortMonthSymbols ?? [])
        let escaped = monthNames
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = #"^\s*("# + escaped + #")\s+([0-9]{1,2})(?:,\s*([0-9]{4}))?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let monthRange = Range(match.range(at: 1), in: line),
              let dayRange = Range(match.range(at: 2), in: line),
              let day = Int(line[dayRange]) else {
            return nil
        }

        let monthName = String(line[monthRange]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fullMonths = formatter.monthSymbols ?? []
        let shortMonths = formatter.shortMonthSymbols ?? []
        let fullIndex = fullMonths.firstIndex { $0.lowercased() == monthName }
        let shortIndex = shortMonths.firstIndex { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == monthName }
        guard let monthIndex = fullIndex ?? shortIndex else { return nil }

        let calendar = Calendar.current
        let year: Int
        if match.range(at: 3).location != NSNotFound,
           let yearRange = Range(match.range(at: 3), in: line),
           let parsedYear = Int(line[yearRange]) {
            year = parsedYear
        } else {
            year = calendar.component(.year, from: referenceDate)
        }

        return calendar.date(from: DateComponents(year: year, month: monthIndex + 1, day: day))
    }

    private static func extractDateRangeEnd(from line: String, referenceDate: Date) -> Date? {
        extractDateRange(from: line, referenceDate: referenceDate)?.end
    }

    private static func extractDateRange(from line: String, referenceDate: Date) -> (start: Date, end: Date)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let monthNames = (formatter.monthSymbols ?? []) + (formatter.shortMonthSymbols ?? [])
        let escaped = monthNames
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let datePart = #"("# + escaped + #")\s+([0-9]{1,2})(?:,\s*([0-9]{4}))?"#
        let pattern = datePart + #"\s*[-–]\s*"# + datePart
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let startMonthRange = Range(match.range(at: 1), in: line),
              let startDayRange = Range(match.range(at: 2), in: line),
              let endMonthRange = Range(match.range(at: 4), in: line),
              let endDayRange = Range(match.range(at: 5), in: line),
              let startDay = Int(line[startDayRange]),
              let endDay = Int(line[endDayRange]),
              let startMonth = monthIndex(String(line[startMonthRange])),
              let endMonth = monthIndex(String(line[endMonthRange])) else {
            return nil
        }

        let calendar = Calendar.current
        let referenceYear = calendar.component(.year, from: referenceDate)
        let startYear: Int
        if match.range(at: 3).location != NSNotFound,
           let yearRange = Range(match.range(at: 3), in: line),
           let parsedYear = Int(line[yearRange]) {
            startYear = parsedYear
        } else {
            startYear = referenceYear
        }

        let endYear: Int
        if match.range(at: 6).location != NSNotFound,
           let yearRange = Range(match.range(at: 6), in: line),
           let parsedYear = Int(line[yearRange]) {
            endYear = parsedYear
        } else if endMonth < startMonth {
            endYear = startYear + 1
        } else {
            endYear = startYear
        }

        guard let start = calendar.date(from: DateComponents(year: startYear, month: startMonth + 1, day: startDay)),
              let end = calendar.date(from: DateComponents(year: endYear, month: endMonth + 1, day: endDay)) else {
            return nil
        }
        return (start, end)
    }

    private static func monthIndex(_ raw: String) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let month = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let index = formatter.monthSymbols.firstIndex(where: { $0.lowercased() == month }) {
            return index
        }
        return formatter.shortMonthSymbols.firstIndex {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == month
        }
    }

    nonisolated private static func normalizedDisplayName(_ line: String) -> String {
        line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizedServiceDisplayName(_ line: String) -> String {
        let name = normalizedDisplayName(line)
        guard name.lowercased().hasPrefix("clipboard al") else { return name }
        return name.replacingOccurrences(of: "Clipboard Al", with: "Clipboard AI", options: [.caseInsensitive])
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
