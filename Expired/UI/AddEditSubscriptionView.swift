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

    // Reminders & notes
    @State private var notifications: [NotificationRule] = []
    @State private var notes = ""

    // Suggestion sheets
    @State private var showPaymentPicker = false
    @State private var showEmailPicker = false
    @State private var showPhonePicker = false
    @State private var showCurrencyPicker = false

    // Save-to-suggestions prompt
    @State private var pendingSaveValue: String = ""
    @State private var pendingSaveField: SuggestionFieldType? = nil
    @State private var showSavePrompt = false

    // Persistent suggestion store (UserDefaults-backed)
    @AppStorage("savedCards") private var savedCardsData: Data = Data()
    @AppStorage("savedEmails") private var savedEmailsData: Data = Data()
    @AppStorage("savedPhones") private var savedPhonesData: Data = Data()

    private var isEditing: Bool { item != nil }

    // MARK: - Suggestions

    private var savedCards: [String] {
        (try? JSONDecoder().decode([String].self, from: savedCardsData)) ?? []
    }
    private var savedEmails: [String] {
        (try? JSONDecoder().decode([String].self, from: savedEmailsData)) ?? []
    }
    private var savedPhones: [String] {
        (try? JSONDecoder().decode([String].self, from: savedPhonesData)) ?? []
    }

    private var paymentSuggestions: [String] {
        let persisted = savedCards
        let fromItems = allItems.compactMap { $0.paymentMethod.isEmpty ? nil : $0.paymentMethod }
        return Array(Set(persisted + fromItems)).filter { $0 != paymentMethod }.sorted()
    }
    private var emailSuggestions: [String] {
        let persisted = savedEmails
        let fromItems = allItems.compactMap { $0.emailUsed.isEmpty ? nil : $0.emailUsed }
        return Array(Set(persisted + fromItems)).filter { $0 != emailUsed }.sorted()
    }
    private var phoneSuggestions: [String] {
        let persisted = savedPhones
        let fromItems = allItems.compactMap { $0.phoneNumber.isEmpty ? nil : $0.phoneNumber }
        return Array(Set(persisted + fromItems)).filter { $0 != phoneNumber }.sorted()
    }

    private func persistSuggestion(_ value: String, type: SuggestionFieldType) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch type {
        case .card:
            var list = savedCards
            if !list.contains(trimmed) {
                list.append(trimmed)
                savedCardsData = (try? JSONEncoder().encode(list)) ?? Data()
            }
        case .email:
            var list = savedEmails
            if !list.contains(trimmed) {
                list.append(trimmed)
                savedEmailsData = (try? JSONEncoder().encode(list)) ?? Data()
            }
        case .phone:
            var list = savedPhones
            if !list.contains(trimmed) {
                list.append(trimmed)
                savedPhonesData = (try? JSONEncoder().encode(list)) ?? Data()
            }
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
                    SheetPickerField(
                        label: "Card", placeholder: "Visa ****1234",
                        text: $paymentMethod, suggestions: paymentSuggestions,
                        showPicker: $showPaymentPicker
                    )
                    FormDivider()
                    SheetPickerField(
                        label: "Email", placeholder: "you@example.com",
                        text: $emailUsed, suggestions: emailSuggestions,
                        showPicker: $showEmailPicker
                    )
                    FormDivider()
                    SheetPickerField(
                        label: "Phone", placeholder: "+61 400 000 000",
                        text: $phoneNumber, suggestions: phoneSuggestions,
                        showPicker: $showPhonePicker
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

        // Check if any account values are new and should be saved
        checkAndPromptSave()

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

    /// Check each account field: if the value isn't already in suggestions, prompt once to save it.
    private func checkAndPromptSave() {
        let cardTrimmed = paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailTrimmed = emailUsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneTrimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        if !cardTrimmed.isEmpty && !savedCards.contains(cardTrimmed) {
            persistSuggestion(cardTrimmed, type: .card)
        }
        if !emailTrimmed.isEmpty && !savedEmails.contains(emailTrimmed) {
            persistSuggestion(emailTrimmed, type: .email)
        }
        if !phoneTrimmed.isEmpty && !savedPhones.contains(phoneTrimmed) {
            persistSuggestion(phoneTrimmed, type: .phone)
        }
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
    case card, email, phone
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

// MARK: - Sheet Picker Field

struct SheetPickerField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let suggestions: [String]
    @Binding var showPicker: Bool

    var body: some View {
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
                    showPicker = true
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .sheet(isPresented: $showPicker) {
            SuggestionPickerSheet(label: label, suggestions: suggestions, selection: $text)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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

// MARK: - Suggestion Picker Sheet

struct SuggestionPickerSheet: View {
    let label: String
    let suggestions: [String]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(suggestions, id: \.self) { item in
                    Button {
                        selection = item
                        dismiss()
                    } label: {
                        HStack {
                            Text(item)
                                .foregroundStyle(.primary)
                            Spacer()
                            if item == selection {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(label)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
    /// Well-known currencies with their symbols and display order.
    static let builtIn: [(code: String, symbol: String, name: String)] = [
        ("AUD", "A$",  "Australian Dollar"),
        ("USD", "$",   "US Dollar"),
        ("EUR", "€",   "Euro"),
        ("GBP", "£",   "British Pound"),
        ("CAD", "C$",  "Canadian Dollar"),
        ("NZD", "NZ$", "New Zealand Dollar"),
        ("AED", "د.إ", "UAE Dirham"),
        ("SGD", "S$",  "Singapore Dollar"),
        ("HKD", "HK$", "Hong Kong Dollar"),
        ("JPY", "¥",   "Japanese Yen"),
        ("CNY", "¥",   "Chinese Yuan"),
        ("INR", "₹",   "Indian Rupee"),
        ("CHF", "Fr",  "Swiss Franc"),
        ("SEK", "kr",  "Swedish Krona"),
        ("NOK", "kr",  "Norwegian Krone"),
        ("DKK", "kr",  "Danish Krone"),
        ("MXN", "MX$", "Mexican Peso"),
        ("BRL", "R$",  "Brazilian Real"),
        ("ZAR", "R",   "South African Rand"),
        ("THB", "฿",   "Thai Baht"),
        ("KRW", "₩",   "South Korean Won"),
    ]

    static func symbol(for code: String) -> String {
        builtIn.first { $0.code == code }?.symbol ?? code
    }
}

// MARK: - Currency Picker Sheet

struct CurrencyPickerSheet: View {
    @Binding var selectedCode: String
    @Environment(\.dismiss) private var dismiss

    // Persisted custom currencies (JSON array of code strings)
    @AppStorage("customCurrencies") private var customCurrenciesData: Data = Data()
    @State private var searchText = ""
    @State private var showAddCustom = false
    @State private var newCurrencyCode = ""

    private var customCurrencies: [String] {
        (try? JSONDecoder().decode([String].self, from: customCurrenciesData)) ?? []
    }

    private func saveCustomCurrencies(_ list: [String]) {
        customCurrenciesData = (try? JSONEncoder().encode(list)) ?? Data()
    }

    private var allEntries: [(code: String, symbol: String, name: String)] {
        let custom = customCurrencies.map { code -> (code: String, symbol: String, name: String) in
            // Try to get a locale-based symbol for the custom code
            let locale = Locale(identifier: "en_\(code)")
            let sym = locale.currencySymbol ?? code
            return (code, sym, "Custom")
        }
        return CurrencyInfo.builtIn + custom
    }

    private var filtered: [(code: String, symbol: String, name: String)] {
        guard !searchText.isEmpty else { return allEntries }
        return allEntries.filter {
            $0.code.localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
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
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .frame(width: 36, alignment: .leading)
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
                        // Only allow deleting custom entries
                        if customCurrencies.contains(entry.code) {
                            Button(role: .destructive) {
                                var list = customCurrencies
                                list.removeAll { $0 == entry.code }
                                saveCustomCurrencies(list)
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
            .alert("Add Custom Currency", isPresented: $showAddCustom) {
                TextField("Currency code (e.g. SAR)", text: $newCurrencyCode)
#if os(iOS)
                    .textInputAutocapitalization(.characters)
#endif
                Button("Add") {
                    let code = newCurrencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    guard !code.isEmpty, !customCurrencies.contains(code),
                          !CurrencyInfo.builtIn.map(\.code).contains(code) else { return }
                    saveCustomCurrencies(customCurrencies + [code])
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a 3-letter ISO currency code.")
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
