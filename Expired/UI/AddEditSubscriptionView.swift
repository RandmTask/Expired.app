import SwiftUI
import SwiftData

struct AddEditSubscriptionView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [SubscriptionItem]

    let item: SubscriptionItem?

    // Core
    @State private var itemType: ItemType = .subscription
    @State private var name = ""
    @State private var url = ""
    @State private var nextRenewalDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var expiryDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var isAutoRenew = true
    @State private var isCancelled = false
    @State private var isTrial = false
    @State private var trialEndDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var activeUntilDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

    // Icon
    @State private var iconData: Data? = nil
    @State private var iconSource: IconSource = .system
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

    // Account
    @State private var personName = ""

    // Reminders & notes
    @State private var notifications: [NotificationRule] = []
    @State private var notes = ""

    // Account field sheets
    @State private var showCurrencyPicker = false

    // Persistent suggestion store (UserDefaults-backed)
    @AppStorage("savedNames")  private var savedNamesData:  Data = Data()
    @AppStorage("savedCards")  private var savedCardsData:  Data = Data()
    @AppStorage("savedEmails") private var savedEmailsData: Data = Data()
    @AppStorage("savedPhones") private var savedPhonesData: Data = Data()

    private var isEditing: Bool { item != nil }

    // MARK: - Suggestions

    private var savedNames: [String] {
        (try? JSONDecoder().decode([String].self, from: savedNamesData)) ?? []
    }
    private var savedCards: [String] {
        (try? JSONDecoder().decode([String].self, from: savedCardsData)) ?? []
    }
    private var savedEmails: [String] {
        (try? JSONDecoder().decode([String].self, from: savedEmailsData)) ?? []
    }
    private var savedPhones: [String] {
        (try? JSONDecoder().decode([String].self, from: savedPhonesData)) ?? []
    }

    private var nameSuggestions: [String] {
        let fromItems = allItems.compactMap { $0.personName.isEmpty ? nil : $0.personName }
        return Array(Set(savedNames + fromItems)).sorted()
    }
    private var paymentSuggestions: [String] {
        let fromItems = allItems.compactMap { $0.paymentMethod.isEmpty ? nil : $0.paymentMethod }
        return Array(Set(savedCards + fromItems)).sorted()
    }
    private var emailSuggestions: [String] {
        let fromItems = allItems.compactMap { $0.emailUsed.isEmpty ? nil : $0.emailUsed }
        return Array(Set(savedEmails + fromItems)).sorted()
    }
    private var phoneSuggestions: [String] {
        let fromItems = allItems.compactMap { $0.phoneNumber.isEmpty ? nil : $0.phoneNumber }
        return Array(Set(savedPhones + fromItems)).sorted()
    }

    func persistSuggestion(_ value: String, type: SuggestionFieldType) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch type {
        case .name:
            var list = savedNames
            if !list.contains(trimmed) { list.append(trimmed); savedNamesData = (try? JSONEncoder().encode(list)) ?? Data() }
        case .card:
            var list = savedCards
            if !list.contains(trimmed) { list.append(trimmed); savedCardsData = (try? JSONEncoder().encode(list)) ?? Data() }
        case .email:
            var list = savedEmails
            if !list.contains(trimmed) { list.append(trimmed); savedEmailsData = (try? JSONEncoder().encode(list)) ?? Data() }
        case .phone:
            var list = savedPhones
            if !list.contains(trimmed) { list.append(trimmed); savedPhonesData = (try? JSONEncoder().encode(list)) ?? Data() }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    itemTypeSection
                    basicSection
                    if itemType == .subscription { statusSection }
                    if itemType == .subscription { costSection }
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
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(isEditing ? "Edit" : (itemType == .document ? "Add Document" : "Add Subscription"))
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

    // MARK: - Item Type section

    private var itemTypeSection: some View {
        FormCard {
            HStack(spacing: 0) {
                ForEach(ItemType.allCases, id: \.self) { type in
                    Button {
                        withAnimation(.spring(duration: 0.25)) { itemType = type }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: type.icon)
                                .font(.system(size: 14, weight: .semibold))
                            Text(type.rawValue)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(itemType == type ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            itemType == type
                                ? (type == .document ? Color.indigo.opacity(0.15) : Color.blue.opacity(0.12))
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                }
            }
        }
    }

    // MARK: - Basic section

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: itemType == .document ? "Document" : "Subscription")
            FormCard {
                VStack(spacing: 0) {
                    // Name + icon
                    HStack(spacing: 12) {
                        iconView
                            .padding(.leading, 16)
                        TextField(itemType == .document ? "Document Name" : "Name", text: $name)
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .submitLabel(.next)
                            .padding(.vertical, 14)
                            .padding(.trailing, 16)
                    }

                    FormDivider()

                    // Website — favicon auto-fetches when URL changes (subscriptions only)
                    if itemType == .subscription {
                        HStack {
                            Text("Website")
                                .font(.system(size: 16))
                                .frame(minWidth: 80, alignment: .leading)
                                .foregroundStyle(.primary)
                            TextField("netflix.com", text: $url)
                                .foregroundStyle(.primary)
                                .trailingTextAlignment()
#if os(iOS)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
#endif
                                .onSubmit { scheduleFaviconFetch(url, delay: false) }
                                .onChange(of: url) { _, newValue in
                                    scheduleFaviconFetch(newValue, delay: true)
                                }
                            if isFetchingIcon {
                                ProgressView().scaleEffect(0.75).padding(.leading, 4)
                            } else if iconData != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .padding(.leading, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        FormDivider()
                    }

                    // Date field: expiry for documents, renew/trial for subscriptions
                    if itemType == .document {
                        FormRow(label: "Expires") {
                            DatePicker("", selection: $expiryDate, displayedComponents: .date)
                                .labelsHidden()
                        }
                    } else {
                        FormRow(label: isTrial ? "Trial Ends" : "Renews") {
                            DatePicker("", selection: isTrial ? $trialEndDate : $nextRenewalDate,
                                       displayedComponents: .date)
                                .labelsHidden()
                        }
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
                .fill(itemType == .document ? Color.indigo.opacity(0.12) : Color.blue.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: itemType == .document ? "doc.text.fill" : "globe")
                        .font(.system(size: 16))
                        .foregroundStyle(itemType == .document ? .indigo.opacity(0.7) : .blue.opacity(0.5))
                }
        }
    }

    // MARK: - Status section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Status")
            FormCard {
                VStack(spacing: 0) {
                    // Three status chips on one row
                    HStack(spacing: 10) {
                        StatusChip(
                            label: "Auto-Renews",
                            icon: "arrow.clockwise",
                            color: .green,
                            isOn: isAutoRenew
                        ) {
                            isAutoRenew.toggle()
                            if isAutoRenew { isCancelled = false }
                        }
                        StatusChip(
                            label: "Trial",
                            icon: "gift",
                            color: .purple,
                            isOn: isTrial
                        ) {
                            isTrial.toggle()
                            if isTrial && notifications.isEmpty {
                                notifications = [
                                    NotificationRule(offsetType: .daysBefore, value: 3),
                                    NotificationRule(offsetType: .daysBefore, value: 1)
                                ]
                            }
                        }
                        StatusChip(
                            label: "Cancelled",
                            icon: "xmark",
                            color: .orange,
                            isOn: isCancelled
                        ) {
                            isCancelled.toggle()
                            if isCancelled { isAutoRenew = false }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

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
                        HStack(spacing: 8) {
                            TextField("0.00", text: $costText)
                                .foregroundStyle(.primary)
                                .trailingTextAlignment()
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                                .onChange(of: costText) { _, val in cost = Double(val) }
                            Button {
                                showCurrencyPicker = true
                            } label: {
                                HStack(spacing: 3) {
                                    Text(CurrencyInfo.symbol(for: currency))
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(currency)
                                        .font(.system(size: 13, weight: .semibold))
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .sheet(isPresented: $showCurrencyPicker) {
                                CurrencyPickerSheet(selectedCode: $currency)
                                    .presentationDetents([.medium, .large])
                                    .presentationDragIndicator(.visible)
                            }
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
                    AccountField(
                        label: "Name", placeholder: "Account holder name",
                        text: $personName,
                        suggestions: nameSuggestions,
                        fieldType: .name,
                        onPersist: { v, t in persistSuggestion(v, type: t) }
                    )
                    FormDivider()
                    AccountField(
                        label: "Payment",
                        placeholder: "e.g. Visa, PayPal, Gift Card…",
                        hint: "Description only — don't enter card numbers",
                        text: $paymentMethod,
                        suggestions: paymentSuggestions,
                        fieldType: .card,
                        onPersist: { v, t in persistSuggestion(v, type: t) }
                    )
                    FormDivider()
                    AccountField(
                        label: "Email", placeholder: "you@example.com",
                        text: $emailUsed,
                        suggestions: emailSuggestions,
                        fieldType: .email,
                        onPersist: { v, t in persistSuggestion(v, type: t) }
                    )
                    FormDivider()
                    AccountField(
                        label: "Phone", placeholder: "+61 400 000 000",
                        text: $phoneNumber,
                        suggestions: phoneSuggestions,
                        fieldType: .phone,
                        onPersist: { v, t in persistSuggestion(v, type: t) }
                    )
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
            // Plain card — no glass, just the standard grouped material
            TextField("Optional notes…", text: $notes, axis: .vertical)
                .foregroundStyle(.primary)
                .lineLimit(3...6)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    // MARK: - Delete section

    private var deleteSection: some View {
        Button(role: .destructive, action: deleteAndDismiss) {
            HStack {
                Spacer()
                Label("Delete \(itemType.rawValue)", systemImage: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
        }
        .padding(.vertical, 14)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Favicon fetch (debounced)

    private func scheduleFaviconFetch(_ input: String, delay: Bool = true) {
        faviconFetchTask?.cancel()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Need at least "x.co" to attempt
        guard trimmed.count >= 4, trimmed.contains(".") else { return }

        faviconFetchTask = Task {
            // Short debounce so we don't fire on every keystroke
            if delay {
                try? await Task.sleep(for: .milliseconds(800))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { isFetchingIcon = true }
            let data = await FaviconFetcher.fetch(from: trimmed)
            await MainActor.run {
                if let data {
                    iconData = data
                    iconSource = .favicon
                }
                isFetchingIcon = false
            }
        }
    }

    // MARK: - Populate

    private func populateFromItem() {
        guard let item else { return }
        itemType = item.itemType
        name = item.name
        url = item.url
        nextRenewalDate = item.nextRenewalDate
        if let e = item.expiryDate { expiryDate = e }
        isAutoRenew = item.isAutoRenew
        isCancelled = item.isCancelled
        isTrial = item.isTrial
        if let t = item.trialEndDate { trialEndDate = t }
        if let u = item.activeUntilDate { activeUntilDate = u }
        if let c = item.cost { costText = String(c) }
        cost = item.cost
        currency = item.currency
        billingCycle = item.billingCycle
        personName = item.personName
        paymentMethod = item.paymentMethod
        emailUsed = item.emailUsed
        phoneNumber = item.phoneNumber
        notes = item.notes
        iconData = item.iconData
        iconSource = item.iconSource
        notifications = item.notifications
    }

    // MARK: - Save

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let resolvedIconSource: IconSource = (iconData != nil) ? .favicon : .system

        let savedItem: SubscriptionItem
        if let existing = item {
            existing.itemType = itemType
            existing.name = trimmedName
            existing.url = itemType == .subscription ? url : ""
            existing.iconData = iconData
            existing.iconSource = resolvedIconSource
            existing.nextRenewalDate = nextRenewalDate
            existing.expiryDate = itemType == .document ? expiryDate : nil
            existing.isAutoRenew = itemType == .subscription ? isAutoRenew : false
            existing.isCancelled = itemType == .subscription ? isCancelled : false
            existing.trialEndDate = (itemType == .subscription && isTrial) ? trialEndDate : nil
            existing.activeUntilDate = (itemType == .subscription && isCancelled) ? activeUntilDate : nil
            existing.cost = itemType == .subscription ? cost : nil
            existing.currency = currency
            existing.billingCycle = billingCycle
            existing.personName = personName
            existing.paymentMethod = paymentMethod
            existing.emailUsed = emailUsed
            existing.phoneNumber = phoneNumber
            existing.notes = notes
            existing.notifications = notifications
            existing.updatedAt = Date()
            savedItem = existing
        } else {
            let newItem = SubscriptionItem(
                itemType: itemType,
                name: trimmedName,
                iconSource: resolvedIconSource,
                cost: itemType == .subscription ? cost : nil,
                currency: currency,
                billingCycle: billingCycle,
                nextRenewalDate: nextRenewalDate,
                trialEndDate: (itemType == .subscription && isTrial) ? trialEndDate : nil,
                expiryDate: itemType == .document ? expiryDate : nil,
                isAutoRenew: itemType == .subscription ? isAutoRenew : false,
                isCancelled: itemType == .subscription ? isCancelled : false,
                activeUntilDate: (itemType == .subscription && isCancelled) ? activeUntilDate : nil,
                personName: personName,
                paymentMethod: paymentMethod,
                emailUsed: emailUsed,
                phoneNumber: phoneNumber,
                notes: notes,
                url: itemType == .subscription ? url : "",
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

// MARK: - Suggestion Field Type

enum SuggestionFieldType {
    case name, card, email, phone
}

// MARK: - Account Field
// Replaces SheetPickerField. Tapping the field shows saved suggestions inline.
// The + button opens a sheet to enter a new value, with an optional "Save for later" toggle.

struct AccountField: View {
    let label: String
    let placeholder: String
    var hint: String? = nil
    @Binding var text: String
    let suggestions: [String]
    let fieldType: SuggestionFieldType
    let onPersist: (String, SuggestionFieldType) -> Void

    @State private var showSuggestions = false
    @State private var showAddNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16))
                    .frame(minWidth: 80, alignment: .leading)
                    .foregroundStyle(.primary)

                // Tapping anywhere on the value area shows suggestions if any exist
                Button {
                    if suggestions.isEmpty {
                        showAddNew = true
                    } else {
                        showSuggestions = true
                    }
                } label: {
                    HStack {
                        if text.isEmpty {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            Text(text)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .buttonStyle(.plain)

                // + always opens the add-new sheet
                Button {
                    showAddNew = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue.opacity(0.8))
                        .padding(.leading, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        // Suggestions sheet
        .sheet(isPresented: $showSuggestions) {
            AccountSuggestionsSheet(
                label: label,
                suggestions: suggestions,
                current: text,
                onSelect: { value in text = value },
                onAddNew: { showAddNew = true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // Add new value sheet
        .sheet(isPresented: $showAddNew) {
            AddAccountValueSheet(
                label: label,
                fieldType: fieldType,
                onSave: { value, shouldPersist in
                    text = value
                    if shouldPersist {
                        onPersist(value, fieldType)
                    }
                }
            )
            .presentationDetents([.height(260)])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Account Suggestions Sheet (existing values)

struct AccountSuggestionsSheet: View {
    let label: String
    let suggestions: [String]
    let current: String
    let onSelect: (String) -> Void
    let onAddNew: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(suggestions, id: \.self) { item in
                    Button {
                        onSelect(item)
                        dismiss()
                    } label: {
                        HStack {
                            Text(item).foregroundStyle(.primary)
                            Spacer()
                            if item == current {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(label)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                        // Small delay so dismiss animation completes before next sheet opens
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onAddNew() }
                    } label: {
                        Label("Add New", systemImage: "plus")
                    }
                }
            }
        }
    }
}

// MARK: - Add Account Value Sheet (new entry + optional save)

struct AddAccountValueSheet: View {
    let label: String
    let fieldType: SuggestionFieldType
    let onSave: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var value = ""
    @State private var shouldSave = true
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(fieldType == .card ? "e.g. Visa, PayPal, Apple Pay…" : placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    TextField(placeholder, text: $value)
                        .font(.system(size: 16))
                        .padding(12)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                        .focused($focused)
#if os(iOS)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(fieldType == .email ? .never : .words)
#endif
                }

                if fieldType == .card {
                    Text("Enter a description only — never store actual card numbers here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }

                Toggle(isOn: $shouldSave) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save for future use")
                            .font(.system(size: 15))
                        Text("Appears as a quick-pick option next time")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.blue)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .navigationTitle("Add \(label)")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { dismiss(); return }
                        onSave(trimmed, shouldSave)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    private var placeholder: String {
        switch fieldType {
        case .name:  return "Full name"
        case .card:  return "Visa, PayPal, Apple Pay…"
        case .email: return "you@example.com"
        case .phone: return "+61 400 000 000"
        }
    }

#if os(iOS)
    private var keyboardType: UIKeyboardType {
        switch fieldType {
        case .email: return .emailAddress
        case .phone: return .phonePad
        default:     return .default
        }
    }
#endif
}

// MARK: - Status Chip

struct StatusChip: View {
    let label: String
    let icon: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "\(icon).circle.fill" : "\(icon).circle")
                    .font(.system(size: 14, weight: .semibold))
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isOn ? color : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isOn ? color.opacity(0.14) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Form Building Blocks

struct FormCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.glassEffect(in: .rect(cornerRadius: 20))
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

// MARK: - Currency Info

enum CurrencyInfo {
    typealias Entry = (code: String, symbol: String, name: String)

    /// Default currencies shown without any user customisation.
    static let defaults: [Entry] = [
        ("AUD", "A$",  "Australian Dollar"),
        ("USD", "$",   "US Dollar"),
        ("EUR", "€",   "Euro"),
        ("GBP", "£",   "British Pound"),
        ("INR", "₹",   "Indian Rupee"),
        ("AED", "د.إ", "UAE Dirham"),
        ("SGD", "S$",  "Singapore Dollar"),
        ("NZD", "NZ$", "New Zealand Dollar"),
        ("CAD", "C$",  "Canadian Dollar"),
        ("JPY", "¥",   "Japanese Yen"),
        ("CHF", "Fr",  "Swiss Franc"),
        ("HKD", "HK$", "Hong Kong Dollar"),
        ("CNY", "¥",   "Chinese Yuan"),
        ("KRW", "₩",   "South Korean Won"),
        ("BRL", "R$",  "Brazilian Real"),
        ("ZAR", "R",   "South African Rand"),
        ("SEK", "kr",  "Swedish Krona"),
        ("NOK", "kr",  "Norwegian Krone"),
        ("MXN", "MX$", "Mexican Peso"),
        ("THB", "฿",   "Thai Baht"),
    ]

    static func symbol(for code: String) -> String {
        defaults.first { $0.code == code }?.symbol ?? code
    }
}

// MARK: - Currency Picker Sheet

struct CurrencyPickerSheet: View {
    @Binding var selectedCode: String
    @Environment(\.dismiss) private var dismiss

    @AppStorage("customCurrencies") private var customCurrenciesData: Data = Data()
    // Use @State for the list so mutations immediately re-render the List
    @State private var customList: [String] = []
    @State private var searchText = ""
    @State private var showAddCustom = false
    @State private var newCurrencyCode = ""

    private var allEntries: [CurrencyInfo.Entry] {
        let custom: [CurrencyInfo.Entry] = customList.map { code in
            (code, code, "Custom")
        }
        return CurrencyInfo.defaults + custom
    }

    private var filtered: [CurrencyInfo.Entry] {
        guard !searchText.isEmpty else { return allEntries }
        return allEntries.filter {
            $0.code.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func persistCustomList() {
        customCurrenciesData = (try? JSONEncoder().encode(customList)) ?? Data()
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.code) { entry in
                    Button {
                        selectedCode = entry.code
                        dismiss()
                    } label: {
                        HStack {
                            Text(entry.symbol)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .frame(width: 40, alignment: .leading)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.code)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(entry.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.code == selectedCode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if customList.contains(entry.code) {
                            Button(role: .destructive) {
                                customList.removeAll { $0 == entry.code }
                                persistCustomList()
                                if selectedCode == entry.code { selectedCode = "AUD" }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search currencies")
            .navigationTitle("Currency")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        newCurrencyCode = ""
                        showAddCustom = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Add Currency", isPresented: $showAddCustom) {
                TextField("ISO code, e.g. SAR", text: $newCurrencyCode)
                Button("Add") {
                    let code = newCurrencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let existing = CurrencyInfo.defaults.map(\.code) + customList
                    guard !code.isEmpty, !existing.contains(code) else { return }
                    customList.append(code)
                    persistCustomList()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a 3-letter ISO currency code (e.g. SAR, QAR, TWD).")
            }
            .onAppear {
                customList = (try? JSONDecoder().decode([String].self, from: customCurrenciesData)) ?? []
            }
        }
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
