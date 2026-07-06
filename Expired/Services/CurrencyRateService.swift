import Foundation
import Supabase

/// Fetches live USD-based exchange rates from the Supabase `exchange_rates` table
/// (populated daily by the `update-exchange-rates` Edge Function from Frankfurter/ECB).
///
/// `CurrencyInfo.convert()` reads `CurrencyRateService.shared.rates` and falls back
/// to the hardcoded snapshot in `CurrencyInfo.ratesFromUSD` when no live data exists.
///
/// Thread-safety note: `rates` is marked `nonisolated(unsafe)` because it is written
/// only from async refresh calls and read only for display math — a stale read is
/// acceptable for exchange rate data that changes at most once per weekday.
final class CurrencyRateService {
    nonisolated(unsafe) static let shared = CurrencyRateService()

    /// Live rates (1 USD = N units). Empty until the first successful fetch; in that
    /// state `CurrencyInfo.convert()` falls back to its hardcoded snapshot.
    nonisolated(unsafe) private(set) var rates: [String: Double] = [:]

    private let ratesKey = "currencyRates.v1"
    private let timestampKey = "currencyRates.updatedAt"
    private let maxCacheAge: TimeInterval = 12 * 3600   // 12 hours

    private init() {
        if let data = UserDefaults.standard.data(forKey: ratesKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data),
           !decoded.isEmpty {
            rates = decoded
        }
    }

    /// Skips the network call if cached rates are < 12 hours old.
    func refreshIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: timestampKey)
        guard last == 0 || Date().timeIntervalSince1970 - last >= maxCacheAge else { return }
        await refresh()
    }

    /// Unconditionally fetches rates from Supabase and updates the local cache.
    func refresh() async {
        do {
            struct Row: Decodable {
                let currency_code: String
                let rate_vs_usd: Double
            }

            let rows: [Row] = try await SupabaseService.shared.client
                .from("exchange_rates")
                .select("currency_code, rate_vs_usd")
                .execute()
                .value

            guard !rows.isEmpty else {
                print("[CurrencyRates] Table is empty — keeping fallback rates")
                return
            }

            var newRates: [String: Double] = [:]
            for row in rows { newRates[row.currency_code] = row.rate_vs_usd }

            rates = newRates

            if let data = try? JSONEncoder().encode(newRates) {
                UserDefaults.standard.set(data, forKey: ratesKey)
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
            print("[CurrencyRates] Updated \(newRates.count) rates from Supabase")
        } catch {
            print("[CurrencyRates] Refresh failed: \(error)")
        }
    }
}
