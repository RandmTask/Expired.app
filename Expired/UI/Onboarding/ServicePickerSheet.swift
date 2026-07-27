import SwiftUI

/// Standalone home for R4's grid + quick setup pages outside onboarding — reached from
/// `HomeView`'s empty state ("Add your services") so the picker grid has a permanent
/// entry point, not just a one-shot onboarding surface (per
/// `_shared/onboarding-conventions.md`).
struct ServicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode
    @State private var selectedTileIDs: [String] = []
    @State private var showQuickSetup = false

    var body: some View {
        NavigationStack {
            Group {
                if showQuickSetup {
                    QuickSetupPage(
                        selectedTileIDs: $selectedTileIDs,
                        reminderOffsetDays: 3,
                        currency: preferredCurrency,
                        onCommit: { dismiss() },
                        onSkip: { dismiss() }
                    )
                } else {
                    ServicePickerPage(
                        selectedTileIDs: $selectedTileIDs,
                        onContinue: { withAnimation { showQuickSetup = true } },
                        onSkip: { dismiss() },
                        onAddYourOwn: { dismiss() }
                    )
                }
            }
            .padding(.top, 8)
            .toolbar {
                if showQuickSetup {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            withAnimation { showQuickSetup = false }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.large])
    }
}
