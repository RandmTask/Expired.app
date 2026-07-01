import SwiftUI
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

extension View {
    /// Presents RevenueCat's hosted paywall as a sheet. The SDK dismisses it
    /// automatically on a successful purchase.
    func expiredPaywallSheet(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            PaywallView(displayCloseButton: true)
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
