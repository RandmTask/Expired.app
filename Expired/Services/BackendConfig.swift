import Foundation

/// Central, single source of truth for backend + monetization configuration.
///
/// Everything here is **public by design**: the Supabase publishable key and the
/// RevenueCat SDK key are meant to ship in the client. The secrets that must never
/// leave the server (Supabase service-role key, AI provider keys, RevenueCat webhook
/// secret) live only in Supabase — see `Expired/supabase/SETUP.md`.
enum BackendConfig {

    // MARK: Supabase
    static let supabaseURL = URL(string: "https://ehibtlaoshmqpbnexehy.supabase.co")!

    /// New-format publishable key (replaces the legacy JWT anon key for clients).
    static let supabasePublishableKey = "sb_publishable_ovK9myqBXql1v1B_a52gJQ_xkLLO-GN"

    /// Edge Function base. Functions are at `<project>.functions.supabase.co/<name>`.
    static func functionURL(_ name: String) -> URL {
        URL(string: "https://ehibtlaoshmqpbnexehy.functions.supabase.co/\(name)")!
    }

    enum Function {
        static let aiProxy = "ai-proxy"
        static let models = "models"
    }

    // MARK: RevenueCat
    /// Public SDK key. `test_…` is the sandbox key; swap for the production key before release.
    static let revenueCatAPIKey = "test_aTQLDKzrPfEdvwGfOFVEChZPtAI"

    /// Entitlement identifier configured in the RevenueCat dashboard (display name "Expired Pro").
    static let proEntitlementID = "Expired Pro"
}
