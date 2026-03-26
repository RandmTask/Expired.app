import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

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

    // Icon
    @State private var iconData: Data? = nil
    @State private var iconSource: IconSource = .system
    @State private var isFetchingIcon = false
    @State private var faviconFetchTask: Task<Void, Never>? = nil
    @State private var showIconMenu = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var showURLEntry = false
    @State private var iconURLText = ""
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var isDropTargeted = false

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

    // Category
    @State private var category: SubscriptionCategory? = nil

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
        .onAppear {
            if currency.isEmpty { currency = preferredCurrency }
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
                            .autocorrectionDisabled()
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
                        FormRow(label: isTrial ? "Trial Ends" : "Renews") {
                            DatePicker("", selection: isTrial ? $trialEndDate : $nextRenewalDate,
                                       displayedComponents: .date)
                                .labelsHidden()
                        }
                        FormDivider()
                        FormRow(label: "Category") {
                            Menu {
                                Button {
                                    category = nil
                                } label: {
                                    if category == nil {
                                        Label("None", systemImage: "checkmark")
                                    } else {
                                        Text("None")
                                    }
                                }
                                Divider()
                                ForEach(SubscriptionCategory.allCases, id: \.self) { cat in
                                    Button {
                                        category = cat
                                    } label: {
                                        if category == cat {
                                            Label(cat.rawValue, systemImage: "checkmark")
                                        } else {
                                            Label(cat.rawValue, systemImage: cat.icon)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if let cat = category {
                                        Image(systemName: cat.icon)
                                            .font(.system(size: 13))
                                        Text(cat.rawValue)
                                    } else {
                                        Text("None")
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .foregroundStyle(category != nil ? .primary : .secondary)
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        iconContent
            .frame(width: 52, height: 52)
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
                Button("Choose Photo") { showPhotoPicker = true }
                Button("Choose File") { showFilePicker = true }
                Button("Paste Image") { pasteImageFromClipboard() }
                Button("Enter URL") { iconURLText = ""; showURLEntry = true }
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
            .alert("Image URL", isPresented: $showURLEntry) {
                TextField("https://example.com/logo.png", text: $iconURLText)
#if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
#endif
                Button("Fetch") { fetchIconFromURL(iconURLText) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter an image URL or App Store app URL")
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
            Button("Enter Image URL…") { showIconMenu = false; showURLEntry = true }
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

    private func fetchIconFromURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isFetchingIcon = true
        Task {
            let data = await FaviconFetcher.fetch(from: trimmed)
            await MainActor.run {
                if let data {
                    iconData = data
                    iconSource = .customImage
                }
                isFetchingIcon = false
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
                                .autocorrectionDisabled()
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                                .onChange(of: costText) { _, val in
                                    // Allow partial input while typing (e.g. "1.")
                                    cost = Double(val)
                                }
                                .onSubmit {
                                    if let c = cost {
                                        costText = String(format: "%.2f", c)
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
                RemindersEditorView(notifications: $notifications)
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
        if let c = item.cost { costText = String(format: "%.2f", c) }
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
        category = item.category
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
            existing.nextRenewalDate = nextRenewalDate
            existing.expiryDate = isDoc ? expiryDate : nil
            existing.validFromDate = isDoc ? validFromDate : nil
            existing.documentNumber = isDoc ? trimmedDocNum.isEmpty ? nil : trimmedDocNum : nil
            existing.isAutoRenew = isDoc ? false : isAutoRenew
            existing.isCancelled = isDoc ? false : isCancelled
            existing.trialEndDate = (!isDoc && isTrial) ? trialEndDate : nil
            existing.activeUntilDate = (!isDoc && isCancelled) ? activeUntilDate : nil
            existing.cost = isDoc ? nil : cost
            existing.currency = currency
            existing.billingCycle = billingCycle
            existing.personName = trimmedPersonName
            existing.paymentMethod = trimmedPayment
            existing.emailUsed = trimmedEmail
            existing.phoneNumber = trimmedPhone
            existing.notes = trimmedNotes
            existing.notifications = notifications
            existing.category = isDoc ? nil : category
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
                nextRenewalDate: nextRenewalDate,
                trialEndDate: (!isDoc && isTrial) ? trialEndDate : nil,
                expiryDate: isDoc ? expiryDate : nil,
                isAutoRenew: isDoc ? false : isAutoRenew,
                isCancelled: isDoc ? false : isCancelled,
                activeUntilDate: (!isDoc && isCancelled) ? activeUntilDate : nil,
                personName: trimmedPersonName,
                paymentMethod: trimmedPayment,
                emailUsed: trimmedEmail,
                phoneNumber: trimmedPhone,
                notes: trimmedNotes,
                url: isDoc ? "" : trimmedURL,
                documentNumber: isDoc ? trimmedDocNum.isEmpty ? nil : trimmedDocNum : nil,
                validFromDate: isDoc ? validFromDate : nil,
                category: isDoc ? nil : category,
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

    @State private var showAddNew = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16))
                    .frame(minWidth: 80, alignment: .leading)
                    .foregroundStyle(.primary)

                if suggestions.isEmpty {
                    // No saved values yet — tapping the value area opens add-new
                    Button {
                        showAddNew = true
                    } label: {
                        Text(text.isEmpty ? placeholder : text)
                            .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
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
                                .foregroundStyle(text.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .menuStyle(.borderlessButton)
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
            HStack(spacing: 5) {
                Image(systemName: isOn ? "\(icon).circle.fill" : "\(icon).circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 16, height: 16)  // fixed frame prevents symbol size variance
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
        .padding(.vertical, 14)
    }
}

struct FormDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
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

    /// Formats an amount as "symbol + 2dp number", e.g. "A$55.00", "€12.99"
    static func format(_ amount: Double, code: String) -> String {
        let sym = symbol(for: code)
        // JPY, KRW, IDR, CLP, HUF have no sub-units — show 0dp
        let noSubunits: Set<String> = ["JPY", "KRW", "IDR", "CLP", "HUF"]
        let formatted = noSubunits.contains(code)
            ? String(format: "%.0f", amount)
            : String(format: "%.2f", amount)
        return "\(sym)\(formatted)"
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
