import Foundation
import Supabase

/// Reports which known AppCatalog services this device tracks, so onboarding/search
/// suggestions can be ranked by real-world popularity. Privacy-preserving by design:
/// only a canonical service name is ever sent (e.g. "Netflix") — never a user
/// identifier, cost, date, email, or free-text name a user typed. A device reports a
/// given service at most once. On by default; can be turned off in Settings, in which
/// case nothing is ever sent.
enum ServicePopularityReporter {
    static let sharingEnabledKey = "shareServicePopularity"
    private static let reportedNamesKey = "reportedServicePopularityNames"

    /// Call after saving a *new* item. No-ops silently if sharing is off, the name
    /// isn't an exact match against the AppCatalog (never sends arbitrary free text),
    /// or this device already reported that service.
    static func reportIfNewService(named name: String) {
        guard UserDefaults.standard.object(forKey: sharingEnabledKey) as? Bool ?? true else { return }
        guard let canonicalName = AppCatalog.knownServiceName(for: name) else { return }

        var reported = Set(UserDefaults.standard.stringArray(forKey: reportedNamesKey) ?? [])
        guard !reported.contains(canonicalName) else { return }

        Task {
            do {
                try await SupabaseService.shared.client
                    .rpc("increment_service_popularity", params: ["p_name": canonicalName])
                    .execute()
                reported.insert(canonicalName)
                UserDefaults.standard.set(Array(reported), forKey: reportedNamesKey)
            } catch {
                // Silent — this is best-effort telemetry, never surfaced to the user.
                // Not marking as reported means the next time this service is added
                // (if ever), it'll retry.
                print("[ServicePopularity] report failed for \(canonicalName): \(error)")
            }
        }
    }
}
