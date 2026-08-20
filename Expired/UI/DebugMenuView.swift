import SwiftUI
import SwiftData

/// Pushed debug screen — reached via a single gated "Debug Menu" row in Settings,
/// itself only shown after the hidden 4-second long-press (iOS) / ⌥-click (macOS) on
/// the version footer reveals it. Everything developer-only lives here instead of being
/// injected inline into Settings, so Settings stays one tidy screen and Debug becomes
/// its own drill-in space that can push further sub-screens (e.g. CloudKit Debug) —
/// per `_shared/settings-conventions.md`'s "Hidden debug section" and debug-structure
/// conventions.
///
/// Must be reached via `NavigationLink` from Settings' own `NavigationStack`, never
/// presented as a sheet — a sheet gives this screen no navigation stack of its own, so
/// the `NavigationLink` to Mascot Gallery / CloudKit Debug below would render but do
/// nothing on tap.
struct DebugMenuView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PurchaseManager.self) private var purchaseManager

    /// Re-conceals the section — the caller owns the persisted reveal flag.
    let onHide: () -> Void

    @State private var forcedFailures: Set<ScreenshotAIProvider>
    @State private var isResyncing = false
    @State private var resyncResult: String?

    @State private var showResetConfirm = false
    @State private var resetResult: String?

    /// AI model override — a developer stopgap until model resolution moves
    /// server-side (see `modelPickerNote` below). Shares the same AppStorage key as
    /// Settings' user-facing Analyzer provider picker, so switching provider there is
    /// reflected here automatically.
    @AppStorage(ScreenshotAISettings.providerKey) private var screenshotAIProviderRaw = ScreenshotAIProvider.automatic.rawValue

    /// Experimental same-plane title layout on Home — see HomeView.debugSamePlaneTitle.
    /// Must be removed before launch; row is tinted orange as a standing reminder.
    @AppStorage("debugSamePlaneTitle") private var debugSamePlaneTitle = false

    /// Experimental hidden/pull-to-reveal search bar on Home — see HomeView.debugHiddenSearch.
    /// Must be removed before launch; row is tinted orange as a standing reminder.
    @AppStorage("debugHiddenSearch") private var debugHiddenSearch = false
    @State private var selectedModels: [String: String] = [:]
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    init(onHide: @escaping () -> Void) {
        self.onHide = onHide
        _forcedFailures = State(initialValue: Set(
            DebugAIFailureSimulator.allDebuggableProviders.filter(DebugAIFailureSimulator.isForcedToFail)
        ))
    }

    private var screenshotAIProvider: ScreenshotAIProvider {
        ScreenshotAIProvider(rawValue: screenshotAIProviderRaw) ?? .automatic
    }

    var body: some View {
        List {
            diagnosticsSection
            testingToolsSection
            experimentalSection
            aiModelOverrideSection
            forceFailureSection
            identityRepairSection
            cloudKitLinkSection
            resetSection
            hideSection
        }
        .navigationTitle("Debug")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadSelectedModels(); loadModels() }
        .onChange(of: screenshotAIProviderRaw) { _, _ in loadModels() }
        .alert("Delete All Data?", isPresented: $showResetConfirm) {
            Button("Delete Everything", role: .destructive) { resetSubscriptions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes every subscription and document — including archived items — and their reminders. This syncs to iCloud and removes them from all your signed-in devices. Cannot be undone.")
        }
    }

    private var hideSection: some View {
        Section {
            Button("Hide Debug") {
                Haptics.fire(.light)
                onHide()
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Diagnostics

    /// One-tap launch/crash diagnostic report — the fastest path to getting Deon's
    /// device state into a bug report without reading him the Xcode console.
    private var diagnosticsSection: some View {
        Section {
            CopyFeedbackButton(label: "Copy Diagnostic Report", systemImage: "doc.on.doc") {
                buildDiagnosticReport()
            }
            if BackendConfig.revenueCatAPIKey.hasPrefix("test_") {
                Label("RevenueCat is using a TEST STORE key — swap before App Store submission", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Copies app/device/CloudKit/RevenueCat/Supabase state as text — paste it directly into a bug report.")
        }
    }

    private func buildDiagnosticReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model))"
        #elseif os(macOS)
        let platform = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        let platform = "Unknown"
        #endif
        let keyMode = BackendConfig.revenueCatAPIKey.hasPrefix("test_") ? "TEST STORE (not production-safe)" : "Production"

        var lines: [String] = []
        lines.append("Expired Diagnostic Report")
        lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .standard))")
        lines.append("App: \(version) (\(build))")
        lines.append("Platform: \(platform)")
        lines.append("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        lines.append("")
        lines.append("RevenueCat key mode: \(keyMode)")
        lines.append("RevenueCat configured: \(PurchaseManager.shared.isConfigured)")
        lines.append("RevenueCat appUserID: \(PurchaseManager.shared.appUserID ?? "nil")")
        lines.append("isPremium: \(PurchaseManager.shared.isPremium)")
        lines.append("  entitlement: \(PurchaseManager.shared.entitlementIsPremium), debug override: \(PurchaseManager.shared.debugOverride.rawValue)")
        lines.append("")
        lines.append("Supabase user ID: \(SupabaseService.shared.currentUserID ?? "nil")")
        lines.append("")
        lines.append(CloudKitDebugStore.shared.transcript())
        return lines.joined(separator: "\n")
    }

    // MARK: - Testing tools

    private var testingToolsSection: some View {
        Section {
            NavigationLink {
                MascotGalleryView()
            } label: {
                Label("Mascot Gallery", systemImage: "face.smiling")
            }
            Picker(selection: Bindable(purchaseManager).debugOverride) {
                ForEach(PurchaseManager.DebugOverride.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            } label: {
                Label("Pro Gates", systemImage: "crown")
            }
        } header: {
            Text("Testing")
        } footer: {
            Text("Mascot Gallery shows every expression the bear can display. Pro Gates forces every Premium gate on or off without buying or refunding — real entitlement is \(purchaseManager.entitlementIsPremium ? "active" : "inactive").")
        }
    }

    // MARK: - Experimental (temporary — must be removed before launch)

    private var experimentalSection: some View {
        Section {
            Toggle(isOn: $debugSamePlaneTitle) {
                Label("Same-Plane Title (Home)", systemImage: "flask.fill")
            }
            .tint(.orange)
            .listRowBackground(Color.orange.opacity(0.15))

            Toggle(isOn: $debugHiddenSearch) {
                Label("Hidden Search, Pull to Reveal (Home)", systemImage: "flask.fill")
            }
            .tint(.orange)
            .listRowBackground(Color.orange.opacity(0.15))

            Label("Experimental — remove these toggles before launch", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .listRowBackground(Color.orange.opacity(0.15))
        } header: {
            Text("Experimental")
        } footer: {
            Text("Same-Plane Title puts the \"Expired\" title on the same row as the +/⋯ buttons on Home, instead of its own row below them. Hidden Search removes the search field from view until you pull down at the top of the list, matching Mail/Reminders — instead of the minimized search icon.")
        }
    }

    // MARK: - AI model override

    private var currentSelectedModel: String {
        selectedModels[screenshotAIProvider.rawValue] ?? screenshotAIProvider.selectedModelID
    }

    /// Picker options: live-fetched ∪ current selection ∪ hardcoded default, so a
    /// tag always exists for the current value even before a successful fetch.
    private var modelPickerOptions: [String] {
        var set = Set(availableModels)
        set.insert(currentSelectedModel)
        set.insert(screenshotAIProvider.defaultModelID)
        return set.filter { !$0.isEmpty }.sorted()
    }

    private func modelLabel(_ model: String) -> String {
        model == screenshotAIProvider.defaultModelID ? "\(model) (default)" : model
    }

    private func setSelectedModel(_ model: String) {
        screenshotAIProvider.setSelectedModelID(model)
        withTransaction(Transaction(animation: nil)) {
            selectedModels[screenshotAIProvider.rawValue] = screenshotAIProvider.selectedModelID
        }
    }

    private func loadSelectedModels() {
        var dict: [String: String] = [:]
        for provider in ScreenshotAIProvider.allCases where provider.requiresAPIKey {
            dict[provider.rawValue] = provider.selectedModelID
        }
        selectedModels = dict
    }

    /// Fetches the live model list for the current provider via the Supabase `models`
    /// function (server holds the key). Guards against a stale response landing after
    /// the user has switched provider.
    private func loadModels() {
        availableModels = []
        modelLoadError = nil
        let provider = screenshotAIProvider
        guard provider.requiresAPIKey else { return }
        isLoadingModels = true
        Task {
            do {
                let models = try await ScreenshotAIModelService.listModels(provider: provider)
                await MainActor.run {
                    guard screenshotAIProvider == provider else { return }
                    availableModels = models
                    isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    guard screenshotAIProvider == provider else { return }
                    modelLoadError = error.localizedDescription
                    isLoadingModels = false
                }
            }
        }
    }

    private var aiModelOverrideSection: some View {
        Section {
            if screenshotAIProvider.requiresAPIKey {
                HStack {
                    Text("Model").foregroundStyle(.primary)
                    Spacer()
                    if isLoadingModels { ProgressView().controlSize(.small) }
                    Menu {
                        ForEach(modelPickerOptions, id: \.self) { model in
                            Button {
                                Haptics.fire(.selectionChanged)
                                setSelectedModel(model)
                            } label: {
                                if currentSelectedModel == model {
                                    Label(modelLabel(model), systemImage: "checkmark")
                                } else {
                                    Text(modelLabel(model))
                                }
                            }
                        }
                    } label: {
                        Text(modelLabel(currentSelectedModel)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    Button {
                        Haptics.fire(.light)
                        loadModels()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                if let modelLoadError {
                    Text(modelLoadError)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            } else {
                Text("\(screenshotAIProvider.displayName) has no model override — switch provider in Settings → Screenshot Import.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI Model Override")
        } footer: {
            Text("Models load live from the server for the provider currently selected in Settings. A server-side default is planned — this picker is a stopgap.")
        }
    }

    // MARK: - Force AI failure

    private var forceFailureSection: some View {
        Section {
            ForEach(DebugAIFailureSimulator.allDebuggableProviders) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { forcedFailures.contains(provider) },
                    set: { isOn in
                        Haptics.fire(.selectionChanged)
                        if isOn { forcedFailures.insert(provider) } else { forcedFailures.remove(provider) }
                        DebugAIFailureSimulator.setForcedToFail(provider, isOn)
                    }
                ))
            }
        } header: {
            Text("Force AI Failure")
        } footer: {
            Text("Makes Automatic skip this provider as if it were down, without a real outage — On-Device forces the whole cascade to reach Gemini/DeepSeek.")
        }
    }

    // MARK: - Identity repair

    private var identityRepairSection: some View {
        Section {
            Button {
                Haptics.fire(.light)
                Task {
                    isResyncing = true
                    let ok = await PurchaseManager.shared.resyncIdentityToCurrentSession(
                        supabaseUserID: SupabaseService.shared.currentUserID
                    )
                    Haptics.fire(ok ? .success : .warning)
                    resyncResult = ok ? "Premium is now active on this session." : "Resynced, but still not Premium — the App Store account signed in may not hold the purchase."
                    isResyncing = false
                }
            } label: {
                if isResyncing { ProgressView() } else { Text("Resync RevenueCat to Current Session") }
            }
            .disabled(isResyncing)
            if let resyncResult {
                Text(resyncResult).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Identity Repair")
        } footer: {
            Text("Fixes a client/server identity mismatch caused by \"Reset for Testing\" — logs RevenueCat back into the current Supabase session and restores purchases onto it. Doesn't touch subscription data.")
        }
    }

    // MARK: - CloudKit debug (own pushed screen)

    private var cloudKitLinkSection: some View {
        Section {
            NavigationLink {
                CloudKitDebugDetailView()
            } label: {
                Label("CloudKit Debug", systemImage: "icloud")
            }
        } footer: {
            Text("Confirms whether CloudKit is authenticating, importing, and exporting.")
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button {
                Haptics.fire(.warning)
                showResetConfirm = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                        .frame(width: 22, alignment: .center)
                    Text("Delete All Data")
                        .foregroundStyle(.primary)
                }
            }
            if let resetResult {
                Text(resetResult).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Haptics.fire(.warning)
                Task { await PurchaseManager.shared.logOutForTesting() }
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .center)
                    Text("Reset Premium Status")
                        .foregroundStyle(.primary)
                }
            }
        } header: {
            Text("Reset Data")
        } footer: {
            Text("Delete All Data permanently deletes every subscription/document (Netflix, insurance, etc.) — not just the Pro purchase. Reset Premium Status leaves your subscription data untouched and only logs RevenueCat out to a fresh sandbox identity, so Expired Pro shows inactive again for testing the paywall.")
        }
    }

    private func resetSubscriptions() {
        let descriptor = FetchDescriptor<SubscriptionItem>()
        guard let items = try? modelContext.fetch(descriptor) else {
            Haptics.fire(.error)
            resetResult = "Fetch failed — nothing deleted."
            return
        }
        let count = items.count
        for item in items {
            modelContext.delete(item)   // .cascade removes the item's NotificationRules
        }
        do {
            try modelContext.save()
            Haptics.fire(.success)
            resetResult = "Deleted \(count) item\(count == 1 ? "" : "s")."
            let ctx = modelContext
            Task { await NotificationManager.shared.refreshAll(context: ctx) }
        } catch {
            Haptics.fire(.error)
            resetResult = "Delete saved partially: \(error.localizedDescription)"
        }
    }
}

// MARK: - CloudKit debug detail screen

/// Own pushed screen (rather than an inline Settings section) so the status rows,
/// action buttons, and activity log all have room to breathe — the previous inline
/// version cramped these into one dense card. Reached from `DebugMenuView`'s "CloudKit
/// Debug" row, per the debug-structure convention of pushing sub-screens for anything
/// with more than a couple of rows.
private struct CloudKitDebugDetailView: View {
    @ObservedObject private var cloudKitDebug = CloudKitDebugStore.shared

    var body: some View {
        List {
            Section {
                debugRow("Account", cloudKitDebug.accountStatusText)
                debugRow("User Record", cloudKitDebug.userRecordIDText)
                debugRow("Store", cloudKitDebug.storeSummaryText)
            } header: {
                Text("Status")
            }

            Section {
                Button {
                    Haptics.fire(.light)
                    NotificationCenter.default.post(name: .expiredManualSync, object: nil)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                CopyFeedbackButton(label: "Copy Transcript", systemImage: "doc.on.doc") {
                    cloudKitDebug.transcript()
                }

                Button {
                    Haptics.fire(.warning)
                    cloudKitDebug.clear()
                } label: {
                    Label("Clear Log", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } header: {
                Text("Actions")
            }

            if !cloudKitDebug.entries.isEmpty {
                Section {
                    ForEach(cloudKitDebug.entries.prefix(20)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.category)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(entry.date.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.message)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Recent Activity")
                }
            }
        }
        .navigationTitle("CloudKit Debug")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Preview grid of every mascot expression at hero and glyph sizes.
private struct MascotGalleryView: View {
    private let expressions: [(BearExpression, String)] = [
        (.happy, "happy"),
        (.sleepy, "sleepy"),
        (.expired, "expired"),
        (.celebrating, "celebrating")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ForEach(expressions, id: \.1) { expression, name in
                    VStack(spacing: 12) {
                        Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(alignment: .center, spacing: 32) {
                            ExpiredBear(expression: expression, size: 120)
                            ExpiredBear(expression: expression, size: 44)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .padding()
        }
        .navigationTitle("Mascot Gallery")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
