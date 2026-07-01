import SwiftUI

/// Testing-only sheet, reachable via a hidden long-press on the Settings "Analyzer"
/// row — never a visible control. Forces one or more cascade providers to fail so
/// Automatic's skip-on-failure path can be watched without a real outage.
struct DebugAIFailureSimulatorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var forcedFailures: Set<ScreenshotAIProvider>
    @State private var isResyncing = false
    @State private var resyncResult: String?

    init() {
        _forcedFailures = State(initialValue: Set(
            DebugAIFailureSimulator.allDebuggableProviders.filter(DebugAIFailureSimulator.isForcedToFail)
        ))
    }

    var body: some View {
        NavigationStack {
            List {
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
                    Text("Force Failure")
                } footer: {
                    Text("Makes Automatic skip this provider as if it were down, without a real outage — On-Device forces the whole cascade to reach Gemini/DeepSeek. Testing only — never shown to real users.")
                }

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
            .navigationTitle("Debug: AI Cascade")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 240)
        #endif
    }
}
