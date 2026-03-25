import SwiftUI
import SwiftData

struct AddEditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var provider = ""
    @State private var nextRenewalDate = Date()
    @State private var isAutoRenew = true
    @State private var hasTrial = false
    @State private var trialEndDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    @State private var showDetails = false
    @State private var costText = ""
    @State private var billingCycle: BillingCycle = .monthly
    @State private var paymentMethod = ""
    @State private var emailUsed = ""
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Provider", text: $provider)
                        .textInputAutocapitalization(.words)
                    DatePicker("Next Renewal", selection: $nextRenewalDate, displayedComponents: .date)
                }

                Section {
                    Toggle("Auto-renew", isOn: $isAutoRenew)
                    Toggle("Free Trial", isOn: $hasTrial)
                    if hasTrial {
                        DatePicker("Trial Ends", selection: $trialEndDate, displayedComponents: .date)
                    }
                }

                Section {
                    Button(showDetails ? "Hide Details" : "Show Details") {
                        showDetails.toggle()
                    }
                }

                if showDetails {
                    Section {
                        TextField("Cost", text: $costText)
                            .keyboardType(.decimalPad)
                        Picker("Billing", selection: $billingCycle) {
                            ForEach(BillingCycle.allCases) { cycle in
                                Text(cycle.rawValue.capitalized).tag(cycle)
                            }
                        }
                        TextField("Payment Method", text: $paymentMethod)
                        TextField("Email Used", text: $emailUsed)
                            .textInputAutocapitalization(.never)
                        TextField("Notes", text: $notes, axis: .vertical)
                            .lineLimit(3, reservesSpace: true)
                    }
                }
            }
            .navigationTitle("New Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let cost = Double(costText.replacingOccurrences(of: ",", with: "."))
        let item = SubscriptionItem(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider.isEmpty ? nil : provider,
            iconSource: .system,
            cost: cost,
            currency: "USD",
            billingCycle: billingCycle,
            nextRenewalDate: nextRenewalDate,
            trialEndDate: hasTrial ? trialEndDate : nil,
            isAutoRenew: isAutoRenew,
            isCancelled: false,
            activeUntilDate: nil,
            paymentMethod: paymentMethod.isEmpty ? nil : paymentMethod,
            emailUsed: emailUsed.isEmpty ? nil : emailUsed,
            notes: notes.isEmpty ? nil : notes
        )

        if item.trialEndDate != nil {
            item.notifications = [
                NotificationRule(offsetType: .daysBefore, value: 3),
                NotificationRule(offsetType: .daysBefore, value: 1)
            ]
        }

        modelContext.insert(item)
        dismiss()
    }
}

#Preview {
    AddEditSubscriptionView()
        .modelContainer(PreviewData.inMemoryContainer)
}
