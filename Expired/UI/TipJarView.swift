import SwiftUI
import RevenueCat

/// Tip jar sheet. Opened from Settings → Support, and only reachable when
/// `TipJarManager.tips` is non-empty — a tip jar with nothing in it is a dead row,
/// so Settings hides the row entirely instead of pushing to an empty screen.
///
/// Tips unlock nothing. That's deliberate: gating a feature behind a "tip" turns it
/// into a purchase, which is both an App Store problem and a broken promise.
struct TipJarView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tipJar = TipJarManager.shared
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tipJar.tips, id: \.productIdentifier) { product in
                        Button {
                            Haptics.fire(.light)
                            Task {
                                switch await tipJar.purchase(product) {
                                case .success:
                                    Haptics.fire(.success)
                                case .cancelled:
                                    break   // Backing out of the App Store sheet is not a failure.
                                case .failed(let message):
                                    Haptics.fire(.error)
                                    failureMessage = message
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                rowIcon(icon(for: product), color: .pink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(product.localizedTitle)
                                        .foregroundStyle(.primary)
                                    if !product.localizedDescription.isEmpty {
                                        Text(product.localizedDescription)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if tipJar.purchasingID == product.productIdentifier {
                                    ProgressView()
                                } else {
                                    Text(product.localizedPriceString)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(tipJar.purchasingID != nil)
                    }
                } header: {
                    Text("Leave a Tip")
                } footer: {
                    Text("Tips are entirely optional and unlock nothing; every feature works exactly the same either way. They just help keep Expired maintained.")
                }
            }
            .navigationTitle("Tip Jar")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.fire(.light)
                        dismiss()
                    }
                }
            }
            .alert("Thank You", isPresented: Binding(
                get: { tipJar.didTip },
                set: { if !$0 { tipJar.didTip = false } }
            )) {
                Button("You're welcome", role: .cancel) {}
            } message: {
                Text("That genuinely helps. Nothing has changed in the app; you already had everything.")
            }
            .alert("Tip Didn't Go Through", isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failureMessage ?? "")
            }
        }
    }

    /// Cheapest → dearest gets a progressively warmer icon; falls back gracefully if
    /// more than three tip products are ever configured.
    private func icon(for product: StoreProduct) -> String {
        let index = tipJar.tips.firstIndex { $0.productIdentifier == product.productIdentifier } ?? 0
        switch index {
        case 0:  return "cup.and.saucer"
        case 1:  return "takeoutbag.and.cup.and.straw"
        default: return "heart"
        }
    }

    @ViewBuilder
    private func rowIcon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .frame(width: 22, alignment: .center)
            .foregroundStyle(color)
    }
}
