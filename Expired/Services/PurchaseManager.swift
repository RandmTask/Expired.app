import Foundation
import RevenueCat

/// Observable wrapper over RevenueCat. Configured once at launch with the Supabase
/// anonymous UUID as `appUserID`, so the proxy (server) and the app (client) agree on
/// one identity. `isPremium` drives every Premium gate in the UI.
@MainActor
@Observable
final class PurchaseManager: NSObject, PurchasesDelegate {
    static let shared = PurchaseManager()

    /// True when the "Expired Pro" entitlement is active. Reactive — gates read this.
    private(set) var isPremium = false
    private(set) var offerings: Offerings?
    private(set) var isConfigured = false

    private override init() { super.init() }

    /// Call once, after the Supabase anonymous session resolves.
    func configure(appUserID: String?) {
        guard !isConfigured else { return }
        isConfigured = true

        #if DEBUG
        Purchases.logLevel = .info
        #endif
        Purchases.configure(
            with: Configuration.builder(withAPIKey: BackendConfig.revenueCatAPIKey)
                .with(appUserID: appUserID)
                .build()
        )
        Purchases.shared.delegate = self

        Task {
            await refreshCustomerInfo()
            await loadOfferings()
        }
    }

    func refreshCustomerInfo() async {
        guard isConfigured else { return }
        if let info = try? await Purchases.shared.customerInfo() {
            apply(info)
        }
    }

    func loadOfferings() async {
        guard isConfigured else { return }
        offerings = try? await Purchases.shared.offerings()
    }

    /// Switches to a brand-new RevenueCat identity with no purchases.
    /// `logOut()` is rejected for anonymous users; `logIn` with a fresh UUID sidesteps that.
    /// Use for testing only.
    func logOutForTesting() async {
        guard isConfigured else {
            print("[PurchaseManager] logOutForTesting: not configured yet")
            return
        }
        let newID = UUID().uuidString
        print("[PurchaseManager] logOutForTesting: switching to new user \(newID)")
        do {
            let (info, isNew) = try await Purchases.shared.logIn(newID)
            let hasPro = info.entitlements[BackendConfig.proEntitlementID]?.isActive == true
            print("[PurchaseManager] logOutForTesting: logIn OK. isNew=\(isNew), hasPro=\(hasPro)")
            apply(info)
        } catch {
            print("[PurchaseManager] logOutForTesting: logIn FAILED: \(error)")
            isPremium = false
        }
    }

    /// Restore purchases (e.g. on a new device, same Apple ID).
    @discardableResult
    func restore() async -> Bool {
        guard isConfigured else { return false }
        if let info = try? await Purchases.shared.restorePurchases() {
            apply(info)
        }
        return isPremium
    }

    private func apply(_ info: CustomerInfo) {
        isPremium = info.entitlements[BackendConfig.proEntitlementID]?.isActive == true
    }

    // MARK: PurchasesDelegate
    nonisolated func purchases(_ purchases: Purchases, receivedUpdated customerInfo: CustomerInfo) {
        Task { @MainActor in self.apply(customerInfo) }
    }
}
