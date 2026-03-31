import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import ImagePlayground

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
    @State private var validFromDate: Date = Date()
    @State private var documentNumber: String = ""
    @State private var isAutoRenew = true
    @State private var isCancelled = false
    @State private var isTrial = false
    @State private var trialEndDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    @State private var activeUntilDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    // Single date shown in the status row — doesn't change when chips are toggled
    @State private var statusDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

    // Icon
    @State private var iconData: Data? = nil
    @State private var iconSource: IconSource = .system
    @State private var isFetchingIcon = false
    @State private var faviconFetchTask: Task<Void, Never>? = nil
    @State private var showIconMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var isDropTargeted = false
    @State private var showImagePlayground = false
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground

    // Cost & payment
    @State private var cost: Double? = nil
    @State private var costText = ""
    @AppStorage("preferredCurrency") private var preferredCurrency = SettingsView.localeCurrencyCode
    @State private var currency = ""  // set in onAppear / populateFromItem
    @State private var billingCycle: BillingCycle = .monthly
    @State private var paymentMethod = ""
    @State private var emailUsed = ""
    @State private var phoneNumber = ""

    // Account
    @State private var personName = ""

    // Category (stored as raw name string to support both built-in and user-defined categories)
    @State private var selectedCategoryRaw: String? = nil
    @State private var userCategories: [UserCategory] = []

    // Start date (optional — nil means not set)
    @State private var startDate: Date? = nil
    @State private var startDateValue: Date = Date()

    // Reminders & notes
    @State private var notifications: [NotificationRule] = []
    @State private var notes = ""

    // Account field sheets
    @State private var showCurrencyPicker = false

    // Confirmation dialogs
    @State private var showDeleteConfirmation = false
    @State private var showArchiveConfirmation = false

    // Focus tracking for cost field formatting
    @FocusState private var costFieldFocused: Bool

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
#if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { hideKeyboard() }
#endif
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
        .onAppear {
            if currency.isEmpty { currency = preferredCurrency }
            userCategories = UserCategoryStore.load()
            populateFromItem()
        }
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
            SectionHeader(title: itemType == .document ? "Document" : "Details")
            FormCard {
                VStack(spacing: 0) {
                    // Name + icon
                    HStack(spacing: 14) {
                        iconView
                            .padding(.leading, 16)
                        TextField(itemType == .document ? "Document Name" : "Name", text: $name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .submitLabel(.next)
                            .autocorrectionDisabled()
                            .padding(.vertical, 18)
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
                            TextField("eg. netflix.com or App Store URL", text: $url)
                                .foregroundStyle(.primary)
                                .trailingTextAlignment()
                                .autocorrectionDisabled()
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
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())

                        FormDivider()
                    }

                    // Date field: expiry for documents, renew/trial for subscriptions
                    if itemType == .document {
                        FormRow(label: "Expires") {
                            DatePicker("", selection: $expiryDate, displayedComponents: .date)
                                .labelsHidden()
                        }
                        FormDivider()
                        FormRow(label: "Valid From") {
                            DatePicker("", selection: $validFromDate, displayedComponents: .date)
                                .labelsHidden()
                        }
                        FormDivider()
                        HStack {
                            Text("Reference")
                                .font(.system(size: 16))
                                .frame(minWidth: 80, alignment: .leading)
                                .foregroundStyle(.primary)
                            TextField("Document / policy number", text: $documentNumber)
                                .foregroundStyle(.primary)
                                .trailingTextAlignment()
                                .autocorrectionDisabled()
#if os(iOS)
                                .textInputAutocapitalization(.characters)
#endif
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        FormDivider()
                        // Website field for documents too
                        HStack {
                            Text("Website")
                                .font(.system(size: 16))
                                .frame(minWidth: 80, alignment: .leading)
                                .foregroundStyle(.primary)
                            TextField("agency.gov.au", text: $url)
                                .foregroundStyle(.primary)
                                .trailingTextAlignment()
                                .autocorrectionDisabled()
#if os(iOS)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
#endif
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    } else {
                        // Category row — matches AccountField layout exactly
                        HStack(alignment: .center) {
                            Text("Category")
                                .font(.system(size: 16))
                                .fixedSize()
                                .foregroundStyle(.primary)
                            Menu {
                                ForEach(BuiltInCategoryStore.unifiedVisibleItems()) { item in
                                    switch item {
                                    case .builtIn(let cat):
                                        Button {
                                            hideKeyboard()
                                            selectedCategoryRaw = cat.rawValue
                                        } label: {
                                            Label(cat.displayName, systemImage: cat.icon)
                                        }
                                    case .custom(let cat):
                                        Button {
                                            hideKeyboard()
                                            selectedCategoryRaw = cat.name
                                        } label: {
                                            Label(cat.name, systemImage: cat.icon)
                                        }
                                    }
                                }
                            } label: {
                                if let raw = selectedCategoryRaw {
                                    HStack(spacing: 4) {
                                        Image(systemName: UserCategoryStore.icon(for: raw))
                                            .font(.system(size: 13))
                                        Text(SubscriptionCategory(rawValue: raw)?.displayName ?? raw)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                } else {
                                    Text("None")
                                        .foregroundStyle(.secondary.opacity(0.35))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                            }
                            .menuStyle(.borderlessButton)
#if os(macOS)
                            .menuIndicator(.hidden)
#endif
                            // Trailing action: × clears when filled, + opens menu when empty
                            if selectedCategoryRaw != nil {
                                Button {
                                    withAnimation { selectedCategoryRaw = nil }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.secondary)
                                        .padding(.leading, 6)
                                }
                                .buttonStyle(.plain)
                            } else {
                                // + button also opens the menu (matches AccountField blue +)
                                Menu {
                                    ForEach(BuiltInCategoryStore.unifiedVisibleItems()) { item in
                                        switch item {
                                        case .builtIn(let cat):
                                            Button {
                                                hideKeyboard()
                                                selectedCategoryRaw = cat.rawValue
                                            } label: {
                                                Label(cat.displayName, systemImage: cat.icon)
                                            }
                                        case .custom(let cat):
                                            Button {
                                                hideKeyboard()
                                                selectedCategoryRaw = cat.name
                                            } label: {
                                                Label(cat.name, systemImage: cat.icon)
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.blue.opacity(0.8))
                                        .padding(.leading, 6)
                                }
                                .menuStyle(.borderlessButton)
#if os(macOS)
                                .menuIndicator(.hidden)
#endif
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                    }
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        iconContent
            .frame(width: 60, height: 60)
            .overlay(alignment: .bottomTrailing) {
                // Small edit badge
                if !isFetchingIcon {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Color.blue)
                        .offset(x: 4, y: 4)
                }
            }
            .overlay {
                // Drop highlight
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.blue, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            // iOS: tap for action menu
#if os(iOS)
            .onTapGesture { showIconMenu = true }
            .confirmationDialog("Set Icon", isPresented: $showIconMenu, titleVisibility: .visible) {
                if supportsImagePlayground {
                    Button("Create with Image Playground") { showImagePlayground = true }
                }
                Button("Choose Photo") { showPhotoPicker = true }
                Button("Choose File") { showFilePicker = true }
                Button("Paste Image") { pasteImageFromClipboard() }
                if iconData != nil {
                    Button("Remove Icon", role: .destructive) { clearIcon() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoPickerItem, matching: .images)
            .onChange(of: photoPickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            iconData = data
                            iconSource = .customImage
                            photoPickerItem = nil
                        }
                    }
                }
            }
            .imagePlaygroundSheet(isPresented: $showImagePlayground, concept: name.isEmpty ? "App icon" : name) { url in
                if let data = try? Data(contentsOf: url) {
                    iconData = data
                    iconSource = .customImage
                }
            }
#else
            // macOS: click for menu
            .onTapGesture { showIconMenu = true }
            .contextMenu {
                Button("Paste Image") { pasteImageFromClipboard() }
                if iconData != nil {
                    Button("Remove Icon") { clearIcon() }
                }
            }
            .popover(isPresented: $showIconMenu, arrowEdge: .bottom) {
                macIconMenuContent
            }
#endif
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.image, .jpeg, .png, .gif, .bmp, .webP],
                allowsMultipleSelection: false
            ) { result in
                guard let url = try? result.get().first,
                      url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    iconData = data
                    iconSource = .customImage
                }
            }
            // Drag and drop (both platforms)
            .dropDestination(for: Data.self) { items, _ in
                guard let data = items.first, FaviconFetcher.isImage(data) else { return false }
                iconData = data
                iconSource = .customImage
                isDropTargeted = false
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
    }

    @ViewBuilder
    private var iconContent: some View {
        if isFetchingIcon {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.15))
                .overlay { ProgressView().scaleEffect(0.8) }
        } else if let data = iconData, let img = platformImage(from: data) {
            Image(platformImage: img)
                .resizable().scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(itemType == .document ? Color.indigo.opacity(0.12) : Color.blue.opacity(0.12))
                .overlay {
                    Image(systemName: itemType == .document ? "doc.text.fill" : "globe")
                        .font(.system(size: 22))
                        .foregroundStyle(itemType == .document ? .indigo.opacity(0.7) : .blue.opacity(0.5))
                }
        }
    }

#if os(macOS)
    private var macIconMenuContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Choose Image File…") { showIconMenu = false; showFilePicker = true }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            Button("Paste Image") { showIconMenu = false; pasteImageFromClipboard() }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if iconData != nil {
                Divider()
                Button("Remove Icon") { showIconMenu = false; clearIcon() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 180)
    }
#endif

    private func pasteImageFromClipboard() {
#if os(iOS)
        if let image = UIPasteboard.general.image,
           let data = image.pngData() {
            iconData = data
            iconSource = .customImage
        }
#else
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let first = image.first,
           let tiffData = first.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let data = bitmap.representation(using: .png, properties: [:]) {
            iconData = data
            iconSource = .customImage
        }
#endif
    }

    private func clearIcon() {
        iconData = nil
        iconSource = .system
    }


    // MARK: - Status section (chips + date + cost)

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Subscription")
            FormCard {
                VStack(spacing: 0) {
                    // Three status chips on one row
                    HStack(spacing: 8) {
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
                            color: .red,
                            isOn: isCancelled
                        ) {
                            isCancelled.toggle()
                            if isCancelled { isAutoRenew = false }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    FormDivider()
                    HStack {
                        Text(isCancelled ? "Active Until" : isTrial ? "Trial Ends" : "Renews")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .fixedSize()
                        Spacer()
                        DatePicker("", selection: $statusDate, displayedComponents: .date)
                            .labelsHidden()
                        // Quick-pick + button: bump the renewal date forward
                        Menu {
                            Button("+1 Week") {
                                statusDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: statusDate) ?? statusDate
                            }
                            Button("+1 Month") {
                                statusDate = Calendar.current.date(byAdding: .month, value: 1, to: statusDate) ?? statusDate
                            }
                            Button("+3 Months") {
                                statusDate = Calendar.current.date(byAdding: .month, value: 3, to: statusDate) ?? statusDate
                            }
                            Button("+6 Months") {
                                statusDate = Calendar.current.date(byAdding: .month, value: 6, to: statusDate) ?? statusDate
                            }
                            Button("+1 Year") {
                                statusDate = Calendar.current.date(byAdding: .year, value: 1, to: statusDate) ?? statusDate
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.blue.opacity(0.8))
                                .padding(.leading, 6)
                        }
                        .menuStyle(.borderlessButton)
#if os(macOS)
                        .menuIndicator(.hidden)
#endif
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    FormDivider()

                    // Start Date — optional, for accurate lifetime cost tracking
                    HStack {
                        Text("Start Date")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        Spacer()
                        if startDate != nil {
                            DatePicker("", selection: Binding(
                                get: { startDateValue },
                                set: { startDateValue = $0; startDate = $0 }
                            ), in: ...Date(), displayedComponents: .date)
                                .labelsHidden()
#if os(macOS)
                                .datePickerStyle(.field)
#endif
                            Button {
                                withAnimation { startDate = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 6)
                        } else {
                            Text("Not set")
                                .foregroundStyle(.tertiary)
                            Button {
                                withAnimation { startDate = startDateValue }
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.blue.opacity(0.8))
                                    .padding(.leading, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(minHeight: 50)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 0)
                    .contentShape(Rectangle())

                    FormDivider()
                    // Amount row
                    HStack {
                        Text("Amount")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                        Spacer()
                        TextField(CurrencyInfo.placeholder(for: currency), text: $costText)
                            .foregroundStyle(.primary)
                            .trailingTextAlignment()
                            .autocorrectionDisabled()
                            .frame(minWidth: 60)
                            .focused($costFieldFocused)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                            .onChange(of: costText) { _, val in
                                let cleaned = val.filter { $0.isNumber || $0 == "." }
                                if cleaned != val { costText = cleaned }
                                cost = Double(cleaned)
                            }
                            .onChange(of: costFieldFocused) { _, isFocused in
                                if !isFocused, let c = cost {
                                    costText = CurrencyInfo.formatForEntry(c, code: currency)
                                }
                            }
                            .onChange(of: currency) { _, _ in
                                if let c = cost {
                                    costText = CurrencyInfo.formatForEntry(c, code: currency)
                                }
                            }
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
                        .currencyPickerPresentation(isPresented: $showCurrencyPicker, selectedCode: $currency)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                    FormDivider()
                    FormRow(label: "Billing") {
                        Picker("", selection: $billingCycle) {
                            ForEach(BillingCycle.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.menu)
                    }
                }
                .animation(.spring(duration: 0.25), value: isCancelled)
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
                    FormDivider()
                    AccountField(
                        label: "Payment",
                        placeholder: "e.g. Visa, PayPal, Gift Card…",
                        text: $paymentMethod,
                        suggestions: paymentSuggestions,
                        fieldType: .card,
                        onPersist: { v, t in persistSuggestion(v, type: t) }
                    )
                }
            }
            // Payment disclaimer sits outside the card row, below it
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Do **not** enter card numbers — enter description only")
                    .font(.system(size: 13))
            }
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Reminders section

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Reminders")
            FormCard {
                RemindersEditorView(
                    notifications: $notifications,
                    baseDate: itemType == .document ? expiryDate : statusDate
                )
            }
        }
    }

    // MARK: - Notes section

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Notes")
            TextField("Optional notes…", text: $notes, axis: .vertical)
                .foregroundStyle(.primary)
                .lineLimit(3...6)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(notesBackground, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var notesBackground: Color {
#if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
#else
        Color(nsColor: .controlBackgroundColor)
#endif
    }

    // MARK: - Delete section

    private var isCurrentlyArchived: Bool { item?.isArchived == true }

    private var deleteSection: some View {
        HStack(spacing: 12) {
            // Archive / Unarchive button
            Button {
                showArchiveConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Label(isCurrentlyArchived ? "Unarchive" : "Archive",
                          systemImage: isCurrentlyArchived ? "arrow.uturn.left" : "archivebox")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
            }
            .padding(.vertical, 14)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 16))
            .confirmationDialog(
                isCurrentlyArchived ? "Unarchive this item?" : "Archive this item?",
                isPresented: $showArchiveConfirmation,
                titleVisibility: .visible
            ) {
                Button(isCurrentlyArchived ? "Unarchive" : "Archive") { archiveAndDismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(isCurrentlyArchived
                    ? "This item will be moved back to your active list."
                    : "This item will be hidden from your main list and stored in the Archive.")
            }

            // Delete button
            Button {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
            }
            .padding(.vertical, 14)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 16))
            .confirmationDialog(
                "Delete this \(itemType.rawValue.lowercased())?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteAndDismiss() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
        }
    }

    // MARK: - Favicon fetch (debounced)

    private func hideKeyboard() {
#if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
    }

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

            // For App Store URLs: also populate the name field if it's empty
            let normalised = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://\(trimmed)"
            if let host = URLComponents(string: normalised)?.host,
               (host == "apps.apple.com" || host == "itunes.apple.com"),
               let appID = FaviconFetcher.appStoreID(from: normalised) {
                async let artworkFetch = FaviconFetcher.fetch(from: trimmed)
                async let nameFetch = FaviconFetcher.fetchAppStoreName(appID: appID)
                let (data, appName) = await (artworkFetch, nameFetch)
                await MainActor.run {
                    if let data {
                        iconData = data
                        iconSource = .favicon
                    }
                    // Only auto-fill name if the user hasn't typed one yet
                    if let appName, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = appName
                    }
                    isFetchingIcon = false
                }
                return
            }

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
        // Populate isTrial from whether a future trialEndDate exists, not item.isTrial
        // (item.isTrial returns false when isCancelled is true, losing the trial state)
        if let t = item.trialEndDate, t > Date() {
            isTrial = true
            trialEndDate = t
        } else if let t = item.trialEndDate {
            trialEndDate = t
        }
        if let u = item.activeUntilDate { activeUntilDate = u }
        // statusDate: show the most relevant date for the current status
        if item.isCancelled, let u = item.activeUntilDate {
            statusDate = u
        } else if let t = item.trialEndDate, t > Date() {
            statusDate = t
        } else {
            statusDate = item.nextRenewalDate
        }
        if let c = item.cost { costText = CurrencyInfo.formatForEntry(c, code: item.currency) }
        cost = item.cost
        currency = item.currency
        billingCycle = item.billingCycle
        personName = item.personName
        paymentMethod = item.paymentMethod
        emailUsed = item.emailUsed
        phoneNumber = item.phoneNumber
        notes = item.notes
        documentNumber = item.documentNumber ?? ""
        if let vf = item.validFromDate { validFromDate = vf }
        iconData = item.iconData
        iconSource = item.iconSource
        notifications = item.notificationsList
        selectedCategoryRaw = item.categoryRaw
        if let sd = item.startDate {
            startDate = sd
            startDateValue = sd
        }
    }

    // MARK: - Save

    private func saveAndDismiss() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        // Trim all text fields
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedPersonName = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPayment = paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = emailUsed.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDocNum = documentNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalise cost to 2dp
        if let c = cost { cost = (c * 100).rounded() / 100 }

        let resolvedIconSource: IconSource = (iconData != nil) ? .favicon : .system
        let isDoc = itemType == .document

        let savedItem: SubscriptionItem
        if let existing = item {
            existing.itemType = itemType
            existing.name = trimmedName
            existing.url = isDoc ? "" : trimmedURL
            existing.iconData = iconData
            existing.iconSource = resolvedIconSource
            existing.nextRenewalDate = (!isDoc && !isCancelled && !isTrial) ? statusDate : nextRenewalDate
            existing.expiryDate = isDoc ? expiryDate : nil
            existing.validFromDate = isDoc ? validFromDate : nil
            existing.documentNumber = isDoc ? trimmedDocNum.isEmpty ? nil : trimmedDocNum : nil
            existing.isAutoRenew = isDoc ? false : isAutoRenew
            existing.isCancelled = isDoc ? false : isCancelled
            existing.trialEndDate = (!isDoc && isTrial) ? statusDate : nil
            existing.activeUntilDate = (!isDoc && isCancelled) ? statusDate : nil
            existing.cost = isDoc ? nil : cost
            existing.currency = currency
            existing.billingCycle = billingCycle
            existing.personName = trimmedPersonName
            existing.paymentMethod = trimmedPayment
            existing.emailUsed = trimmedEmail
            existing.phoneNumber = trimmedPhone
            existing.notes = trimmedNotes
            existing.notifications = notifications
            existing.categoryRaw = isDoc ? nil : selectedCategoryRaw
            existing.startDate = isDoc ? nil : startDate
            existing.updatedAt = Date()
            savedItem = existing
        } else {
            let newItem = SubscriptionItem(
                itemType: itemType,
                name: trimmedName,
                iconSource: resolvedIconSource,
                cost: isDoc ? nil : cost,
                currency: currency,
                billingCycle: billingCycle,
                nextRenewalDate: (!isDoc && !isCancelled && !isTrial) ? statusDate : nextRenewalDate,
                trialEndDate: (!isDoc && isTrial) ? statusDate : nil,
                expiryDate: isDoc ? expiryDate : nil,
                isAutoRenew: isDoc ? false : isAutoRenew,
                isCancelled: isDoc ? false : isCancelled,
                activeUntilDate: (!isDoc && isCancelled) ? statusDate : nil,
                personName: trimmedPersonName,
                paymentMethod: trimmedPayment,
                emailUsed: trimmedEmail,
                phoneNumber: trimmedPhone,
                notes: trimmedNotes,
                url: isDoc ? "" : trimmedURL,
                documentNumber: isDoc ? trimmedDocNum.isEmpty ? nil : trimmedDocNum : nil,
                validFromDate: isDoc ? validFromDate : nil,
                startDate: isDoc ? nil : startDate,
                notifications: notifications
            )
            newItem.categoryRaw = isDoc ? nil : selectedCategoryRaw
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

    private func archiveAndDismiss() {
        if let item {
            item.isArchived = !item.isArchived
            item.updatedAt = Date()
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

    @State private var showAddNew = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(label)
                    .font(.system(size: 16))
                    .fixedSize()
                    .foregroundStyle(.primary)

                if suggestions.isEmpty {
                    // No saved values yet — tapping the value area opens add-new
                    Button {
                        showAddNew = true
                    } label: {
                        Text(text.isEmpty ? placeholder : text)
                            .foregroundStyle(text.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(Color.primary))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Saved values exist — show an inline Menu picker (suggestions only)
                    Menu {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                text = suggestion
                            } label: {
                                if suggestion == text {
                                    Label(suggestion, systemImage: "checkmark")
                                } else {
                                    Text(suggestion)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(text.isEmpty ? placeholder : text)
                                .foregroundStyle(text.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.35)) : AnyShapeStyle(Color.primary))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .menuStyle(.borderlessButton)
#if os(macOS)
                    .menuIndicator(.hidden)
#endif
                }

                // Trailing action: × clears when filled (red), + opens sheet when empty
                if text.isEmpty {
                    Button {
                        showAddNew = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue.opacity(0.8))
                            .padding(.leading, 6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
            .presentationDetents([.height(280)])
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
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(fieldType == .email ? .never : .words)
                        .textContentType(fieldType == .phone ? .telephoneNumber : .none)
#endif
                        .onChange(of: value) { _, newVal in
                            if fieldType == .phone {
                                let formatted = formatPhoneNumber(newVal)
                                if formatted != newVal { value = formatted }
                            }
                        }
                }

                // Payment disclaimer shown outside the FormCard, not here


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

    /// Formats a phone number with spaces after country code and in digit groups.
    /// e.g. "+97155957..." → "+971 55 957 4189"
    /// Preserves the raw string if it doesn't start with +.
    private func formatPhoneNumber(_ raw: String) -> String {
        // Strip everything except digits and leading +
        let digits = raw.filter { $0.isNumber }
        let hasPlus = raw.hasPrefix("+")

        guard hasPlus, !digits.isEmpty else { return raw }

        // International format: +[country_code] [local groups]
        // Try to detect common country code lengths (1, 2, or 3 digits)
        // We use a simple heuristic: insert space after 1, 2, or 3 digit prefix
        // based on total length and first digit
        let prefix: String
        let local: String

        switch digits.first {
        case "1":           // USA/Canada: +1 XXX XXX XXXX
            prefix = String(digits.prefix(1))
            local  = String(digits.dropFirst(1))
        case "7":           // Russia: +7 XXX XXX XX XX
            prefix = String(digits.prefix(1))
            local  = String(digits.dropFirst(1))
        case "2", "3", "4", "5", "6", "8", "9"
            where digits.count > 3:
            // 2-digit country codes (+61, +44, +49, +971, etc.)
            // Use 3-digit prefix for known Middle-East/long codes
            let threeDigit = Int(String(digits.prefix(3))) ?? 0
            if (200...299).contains(threeDigit) || (350...399).contains(threeDigit) ||
               (850...900).contains(threeDigit) || (960...999).contains(threeDigit) {
                prefix = String(digits.prefix(3))
                local  = String(digits.dropFirst(3))
            } else {
                prefix = String(digits.prefix(2))
                local  = String(digits.dropFirst(2))
            }
        default:
            return raw
        }

        // Group the local number into chunks of 2-4 digits
        let grouped = local.chunked(by: [4, 3, 4]).joined(separator: " ")
        let result = "+\(prefix) \(grouped)".trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? raw : result
    }
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
            HStack(spacing: 4) {
                Image(systemName: isOn ? "\(icon).circle.fill" : "\(icon).circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 14, height: 14)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)
            }
            .foregroundStyle(isOn ? color : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
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
                .foregroundStyle(.primary)
                .fixedSize()
            Spacer()
            content.foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

struct FormDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

// MARK: - User Category Store

/// A user-defined category entry.
struct UserCategory: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var icon: String
    var description: String? = nil

    static let defaultIcon = "tag"
}

/// Manages custom categories stored in UserDefaults alongside the built-in enum cases.
enum UserCategoryStore {
    static let key = "userDefinedCategories"

    static func load() -> [UserCategory] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cats = try? JSONDecoder().decode([UserCategory].self, from: data)
        else { return [] }
        return cats
    }

    static func save(_ categories: [UserCategory]) {
        if let data = try? JSONEncoder().encode(categories) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Returns the icon for a given raw category name, checking built-in enum first then user-defined.
    static func icon(for rawName: String) -> String {
        if let builtin = SubscriptionCategory(rawValue: rawName) { return builtin.icon }
        return load().first { $0.name == rawName }?.icon ?? UserCategory.defaultIcon
    }
}

// MARK: - Built-in Category Preferences Store

/// Persists visibility and display order for built-in SubscriptionCategory cases.
enum BuiltInCategoryStore {
    private static let hiddenKey        = "builtInCategoryHidden"
    private static let orderKey         = "builtInCategoryOrder"
    /// Stores the full interleaved order as tagged strings, e.g. ["builtin:streaming", "custom:uuid-xxxx"]
    static let unifiedOrderKey          = "unifiedCategoryOrder"

    // MARK: Unified interleaved order

    static func saveUnifiedOrder(_ tags: [String]) {
        UserDefaults.standard.set(tags, forKey: unifiedOrderKey)
    }

    static func loadUnifiedOrder() -> [String]? {
        UserDefaults.standard.stringArray(forKey: unifiedOrderKey)
    }

    // MARK: Visibility

    /// Returns the set of rawValues that are hidden in the category picker.
    static func hiddenRawValues() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        return Set(arr)
    }

    static func setHidden(_ rawValue: String, hidden: Bool) {
        var current = hiddenRawValues()
        if hidden { current.insert(rawValue) } else { current.remove(rawValue) }
        UserDefaults.standard.set(Array(current), forKey: hiddenKey)
    }

    // MARK: Order

    /// Returns the ordered list of rawValues. Missing cases are appended at the end.
    static func orderedRawValues() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        let all = SubscriptionCategory.allCases.map { $0.rawValue }
        // Preserve saved order, then append any new cases not yet in saved list
        var result = saved.filter { raw in all.contains(raw) }
        for raw in all where !result.contains(raw) { result.append(raw) }
        return result
    }

    static func saveOrder(_ rawValues: [String]) {
        UserDefaults.standard.set(rawValues, forKey: orderKey)
    }

    // MARK: Convenience

    /// Ordered, visible built-in categories for use in the category picker.
    static func visibleCategories() -> [SubscriptionCategory] {
        let hidden = hiddenRawValues()
        return orderedRawValues().compactMap { SubscriptionCategory(rawValue: $0) }
            .filter { !hidden.contains($0.rawValue) }
    }

    /// All categories in display order (visible + hidden), for the settings management view.
    static func allOrdered() -> [SubscriptionCategory] {
        orderedRawValues().compactMap { SubscriptionCategory(rawValue: $0) }
    }

    /// Represents a single item in the unified (interleaved) category picker list.
    enum UnifiedCategoryItem: Identifiable {
        case builtIn(SubscriptionCategory)
        case custom(UserCategory)
        var id: String {
            switch self {
            case .builtIn(let c): return "builtin-\(c.rawValue)"
            case .custom(let c):  return "custom-\(c.id.uuidString)"
            }
        }
    }

    /// Returns the interleaved, visible categories in the order the user arranged them.
    /// Hidden built-in categories are excluded. Respects the unified order key if present.
    static func unifiedVisibleItems() -> [UnifiedCategoryItem] {
        let hidden = hiddenRawValues()
        let customMap: [String: UserCategory] = Dictionary(
            uniqueKeysWithValues: UserCategoryStore.load().map { ($0.id.uuidString, $0) }
        )
        let builtInMap: [String: SubscriptionCategory] = Dictionary(
            uniqueKeysWithValues: SubscriptionCategory.allCases.map { ($0.rawValue, $0) }
        )

        if let tags = loadUnifiedOrder(), !tags.isEmpty {
            var result: [UnifiedCategoryItem] = []
            for tag in tags {
                if tag.hasPrefix("builtin:") {
                    let raw = String(tag.dropFirst(8))
                    if let cat = builtInMap[raw], !hidden.contains(raw) {
                        result.append(.builtIn(cat))
                    }
                } else if tag.hasPrefix("custom:") {
                    let uuid = String(tag.dropFirst(7))
                    if let cat = customMap[uuid] { result.append(.custom(cat)) }
                }
            }
            // Append any new built-ins not yet in the saved list
            let seenBuiltIns = Set(result.compactMap { if case .builtIn(let c) = $0 { return c.rawValue } else { return nil } })
            for cat in allOrdered() where !seenBuiltIns.contains(cat.rawValue) && !hidden.contains(cat.rawValue) {
                result.append(.builtIn(cat))
            }
            // Append any new customs not yet in the saved list
            let seenCustoms = Set(result.compactMap { if case .custom(let c) = $0 { return c.id.uuidString } else { return nil } })
            for cat in UserCategoryStore.load() where !seenCustoms.contains(cat.id.uuidString) {
                result.append(.custom(cat))
            }
            return result
        }

        // Fallback: built-ins first, then customs
        let builtIns = visibleCategories().map { UnifiedCategoryItem.builtIn($0) }
        let customs  = UserCategoryStore.load().map { UnifiedCategoryItem.custom($0) }
        return builtIns + customs
    }
}

// MARK: - Currency Info

enum CurrencyInfo {
    typealias Entry = (code: String, symbol: String, name: String)

    /// All supported currencies with symbols and display names.
    static let defaults: [Entry] = [
        ("AUD", "A$",   "Australian Dollar"),
        ("USD", "$",    "US Dollar"),
        ("EUR", "€",    "Euro"),
        ("GBP", "£",    "British Pound"),
        ("INR", "₹",    "Indian Rupee"),
        ("AED", "د.إ",  "UAE Dirham"),
        ("SGD", "S$",   "Singapore Dollar"),
        ("NZD", "NZ$",  "New Zealand Dollar"),
        ("CAD", "C$",   "Canadian Dollar"),
        ("JPY", "¥",    "Japanese Yen"),
        ("CHF", "Fr",   "Swiss Franc"),
        ("HKD", "HK$",  "Hong Kong Dollar"),
        ("CNY", "¥",    "Chinese Yuan"),
        ("KRW", "₩",    "South Korean Won"),
        ("BRL", "R$",   "Brazilian Real"),
        ("ZAR", "R",    "South African Rand"),
        ("SEK", "kr",   "Swedish Krona"),
        ("NOK", "kr",   "Norwegian Krone"),
        ("MXN", "MX$",  "Mexican Peso"),
        ("THB", "฿",    "Thai Baht"),
        ("SAR", "﷼",    "Saudi Riyal"),
        ("TRY", "₺",    "Turkish Lira"),
        ("TWD", "NT$",  "Taiwan New Dollar"),
        ("DKK", "kr",   "Danish Krone"),
        ("PLN", "zł",   "Polish Zloty"),
        ("IDR", "Rp",   "Indonesian Rupiah"),
        ("HUF", "Ft",   "Hungarian Forint"),
        ("CZK", "Kč",   "Czech Koruna"),
        ("ILS", "₪",    "Israeli New Shekel"),
        ("CLP", "CL$",  "Chilean Peso"),
        ("PHP", "₱",    "Philippine Peso"),
    ]

    /// Exchange rates relative to 1 USD (snapshot — updated manually or via future API).
    /// Used only for converting totals to a display currency; individual item amounts are stored as-is.
    static let ratesFromUSD: [String: Double] = [
        "USD": 1.00000,
        "EUR": 0.86540,
        "JPY": 158.71800,
        "GBP": 0.74532,
        "AUD": 1.43193,
        "CAD": 1.37654,
        "CHF": 0.78830,
        "CNY": 6.88570,
        "HKD": 7.83270,
        "NZD": 1.71233,
        "SEK": 9.36110,
        "KRW": 1504.15000,
        "SGD": 1.28190,
        "NOK": 9.57820,
        "MXN": 17.88740,
        "INR": 93.83207,
        "BRL": 5.28960,
        "ZAR": 17.04010,
        "TRY": 44.36710,
        "TWD": 31.91000,
        "DKK": 6.47280,
        "PLN": 3.72870,
        "THB": 32.87000,
        "IDR": 11832.00000,
        "HUF": 335.63100,
        "CZK": 21.28400,
        "ILS": 3.11900,
        "CLP": 913.98000,
        "PHP": 59.53100,
        "AED": 3.67250,
        "SAR": 3.75000,
    ]

    static func symbol(for code: String) -> String {
        defaults.first { $0.code == code }?.symbol ?? code
    }

    /// Currencies that have no sub-units (no decimal places).
    static let noSubunits: Set<String> = [
        "JPY",  // Japanese Yen
        "KRW",  // South Korean Won
        "IDR",  // Indonesian Rupiah
        "CLP",  // Chilean Peso
        "HUF",  // Hungarian Forint (rounds in practice)
        "VND",  // Vietnamese Dong
        "ISK",  // Icelandic Króna
        "CRC",  // Costa Rican Colón
        "UGX",  // Ugandan Shilling
        "RWF",  // Rwandan Franc
        "BIF",  // Burundian Franc
        "GNF",  // Guinean Franc
        "XAF",  // Central African CFA Franc
        "XOF",  // West African CFA Franc
        "XPF",  // CFP Franc
        "MGA",  // Malagasy Ariary
        "PYG",  // Paraguayan Guaraní
    ]

    /// Formats an amount with correct decimal places for the given currency.
    static func format(_ amount: Double, code: String) -> String {
        let sym = symbol(for: code)
        let formatted = noSubunits.contains(code)
            ? String(format: "%.0f", amount)
            : String(format: "%.2f", amount)
        return "\(sym)\(formatted)"
    }

    /// Correct decimal places for entry/display of a given currency (0 or 2).
    static func decimalPlaces(for code: String) -> Int {
        noSubunits.contains(code) ? 0 : 2
    }

    /// Formats a raw Double to the correct number of decimal places for entry.
    static func formatForEntry(_ amount: Double, code: String) -> String {
        noSubunits.contains(code)
            ? String(format: "%.0f", amount)
            : String(format: "%.2f", amount)
    }

    /// Placeholder text appropriate for the currency (e.g. "0" for JPY, "0.00" for USD).
    static func placeholder(for code: String) -> String {
        noSubunits.contains(code) ? "0" : "0.00"
    }

    /// Converts `amount` in `fromCode` to `toCode` using the USD-pivot rates.
    /// Returns the original amount unchanged if either rate is unknown.
    static func convert(_ amount: Double, from fromCode: String, to toCode: String) -> Double {
        guard fromCode != toCode else { return amount }
        guard let fromRate = ratesFromUSD[fromCode],
              let toRate   = ratesFromUSD[toCode],
              fromRate > 0 else { return amount }
        // amount / fromRate = USD amount; * toRate = target currency
        return (amount / fromRate) * toRate
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
                        .contentShape(Rectangle())
                    }
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

// MARK: - String chunking helper (for phone formatting)

private extension String {
    /// Splits the string into groups of the given sizes in sequence,
    /// repeating the last size for any remainder.
    /// e.g. "1234567890".chunked(by: [4,3,4]) → ["1234","567","890"]
    func chunked(by sizes: [Int]) -> [String] {
        var result: [String] = []
        var idx = startIndex
        var sizeIndex = 0
        while idx < endIndex {
            let size = sizeIndex < sizes.count ? sizes[sizeIndex] : sizes.last!
            let end = index(idx, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[idx..<end]))
            idx = end
            sizeIndex += 1
        }
        return result
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
