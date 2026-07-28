import SwiftUI
import SwiftData

/// Debug section content, reachable via a hidden 4-second long-press (iOS) / ⌥-click
/// (macOS) on the Settings version footer — never a visible control. Renders as plain
/// `Section`s embedded directly into the Settings screen's own List (not a sheet), so
/// once revealed it stays visible across navigation until "Hide Debug" is tapped —
/// per `_shared/settings-conventions.md`'s "Hidden debug section" convention. Bundles
/// the AI-cascade failure simulator with the other developer utilities (replay
/// onboarding, mascot preview, reset data, CloudKit debug, diagnostic report). Safe to
/// ship in TestFlight (no visible affordance); strip before public App Store release.
struct DebugAIFailureSimulatorView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var cloudKitDebug = CloudKitDebugStore.shared

    /// Re-conceals the section — the caller owns the persisted reveal flag.
    let onHide: () -> Void

    @State private var forcedFailures: Set<ScreenshotAIProvider>
    @State private var isResyncing = false
    @State private var resyncResult: String?

    @State private var showReplayOnboarding = false
    @State private var showResetConfirm = false
    @State private var resetResult: String?

    init(onHide: @escaping () -> Void) {
        self.onHide = onHide
        _forcedFailures = State(initialValue: Set(
            DebugAIFailureSimulator.allDebuggableProviders.filter(DebugAIFailureSimulator.isForcedToFail)
        ))
    }

    var body: some View {
        Group {
            diagnosticsSection
            testingToolsSection
            resetSection
            cloudKitDebugSection
            forceFailureSection
            identityRepairSection
            hideSection
        }
        .alert("Delete All Data?", isPresented: $showResetConfirm) {
            Button("Delete Everything", role: .destructive) { resetSubscriptions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes every subscription and document — including archived items — and their reminders. This syncs to iCloud and removes them from all your signed-in devices. Cannot be undone.")
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showReplayOnboarding) {
            OnboardingView { showReplayOnboarding = false }
        }
        #endif
    }

    private var hideSection: some View {
        Section {
            Button("Hide Debug", action: onHide)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Diagnostics

    /// One-tap launch/crash diagnostic report — the fastest path to getting Deon's
    /// device state into a bug report without reading him the Xcode console.
    private var diagnosticsSection: some View {
        Section {
            Button {
                copyToPasteboard(buildDiagnosticReport())
                Haptics.fire(.success)
            } label: {
                Label("Copy Diagnostic Report", systemImage: "doc.on.doc")
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
        lines.append("")
        lines.append("Supabase user ID: \(SupabaseService.shared.currentUserID ?? "nil")")
        lines.append("")
        lines.append(cloudKitDebug.transcript())
        return lines.joined(separator: "\n")
    }

    // MARK: - Testing tools

    private var testingToolsSection: some View {
        Section {
            #if os(iOS)
            Button {
                showReplayOnboarding = true
            } label: {
                Label("Replay Onboarding", systemImage: "sparkles.rectangle.stack")
            }
            #endif
            NavigationLink {
                MascotGalleryView()
            } label: {
                Label("Mascot Gallery", systemImage: "face.smiling")
            }
        } header: {
            Text("Testing")
        } footer: {
            Text("Replay Onboarding presents the first-run pager without touching the completion flag. Mascot Gallery shows every expression the bear can display.")
        }
    }

    // MARK: - Reset

    private var resetSection: some View {
        Section {
            Button {
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
            resetResult = "Fetch failed — nothing deleted."
            return
        }
        let count = items.count
        for item in items {
            modelContext.delete(item)   // .cascade removes the item's NotificationRules
        }
        do {
            try modelContext.save()
            resetResult = "Deleted \(count) item\(count == 1 ? "" : "s")."
            let ctx = modelContext
            Task { await NotificationManager.shared.refreshAll(context: ctx) }
        } catch {
            resetResult = "Delete saved partially: \(error.localizedDescription)"
        }
    }

    // MARK: - CloudKit debug

    private var cloudKitDebugSection: some View {
        Section {
            debugRow("Account", cloudKitDebug.accountStatusText)
            debugRow("User Record", cloudKitDebug.userRecordIDText)
            debugRow("Store", cloudKitDebug.storeSummaryText)

            HStack(spacing: 10) {
                Button {
                    NotificationCenter.default.post(name: .expiredManualSync, object: nil)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    copyToPasteboard(cloudKitDebug.transcript())
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    cloudKitDebug.clear()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
            }

            if !cloudKitDebug.entries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cloudKitDebug.entries.prefix(8)) { entry in
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
                        if entry.id != cloudKitDebug.entries.prefix(8).last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("CloudKit Debug")
        } footer: {
            Text("Confirms whether CloudKit is authenticating, importing, and exporting.")
        }
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

    // MARK: - AI cascade failure simulator

    private var forceFailureSection: some View {
        Section {
            ForEach(DebugAIFailureSimulator.allDebuggableProviders) { provider in
                Toggle(provider.displayName, isOn: Binding(
                    get: { forcedFailures.contains(provider) },
                    set: { isOn in
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

    private var identityRepairSection: some View {
        Section {
            Button {
                Task {
                    isResyncing = true
                    let ok = await PurchaseManager.shared.resyncIdentityToCurrentSession(
                        supabaseUserID: SupabaseService.shared.currentUserID
                    )
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

    private func copyToPasteboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
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
