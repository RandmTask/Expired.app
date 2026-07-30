import SwiftUI
import RevenueCat
import RevenueCatUI

// Centralised Pro-gating helpers shared by every paywall trigger.
//
// `PurchaseManager.isPremium` flips reactively through the SDK delegate the moment a
// purchase or restore completes, so any view holding the environment object updates
// its gated UI with no extra wiring. RevenueCatUI 5.x renders on both iOS and macOS,
// so a single code path covers both platforms.

/// Small lock glyph marking a Pro-only control inside menus and pickers.
struct ProLockBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

struct ProChip: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.12), in: Capsule())
    }
}

extension View {
    /// Presents RevenueCat's hosted paywall as a sheet. The SDK dismisses it
    /// automatically on a successful purchase.
    ///
    /// Wrapped in `PaywallGate` rather than presenting `PaywallView` directly:
    /// RevenueCatUI renders whatever offering/template is configured in the
    /// RevenueCat dashboard, and it has no graceful fallback if that offering has
    /// no packages (e.g. a Test Store project without a matching production
    /// paywall setup) — it crashes instead of showing an empty state. The gate
    /// checks for at least one package before ever constructing `PaywallView`.
    func expiredPaywallSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            PaywallGate()
        }
    }

    /// Presents RevenueCat's Customer Center (manage/cancel, restore, refunds) on iOS.
    /// Customer Center is iOS-only, so macOS gets a lightweight Restore + guidance sheet.
    @ViewBuilder
    func expiredCustomerCenterSheet(isPresented: Binding<Bool>) -> some View {
#if os(iOS)
        sheet(isPresented: isPresented) {
            CustomerCenterView()
        }
#else
        sheet(isPresented: isPresented) {
            MacManageSubscriptionSheet()
        }
#endif
    }
}

/// Loads offerings (if not already cached) and only then decides whether it's safe
/// to hand control to RevenueCatUI's `PaywallView`. Never presents `PaywallView`
/// against a nil/empty offering.
private struct PaywallGate: View {
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var isChecking = true
    @State private var canShowPaywall = false

    var body: some View {
        Group {
            if isChecking {
                ProgressView()
                    .task { await checkOfferings() }
            } else if canShowPaywall {
                PaywallView(displayCloseButton: true)
            } else {
                PaywallUnavailableView()
            }
        }
    }

    private func checkOfferings() async {
        if purchaseManager.offerings == nil {
            await purchaseManager.loadOfferings()
        }
        canShowPaywall = !(purchaseManager.offerings?.current?.availablePackages.isEmpty ?? true)
        isChecking = false
    }
}

/// Shown instead of `PaywallView` when RevenueCat has no usable offering — e.g. the
/// Test Store project isn't configured with a matching paywall/offering, or the
/// network fetch failed. Never blocks the user from using the free tier.
private struct PaywallUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Store Unavailable")
                .font(.headline)
            Text("Expired Pro isn't available right now. This usually means the store connection failed — check your internet connection and try again shortly.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Button {
                isRestoring = true
                Task {
                    let restored = await PurchaseManager.shared.restore()
                    Haptics.fire(restored ? .success : .warning)
                    isRestoring = false
                }
            } label: {
                if isRestoring {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Restore Purchases")
                }
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}

#if os(macOS)
/// macOS fallback for RevenueCat's iOS-only Customer Center: restore purchases plus
/// a pointer to where subscriptions are actually managed on the platform.
private struct MacManageSubscriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isRestoring = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Manage Subscription")
                .font(.headline)
            Text("Manage or cancel Expired Pro in System Settings › Apple Account › Subscriptions, or from the App Store on your iPhone or iPad.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isRestoring = true
                Task {
                    let restored = await PurchaseManager.shared.restore()
                    Haptics.fire(restored ? .success : .warning)
                    isRestoring = false
                }
            } label: {
                if isRestoring {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Restore Purchases")
                }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(minWidth: 360)
    }
}
#endif
