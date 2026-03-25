import SwiftUI
import SwiftData

struct AddEditSubscriptionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [SubscriptionItem]

    let item: SubscriptionItem?

    // Core
    @State private var name = ""
    @State private var url = ""
    @State private var nextRenewalDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var isAutoRenew = true
    @State private var isCancelled = false
    @State private var isTrial = false
    @State private var trialEndDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var activeUntilDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

    // Icon
    @State private var iconData: Data? = nil
    @State private var isFetchingIcon = false
    @State private var faviconFetchTask: Task<Void, Never>? = nil

    // Cost & payment
    @State private var cost: Double? = nil
    @State private var costText = ""
    @State private var currency = "AUD"
    @State private var billingCycle: BillingCycle = .monthly
    @State private var paymentMethod = ""
    @State private var emailUsed = ""
    @State private var phoneNumber = ""

    // Reminders & notes
    @State private var notifications: [NotificationRule] = []
    @State private var notes = ""

    // Suggestion dropdowns
    @State private var showPaymentSuggestions = false
    @State private var showEmailSuggestions = false
    @State private var showPhoneSuggestions = false

    private var isEditing: Bool { item != nil }

    // MARK: - Suggestions

    private var paymentSuggestions: [String] {
        Array(Set(allItems.compactMap { $0.paymentMethod.isEmpty ? nil : $0.paymentMethod }))
            .filter { $0 != paymentMethod }.sorted()
    }
    private var emailSuggestions: [String] {
        Array(Set(allItems.compactMap { $0.emailUsed.isEmpty ? nil : $0.emailUsed }))
            .filter { $0 != emailUsed }.sorted()
    }
    private var phoneSuggestions: [String] {
        Array(Set(allItems.compactMap { $0.phoneNumber.isEmpty ? nil : $0.phoneNumber }))
            .filter { $0 != phoneNumber }.sorted()
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    basicSection
                    statusSection
                    costSection
                    paymentSection
                    remindersSection
                    notesSection
                    if isEditing { deleteSection }
                    Spacer(minLength: 40)
                }
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .background(groupedBackground.ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit" : "Add Subscription")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Add") { saveAndDismiss() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { populateFromItem() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Basic section

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Subscription")
            FormCard {
                VStack(spacing: 0) {
                    // Name + icon
                    HStack(spacing: 12) {
                        iconView
                            .padding(.leading, 16)
                        TextField("Name", text: $name)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .submitLabel(.next)
                            .padding(.vertical, 14)
                            .padding(.trailing, 16)
                    }

                    FormDivider()

                    // Website — triggers favicon
                    HStack {
                        Text("Website")
                            .font(.system(size: 16))
                            .frame(minWidth: 80, alignment: .leading)
                            .foregroundStyle(.primary)
                        Spacer()
                        TextField("netflix.com", text: $url)
                            .foregroundStyle(.primary)
                            .trailingTextAlignment()
#if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
#endif
                            .onChange(of: url) { _, newVal in scheduleFaviconFetch(newVal) }
                        if isFetchingIcon {
                            ProgressView().scaleEffect(0.75).padding(.leading, 6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    FormDivider()

                    FormRow(label: isTrial ? "Trial Ends" : "Renews") {
                        DatePicker("", selection: isTrial ? $trialEndDate : $nextRenewalDate,
                                   displayedComponents: .date)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if isFetchingIcon {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay { ProgressView().scaleEffect(0.8) }
        } else if let data = iconData, let img = platformImage(from: data) {
            Image(platformImage: img)
                .resizable().scaledToFill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue.opacity(0.5))
                }
        }
    }

    // MARK: - Status section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Status")
            FormCard {
                VStack(spacing: 0) {
                    // Auto-Renew
                    Toggle(isOn: $isAutoRenew) {
                        Label("Auto-Renews", systemImage: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.multicolor)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .onChange(of: isAutoRenew) { _, on in
                        if on { isCancelled = false }   // flip the other off
                    }

                    FormDivider()

                    // Free Trial
                    Toggle(isOn: $isTrial) {
                        Label("Free Trial", systemImage: "gift.fill")
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.multicolor)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .onChange(of: isTrial) { _, on in
                        if on && notifications.isEmpty {
                            notifications = [
                                NotificationRule(offsetType: .daysBefore, value: 3),
                                NotificationRule(offsetType: .daysBefore, value: 1)
                            ]
                        }
                    }

                    FormDivider()

                    // Cancelled — flips auto-renew off automatically
                    Toggle(isOn: $isCancelled) {
                        Label("Cancelled", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.multicolor)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .onChange(of: isCancelled) { _, on in
                        if on { isAutoRenew = false }   // flip the other off
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
        }
    }

    // MARK: - Cost section

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Cost")
            FormCard {
                VStack(spacing: 0) {
                    FormRow(label: "Amount") {
                        HStack(spacing: 4) {
                            TextField("0.00", text: $costText)
                                .foregroundStyle(.primary)
                                .trailingTextAlignment()
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                                .onChange(of: costText) { _, val in cost = Double(val) }
                            Picker("", selection: $currency) {
                                ForEach(["AUD","USD","EUR","GBP","CAD","NZD"], id: \.self) { Text($0) }
                            }
                            .pickerStyle(.menu).fixedSize()
                        }
                    }
                    FormDivider()
                    FormRow(label: "Billing") {
                        Picker("", selection: $billingCycle) {
                            ForEach(BillingCycle.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
        }
    }

    // MARK: - Payment section

    private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Account")
            FormCard {
                VStack(spacing: 0) {
                    SuggestionField(label: "Card", placeholder: "Visa ****1234",
                                    text: $paymentMethod, suggestions: paymentSuggestions,
                                    isExpanded: $showPaymentSuggestions)
                    FormDivider()
                    SuggestionField(label: "Email", placeholder: "you@example.com",
                                    text: $emailUsed, suggestions: emailSuggestions,
                                    isExpanded: $showEmailSuggestions)
                    FormDivider()
                    SuggestionField(label: "Phone", placeholder: "+61 400 000 000",
                                    text: $phoneNumber, suggestions: phoneSuggestions,
                                    isExpanded: $showPhoneSuggestions)
                }
            }
        }
    }

    // MARK: - Reminders section

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Reminders")
            FormCard {
                RemindersEditorView(notifications: $notifications)
            }
        }
    }

    // MARK: - Notes section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Notes")
            FormCard {
                TextField("Optional notes…", text: $notes, axis: .vertical)
                    .foregroundStyle(.primary)
                    .lineLimit(3...6)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Delete section

    private var deleteSection: some View {
        Button(role: .destructive, action: deleteAndDismiss) {
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

    // MARK: - Favicon fetch (debounced)

    private func scheduleFaviconFetch(_ input: String) {
        faviconFetchTask?.cancel()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Need at least "x.co" to attempt
        guard trimmed.count >= 4, trimmed.contains(".") else { return }

        faviconFetchTask = Task {
            // Small debounce so we don't fire on every keystroke
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }

            await MainActor.run { isFetchingIcon = true }
            let data = await FaviconFetcher.fetch(from: trimmed)
            await MainActor.run {
                if let data { iconData = data }
                isFetchingIcon = false
            }
        }
    }

    // MARK: - Populate

    private func populateFromItem() {
        guard let item else { return }
        name = item.name
        url = item.url
        nextRenewalDate = item.nextRenewalDate
        isAutoRenew = item.isAutoRenew
        isCancelled = item.isCancelled
        isTrial = item.isTrial
        if let t = item.trialEndDate { trialEndDate = t }
        if let u = item.activeUntilDate { activeUntilDate = u }
        if let c = item.cost { costText = String(c) }
        cost = item.cost
        currency = item.currency
        billingCycle = item.billingCycle
        paymentMethod = item.paymentMethod
        emailUsed = item.emailUsed
        phoneNumber = item.phoneNumber
        notes = item.notes
        iconData = item.iconData
        notifications = item.notifications
    }

    // MARK: - Save

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let savedItem: SubscriptionItem
        if let existing = item {
            existing.name = trimmedName
            existing.url = url
            existing.iconData = iconData
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
            existing.phoneNumber = phoneNumber
            existing.notes = notes
            existing.notifications = notifications
            existing.updatedAt = Date()
            savedItem = existing
        } else {
            let newItem = SubscriptionItem(
                name: trimmedName,
                cost: cost,
                currency: currency,
                billingCycle: billingCycle,
                nextRenewalDate: nextRenewalDate,
                trialEndDate: isTrial ? trialEndDate : nil,
                isAutoRenew: isAutoRenew,
                isCancelled: isCancelled,
                activeUntilDate: isCancelled ? activeUntilDate : nil,
                paymentMethod: paymentMethod,
                emailUsed: emailUsed,
                phoneNumber: phoneNumber,
                notes: notes,
                url: url,
                notifications: notifications
            )
            newItem.iconData = iconData
            modelContext.insert(newItem)
            savedItem = newItem
        }
        Task { await NotificationManager.shared.reschedule(for: savedItem) }
        dismiss()
    }

    private func deleteAndDismiss() {
        if let item {
            NotificationManager.shared.removeAll(for: item)
            modelContext.delete(item)
        }
        dismiss()
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.horizontal, 4)
    }
}

// MARK: - Suggestion Field

struct SuggestionField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16))
                    .frame(minWidth: 80, alignment: .leading)
                    .foregroundStyle(.primary)
                TextField(placeholder, text: $text)
                    .foregroundStyle(.primary)
                    .trailingTextAlignment()
#if os(iOS)
                    .keyboardType(resolvedKeyboardType)
                    .textInputAutocapitalization(label == "Email" ? .never : .sentences)
#endif
                if !suggestions.isEmpty {
                    Button {
                        withAnimation(.spring(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if isExpanded && !suggestions.isEmpty {
                Divider().padding(.leading, 16)
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            withAnimation { text = suggestion; isExpanded = false }
                        } label: {
                            HStack {
                                Text(suggestion)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.left")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.04))
                        }
                        .buttonStyle(.plain)
                        if suggestion != suggestions.last {
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

#if os(iOS)
    private var resolvedKeyboardType: UIKeyboardType {
        switch label {
        case "Email": return .emailAddress
        case "Phone": return .phonePad
        default: return .default
        }
    }
#endif
}

// MARK: - Form Building Blocks

struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
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
            content.foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct FormDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
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
