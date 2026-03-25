import SwiftUI
import SwiftData

struct AddEditSubscriptionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let item: SubscriptionItem?

    // Core fields
    @State private var name = ""
    @State private var provider = ""
    @State private var nextRenewalDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var isAutoRenew = true
    @State private var isCancelled = false
    @State private var isTrial = false
    @State private var trialEndDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var activeUntilDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

    // Details
    @State private var cost: Double? = nil
    @State private var costText = ""
    @State private var currency = "AUD"
    @State private var billingCycle: BillingCycle = .monthly
    @State private var paymentMethod = ""
    @State private var emailUsed = ""
    @State private var notes = ""
    @State private var url = ""

    // Notifications
    @State private var notifications: [NotificationRule] = []

    // UI state
    @State private var showDetails = false
    @State private var showReminders = false

    private var isEditing: Bool { item != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: Core section
                    FormCard {
                        VStack(spacing: 0) {
                            FormRow(label: "Name") {
                                TextField("Netflix, Passport…", text: $name)
                                    .submitLabel(.next)
                            }

                            FormDivider()

                            FormRow(label: "Provider") {
                                TextField("Optional", text: $provider)
                                    .submitLabel(.next)
                            }

                            FormDivider()

                            FormRow(label: isTrial ? "Trial Ends" : "Renews") {
                                DatePicker("", selection: isTrial ? $trialEndDate : $nextRenewalDate, displayedComponents: .date)
                                    .labelsHidden()
                            }
                        }
                    }

                    // MARK: Status toggles
                    FormCard {
                        VStack(spacing: 0) {
                            Toggle(isOn: $isAutoRenew) {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Auto-Renews")
                                        .font(.system(size: 16))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .onChange(of: isAutoRenew) { _, on in
                                if on { isCancelled = false }
                            }

                            FormDivider()

                            Toggle(isOn: $isTrial) {
                                HStack(spacing: 10) {
                                    Image(systemName: "gift.fill")
                                        .foregroundStyle(.purple)
                                    Text("Free Trial")
                                        .font(.system(size: 16))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .onChange(of: isTrial) { _, on in
                                if on && notifications.isEmpty {
                                    // Auto-add trial reminders
                                    notifications = [
                                        NotificationRule(offsetType: .daysBefore, value: 3),
                                        NotificationRule(offsetType: .daysBefore, value: 1)
                                    ]
                                }
                            }

                            FormDivider()

                            Toggle(isOn: $isCancelled) {
                                HStack(spacing: 10) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Text("Cancelled")
                                        .font(.system(size: 16))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .onChange(of: isCancelled) { _, on in
                                if on { isAutoRenew = false }
                            }

                            if isCancelled {
                                FormDivider()
                                FormRow(label: "Active Until") {
                                    DatePicker("", selection: $activeUntilDate, displayedComponents: .date)
                                        .labelsHidden()
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.spring(duration: 0.25), value: isCancelled)
                    }

                    // MARK: Details (expandable)
                    ExpandableCard(title: "Cost & Payment", icon: "creditcard.fill", isExpanded: $showDetails) {
                        VStack(spacing: 0) {
                            FormRow(label: "Amount") {
                                HStack {
                                    TextField("0.00", text: $costText)
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                        .onChange(of: costText) { _, val in
                                            cost = Double(val)
                                        }

                                    Picker("", selection: $currency) {
                                        ForEach(["AUD", "USD", "EUR", "GBP", "CAD", "NZD"], id: \.self) {
                                            Text($0)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .fixedSize()
                                }
                            }

                            FormDivider()

                            FormRow(label: "Billing") {
                                Picker("", selection: $billingCycle) {
                                    ForEach(BillingCycle.allCases, id: \.self) {
                                        Text($0.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            FormDivider()

                            FormRow(label: "Card") {
                                TextField("Visa ****1234", text: $paymentMethod)
                                    .multilineTextAlignment(.trailing)
                            }

                            FormDivider()

                            FormRow(label: "Email") {
                                TextField("user@example.com", text: $emailUsed)
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .multilineTextAlignment(.trailing)
                            }

                            FormDivider()

                            FormRow(label: "Website") {
                                TextField("https://…", text: $url)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }

                    // MARK: Reminders (expandable)
                    ExpandableCard(title: "Reminders", icon: "bell.fill", isExpanded: $showReminders) {
                        RemindersEditorView(notifications: $notifications)
                    }

                    // MARK: Notes
                    FormCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Notes", systemImage: "note.text")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)

                            TextField("Optional notes…", text: $notes, axis: .vertical)
                                .lineLimit(3...6)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 12)
                        }
                    }

                    // Delete button when editing
                    if isEditing {
                        Button(role: .destructive) {
                            deleteAndDismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label("Delete Subscription", systemImage: "trash")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                        }
                        .padding(.vertical, 14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit" : "Add Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") {
                        saveAndDismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear {
            populateFromItem()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Populate from existing item

    private func populateFromItem() {
        guard let item else { return }
        name = item.name
        provider = item.provider
        nextRenewalDate = item.nextRenewalDate
        isAutoRenew = item.isAutoRenew
        isCancelled = item.isCancelled
        isTrial = item.isTrial
        if let trial = item.trialEndDate { trialEndDate = trial }
        if let until = item.activeUntilDate { activeUntilDate = until }
        if let c = item.cost { costText = String(c) }
        cost = item.cost
        currency = item.currency
        billingCycle = item.billingCycle
        paymentMethod = item.paymentMethod
        emailUsed = item.emailUsed
        notes = item.notes
        url = item.url
        notifications = item.notifications
    }

    // MARK: - Save

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        if let existing = item {
            // Edit existing
            existing.name = trimmedName
            existing.provider = provider
            existing.nextRenewalDate = nextRenewalDate
            existing.isAutoRenew = isAutoRenew
            existing.isCancelled = isCancelled
            existing.trialEndDate = isTrial ? trialEndDate : nil
            existing.activeUntilDate = isCancelled ? activeUntilDate : nil
            existing.cost = cost
            existing.currency = currency
            existing.billingCycle = billingCycle
            existing.paymentMethod = paymentMethod
            existing.emailUsed = emailUsed
            existing.notes = notes
            existing.url = url
            existing.notifications = notifications
            existing.updatedAt = Date()
        } else {
            // Create new
            let newItem = SubscriptionItem(
                name: trimmedName,
                provider: provider,
                nextRenewalDate: nextRenewalDate,
                trialEndDate: isTrial ? trialEndDate : nil,
                isAutoRenew: isAutoRenew,
                isCancelled: isCancelled,
                activeUntilDate: isCancelled ? activeUntilDate : nil,
                cost: cost,
                currency: currency,
                billingCycle: billingCycle,
                paymentMethod: paymentMethod,
                emailUsed: emailUsed,
                notes: notes,
                url: url,
                notifications: notifications
            )
            modelContext.insert(newItem)
        }

        dismiss()
    }

    private func deleteAndDismiss() {
        if let item {
            modelContext.delete(item)
        }
        dismiss()
    }
}

// MARK: - Form Building Blocks

struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

struct FormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 16))
                .frame(minWidth: 80, alignment: .leading)
                .foregroundStyle(.primary)
            Spacer()
            content
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct FormDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 16)
    }
}

struct ExpandableCard<Content: View>: View {
    let title: String
    let icon: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(title)
                        .font(.system(size: 16))
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider().padding(.leading, 16)
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .clipped()
    }
}

// MARK: - Preview

#Preview("Add") {
    AddEditSubscriptionView(item: nil)
        .modelContainer(PreviewData.container)
}

#Preview("Edit") {
    AddEditSubscriptionView(item: PreviewData.netflix)
        .modelContainer(PreviewData.container)
}
