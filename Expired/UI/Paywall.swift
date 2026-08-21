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

    /// Presents a small custom "Expired Pro Details" sheet — status, renewal date,
    /// a link to Apple's native subscription management, and Restore Purchases.
    /// Replaces RevenueCat's full-screen Customer Center, whose title/sections come
    /// from the RevenueCat dashboard and aren't renameable/trimmable from app code.
    /// (Deon, 2026-08-21: wanted a small sheet titled "Expired Pro Details", no
    /// Manage Subscription/Change Plans/Account Details sections.)
    func expiredProDetailsSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            ExpiredProDetailsSheet()
        }
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

/// Small custom sheet replacing RevenueCat's Customer Center. Shows the Pro entitlement's
/// status and renewal date, a direct link to Apple's subscription management page, and
/// Restore Purchases — nothing else. Only reachable from the "Expired Pro" row when a
/// subscription is already active; "Upgrade to Pro" still opens the full paywall.
private struct ExpiredProDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(PurchaseManager.self) private var purchaseManager
    @State private var isRestoring = false
    @State private var restoreFeedback: String?

    private var renewalDateText: String? {
        guard let date = purchaseManager.entitlementExpirationDate else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Status").foregroundStyle(.secondary)
                        Spacer()
                        Text("Active").foregroundStyle(.green)
                    }
                    .padding(.vertical, 12)
                    if let renewalDateText {
                        FormDivider()
                        HStack {
                            Text("Renews").foregroundStyle(.secondary)
                            Spacer()
                            Text(renewalDateText)
                        }
                        .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                Button {
                    openURL(URL(string: "https://apps.apple.com/account/subscriptions")!)
                } label: {
                    Text("Manage in App Store")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    performRestore()
                } label: {
                    HStack(spacing: 4) {
                        if isRestoring {
                            ProgressView().controlSize(.mini)
                        }
                        Text(restoreFeedback ?? "Restore Purchases")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(restoreFeedback == "Restored!" ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isRestoring)
            }
            .padding(20)
            .navigationTitle("Expired Pro Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 340, height: 300)
        #endif
    }

    private func performRestore() {
        guard !isRestoring else { return }
        Haptics.fire(.light)
        isRestoring = true
        restoreFeedback = nil
        Task {
            let restored = await purchaseManager.restore()
            isRestoring = false
            Haptics.fire(restored ? .success : .warning)
            restoreFeedback = restored ? "Restored!" : "No purchases found"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if restoreFeedback != nil {
                restoreFeedback = nil
            }
        }
    }
}
