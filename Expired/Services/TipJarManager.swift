import Foundation
import RevenueCat

/// Tip jar backed by RevenueCat's product fetch/purchase, **not** a parallel StoreKit 2
/// path: `PurchaseManager` configures RevenueCat with the default completion mode, so
/// RevenueCat already owns the transaction queue. A second owner finishing the same
/// transactions is the classic double-ownership bug — tips go through the same SDK.
///
/// Tips grant no entitlement and gate nothing (App Store rules, and
/// `_shared/settings page/settings-conventions.md`). If the products don't resolve —
/// not yet created in App Store Connect, offline, StoreKit unavailable — `tips` stays
/// empty and the Settings row hides itself rather than shipping a dead affordance.
@MainActor
@Observable
final class TipJarManager {
    static let shared = TipJarManager()

    private(set) var tips: [StoreProduct] = []
    private(set) var isLoading = false
    private(set) var purchasingID: String?

    /// Set after a successful tip so the UI can say thank you; cleared on dismiss.
    var didTip = false

    private var hasLoaded = false

    private init() {}

    /// Cheapest-first, so the sheet reads small → large.
    func load() async {
        guard !hasLoaded, !isLoading, PurchaseManager.shared.isConfigured else { return }
        isLoading = true
        let fetched = await Purchases.shared.products(SupportConfig.tipProductIDs)
        tips = fetched.sorted { $0.price < $1.price }
        isLoading = false
        hasLoaded = true
    }

    enum TipResult {
        case success
        case cancelled
        case failed(String)
    }

    /// A cancel is distinct from a failure — the caller must not buzz or alert on a
    /// user backing out of the App Store sheet.
    @discardableResult
    func purchase(_ product: StoreProduct) async -> TipResult {
        guard purchasingID == nil else { return .cancelled }
        purchasingID = product.productIdentifier
        defer { purchasingID = nil }
        do {
            let result = try await Purchases.shared.purchase(product: product)
            guard !result.userCancelled else { return .cancelled }
            didTip = true
            return .success
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
