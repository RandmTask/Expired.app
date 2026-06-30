import SwiftUI
import SwiftData
import CloudKit
import CoreData
import Combine
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class CloudKitDebugStore: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let date: Date
        let category: String
        let message: String
    }

    static let shared = CloudKitDebugStore()

    @Published var accountStatusText = "Unknown"
    @Published var userRecordIDText = "Unknown"
    @Published var storeSummaryText = "No CloudKit activity yet"
    @Published var entries: [Entry] = []

    private init() {}

    private func apply(_ mutation: @escaping () -> Void) {
        if Thread.isMainThread {
            mutation()
        } else {
            DispatchQueue.main.async { mutation() }
        }
    }

    func record(_ message: String, category: String = "CloudKit") {
        let entry = Entry(date: Date(), category: category, message: message)
        apply {
            self.entries.insert(entry, at: 0)
            if self.entries.count > 30 {
                self.entries.removeLast(self.entries.count - 30)
            }
        }
        print(message)
    }

    func setAccountStatus(_ status: String) {
        apply { self.accountStatusText = status }
    }

    func setUserRecordID(_ recordID: String) {
        apply { self.userRecordIDText = recordID }
    }

    func setStoreSummary(_ summary: String) {
        apply { self.storeSummaryText = summary }
    }

    func clear() {
        apply { self.entries.removeAll() }
    }

    func transcript() -> String {
        var lines: [String] = []
        lines.append("CloudKit Debug Log")
        lines.append("Account: \(accountStatusText)")
        lines.append("User Record ID: \(userRecordIDText)")
        lines.append("Store: \(storeSummaryText)")
        lines.append("")
        for entry in entries.reversed() {
            lines.append("[\(entry.category)] \(entry.date.formatted(date: .omitted, time: .standard)) \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}

@main
struct ExpiredApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(ExpiredAppDelegate.self) private var appDelegate
#elseif os(macOS)
    @NSApplicationDelegateAdaptor(ExpiredAppDelegate.self) private var appDelegate
#endif

    // Persisted user preference for iCloud sync (default: on)
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true
    // Appearance: 0 = system/auto, 1 = light, 2 = dark
    @AppStorage("appearanceMode") private var appearanceMode = 0
    @Environment(\.scenePhase) private var scenePhase
    private static var diagnosticsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ExpiredCloudKitDiagnosticsEnabled")
    }
    @State private var pendingCloudKitRefreshes: [DispatchWorkItem] = []

    let container: ModelContainer

    init() {
        // Move any pre-existing plaintext API keys out of UserDefaults into the Keychain.
        ScreenshotAISettings.migrateAPIKeysToKeychainIfNeeded()

        if Self.diagnosticsEnabled {
            // Equivalent to the -com.apple.CoreData.CloudKitDebug 3 launch argument.
            UserDefaults.standard.set(3, forKey: "com.apple.CoreData.CloudKitDebug")
            CloudKitDebugStore.shared.record("[CloudKit] Debug logging enabled")
        }

        // Read the preference before the App property wrappers are initialised
        let syncOn = UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        container = Self.makeContainer(iCloudSync: syncOn)

        // NSPersistentStoreRemoteChange fires when CloudKit merges remote saves into the store.
        // We force the main SwiftData context to drop stale state so @Query re-fetches immediately.
        if Self.diagnosticsEnabled {
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: nil,
                queue: .main
            ) { _ in
                CloudKitDebugStore.shared.record("[CloudKit] ⬇ Remote store change received")
                CloudKitDebugStore.shared.setStoreSummary("Remote store change received")
            }
        }

        // NSPersistentCloudKitContainer.eventChangedNotification fires when an
        // import/export/setup operation completes. This is the high-level signal.
        if Self.diagnosticsEnabled {
            NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil,
                queue: .main
            ) { note in
                guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                        as? NSPersistentCloudKitContainer.Event else { return }
                let typeStr: String
                switch event.type {
                case .setup:  typeStr = "setup"
                case .import: typeStr = "import ⬇"
                case .export: typeStr = "export ⬆"
                @unknown default: typeStr = "unknown(\(event.type.rawValue))"
                }
                if let error = event.error {
                    CloudKitDebugStore.shared.record("[CloudKit] ✗ \(typeStr) event FAILED: \(error)")
                    CloudKitDebugStore.shared.setStoreSummary("\(typeStr) failed")
                } else if event.succeeded {
                    CloudKitDebugStore.shared.record("[CloudKit] ✓ \(typeStr) event succeeded")
                    CloudKitDebugStore.shared.setStoreSummary("\(typeStr) succeeded")
                } else {
                    CloudKitDebugStore.shared.record("[CloudKit] … \(typeStr) event in progress")
                    CloudKitDebugStore.shared.setStoreSummary("\(typeStr) in progress")
                }
            }
        }

        if Self.diagnosticsEnabled {
            Task {
                await Self.logCloudKitAccountStatus()
                await Self.probeCloudKitRecords()
            }
        }
    }

    /// Directly queries CloudKit to check if any SubscriptionItem records exist
    /// in the container. This bypasses SwiftData entirely — if records show up
    /// here but not in the app, the issue is SwiftData mirroring. If no records
    /// show up here, the iOS devices aren't writing to the cloud at all.
    static func probeCloudKitRecords() async {
        CloudKitDebugStore.shared.record("[CloudKit] ── Direct container probe ────────────────────")
        let ckContainer = CKContainer(identifier: "iCloud.com.swiftstudio.Expired")
        let db = ckContainer.privateCloudDatabase

        // SwiftData stores records with "CD_" prefix. We query by a known field
        // rather than recordName since recordName isn't queryable by default.
        let query = CKQuery(recordType: "CD_SubscriptionItem", predicate: NSPredicate(format: "CD_name != %@", ""))
        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 100)
            let successes = results.compactMap { try? $0.1.get() }
            if successes.isEmpty {
                CloudKitDebugStore.shared.record("[CloudKit] ⚠ No CD_SubscriptionItem records found in private DB")
                CloudKitDebugStore.shared.record("[CloudKit]   → Either iOS hasn't synced yet, or schema not deployed")
                CloudKitDebugStore.shared.record("[CloudKit]   → Check CloudKit Console: icloud.developer.apple.com")
                CloudKitDebugStore.shared.setStoreSummary("No SubscriptionItem records found")
            } else {
                let newestRecords = successes
                    .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
                    .prefix(8)
                CloudKitDebugStore.shared.record("[CloudKit] ✓ Found \(successes.count) CD_SubscriptionItem record(s) in private DB (up to first 100)")
                CloudKitDebugStore.shared.setStoreSummary("Found \(successes.count) CloudKit SubscriptionItem records")
                CloudKitDebugStore.shared.record("[CloudKit]   newest CloudKit records:")
                for r in newestRecords {
                    CloudKitDebugStore.shared.record("[CloudKit]   • \(r.recordID.recordName): \(r["CD_name"] as? String ?? "(no name)")")
                }
            }
        } catch let error as CKError {
            switch error.code {
            case .unknownItem:
                CloudKitDebugStore.shared.record("[CloudKit] ⚠ Record type CD_SubscriptionItem doesn't exist in container")
                CloudKitDebugStore.shared.record("[CloudKit]   → Schema not yet deployed. Run app on iOS first, or deploy via CloudKit Console")
                CloudKitDebugStore.shared.setStoreSummary("Missing CD_SubscriptionItem record type")
            case .notAuthenticated:
                CloudKitDebugStore.shared.record("[CloudKit] ✗ Not authenticated — sign into iCloud in System Settings")
                CloudKitDebugStore.shared.setAccountStatus("Not authenticated")
            case .networkUnavailable, .networkFailure:
                CloudKitDebugStore.shared.record("[CloudKit] ✗ Network error: \(error.localizedDescription)")
                CloudKitDebugStore.shared.setStoreSummary("Network error")
            case .requestRateLimited:
                CloudKitDebugStore.shared.record("[CloudKit] ⚠ Rate limited — wait and try again")
                CloudKitDebugStore.shared.setStoreSummary("Rate limited")
            case .invalidArguments:
                CloudKitDebugStore.shared.record("[CloudKit] ⚠ Query field not queryable in CloudKit Console")
                CloudKitDebugStore.shared.record("[CloudKit]   → Go to icloud.developer.apple.com > Schema > CD_SubscriptionItem")
                CloudKitDebugStore.shared.record("[CloudKit]   → Set CD_name field to 'Queryable' and deploy to Production")
                CloudKitDebugStore.shared.setStoreSummary("Query field not queryable")
            default:
                CloudKitDebugStore.shared.record("[CloudKit] ✗ CKError \(error.code.rawValue): \(error.localizedDescription)")
                CloudKitDebugStore.shared.setStoreSummary("CKError \(error.code.rawValue)")
            }
        } catch {
            CloudKitDebugStore.shared.record("[CloudKit] ✗ Probe failed: \(error)")
            CloudKitDebugStore.shared.setStoreSummary("Probe failed")
        }
        CloudKitDebugStore.shared.record("[CloudKit] ────────────────────────────────────────────")
    }

    /// Logs iCloud account status and the CloudKit user record ID.
    /// The user record ID is a stable per-account identifier — it must match
    /// across all devices for sync to work. If it differs, different Apple IDs
    /// are signed in and data will never cross between devices.
    static func logCloudKitAccountStatus() async {
        let ckContainer = CKContainer(identifier: "iCloud.com.swiftstudio.Expired")
        do {
            let status = try await ckContainer.accountStatus()
            switch status {
            case .available:
                CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account: available ✓")
                CloudKitDebugStore.shared.setAccountStatus("Available")
            case .noAccount:
                CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account: NO ACCOUNT — user not signed in to iCloud")
                CloudKitDebugStore.shared.setAccountStatus("No account")
            case .restricted:
                CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account: restricted — parental controls or MDM")
                CloudKitDebugStore.shared.setAccountStatus("Restricted")
            case .couldNotDetermine:
                CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account: could not determine — check network")
                CloudKitDebugStore.shared.setAccountStatus("Could not determine")
            case .temporarilyUnavailable:
                CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account: temporarily unavailable")
                CloudKitDebugStore.shared.setAccountStatus("Temporarily unavailable")
            @unknown default:
                CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account: unknown status \(status.rawValue)")
                CloudKitDebugStore.shared.setAccountStatus("Unknown (\(status.rawValue))")
            }
        } catch {
            CloudKitDebugStore.shared.record("[ExpiredApp] iCloud account check failed: \(error)")
            CloudKitDebugStore.shared.setAccountStatus("Check failed")
        }
        // Fetch the CloudKit user record ID — this is unique per Apple ID.
        // Compare this value across Mac, iPhone, and iPad.
        // If they differ, the devices are on different iCloud accounts and will
        // each have their own isolated private database — explaining why data
        // added on one device never appears on another.
        do {
            let userID = try await ckContainer.userRecordID()
            CloudKitDebugStore.shared.record("[ExpiredApp] CloudKit user record ID: \(userID.recordName)")
            CloudKitDebugStore.shared.record("[ExpiredApp] ⚠ Compare this value across all devices — must be identical for sync to work")
            CloudKitDebugStore.shared.setUserRecordID(userID.recordName)
        } catch {
            CloudKitDebugStore.shared.record("[ExpiredApp] CloudKit user record ID fetch failed: \(error)")
            CloudKitDebugStore.shared.setUserRecordID("Unavailable")
        }
    }

    static func makeContainer(iCloudSync: Bool) -> ModelContainer {
        let schema = Schema([SubscriptionItem.self, NotificationRule.self])

        let storeURL = URL.applicationSupportDirectory
            .appending(path: "Expired", directoryHint: .isDirectory)
            .appending(path: "default.store")

        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        CloudKitDebugStore.shared.record("[ExpiredApp] ── Launch diagnostics ──────────────────────")
        CloudKitDebugStore.shared.record("[ExpiredApp] Platform: \(platformName)")
        CloudKitDebugStore.shared.record("[ExpiredApp] Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        CloudKitDebugStore.shared.record("[ExpiredApp] CloudKit container: iCloud.com.swiftstudio.Expired")
        CloudKitDebugStore.shared.record("[ExpiredApp] Store URL: \(storeURL.path)")
        CloudKitDebugStore.shared.record("[ExpiredApp] iCloud sync enabled: \(iCloudSync)")
        CloudKitDebugStore.shared.record("[ExpiredApp] ────────────────────────────────────────────")

        // Try preferred store type first
        if iCloudSync {
            do {
                let config = ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .automatic
                )
                let c = try ModelContainer(for: schema, configurations: config)
                CloudKitDebugStore.shared.record("[ExpiredApp] CloudKit store opened successfully ✓")
                CloudKitDebugStore.shared.setStoreSummary("CloudKit store opened successfully")
                return c
            } catch {
                CloudKitDebugStore.shared.record("[ExpiredApp] CloudKit store FAILED: \(error)")
                CloudKitDebugStore.shared.record("[ExpiredApp] Falling back to local-only store")
                CloudKitDebugStore.shared.setStoreSummary("CloudKit store failed; using local-only")
            }
        }

        // Local-only store
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let c = try ModelContainer(for: schema, configurations: config)
            CloudKitDebugStore.shared.record("[ExpiredApp] Local store opened successfully")
            CloudKitDebugStore.shared.setStoreSummary("Local-only store opened")
            return c
        } catch {
            CloudKitDebugStore.shared.record("[ExpiredApp] Store failed (likely schema mismatch): \(error)")
            Self.backupSQLiteFiles(at: storeURL)
        }

        // Re-try after moving the incompatible store aside (originals preserved in Backups/)
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let c = try ModelContainer(for: schema, configurations: config)
            CloudKitDebugStore.shared.record("[ExpiredApp] Fresh store opened after backing up old schema")
            CloudKitDebugStore.shared.setStoreSummary("Fresh local store opened")
            return c
        } catch {
            CloudKitDebugStore.shared.record("[ExpiredApp] Fresh store also failed: \(error)")
        }

        CloudKitDebugStore.shared.record("[ExpiredApp] WARNING: falling back to in-memory store")
        CloudKitDebugStore.shared.setStoreSummary("In-memory fallback")
        return try! ModelContainer(for: schema,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private static var platformName: String {
#if os(macOS)
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
#elseif os(iOS)
        "iOS \(UIDevice.current.systemVersion) (\(UIDevice.current.model))"
#else
        "Unknown"
#endif
    }

    /// Moves the SQLite store triple (.store, .store-shm, .store-wal) into a timestamped
    /// Backups/ folder instead of deleting it. A schema mismatch, migration bug, or transient
    /// open failure must never destroy the user's on-device data — preserving the files keeps
    /// recovery (and a future migration path) possible.
    static func backupSQLiteFiles(at url: URL) {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = url.deletingLastPathComponent()
            .appending(path: "Backups", directoryHint: .isDirectory)
            .appending(path: stamp, directoryHint: .isDirectory)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            let dest = backupDir.appending(path: file.lastPathComponent)
            do {
                try fm.moveItem(at: file, to: dest)
                CloudKitDebugStore.shared.record("[ExpiredApp] Backed up \(file.lastPathComponent) → \(dest.path)")
            } catch {
                CloudKitDebugStore.shared.record("[ExpiredApp] Backup move failed for \(file.lastPathComponent): \(error)")
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case 1: return .light
        case 2: return .dark
        default: return nil  // system default
        }
    }

    @MainActor
    private func runSwiftDataRefreshPass(reason: String, refreshRootView: Bool = true) {
        CloudKitDebugStore.shared.record("[CloudKit]   local SwiftData refresh pass started (\(reason))")
        do {
            if container.mainContext.hasChanges {
                try container.mainContext.save()
            }
            container.mainContext.processPendingChanges()
            let items = try container.mainContext.fetch(
                FetchDescriptor<SubscriptionItem>(
                    sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
                )
            )
            let rules = try container.mainContext.fetch(FetchDescriptor<NotificationRule>())
            container.mainContext.processPendingChanges()

            if refreshRootView {
                CloudKitDebugStore.shared.record("[CloudKit]   SwiftData refresh completed without resetting UI state ✓")
            }
            CloudKitDebugStore.shared.setStoreSummary("Local SwiftData has \(items.count) SubscriptionItem records")
            CloudKitDebugStore.shared.record("[CloudKit]   local SwiftData store: \(items.count) item(s), \(rules.count) notification rule(s)")
            for item in items.prefix(8) {
                let archived = item.isArchived ? " archived" : ""
                CloudKitDebugStore.shared.record("[CloudKit]   • \(item.name)\(archived)")
            }
            CloudKitDebugStore.shared.record("[CloudKit]   local SwiftData refresh pass finished ✓")
        } catch {
            CloudKitDebugStore.shared.record("[CloudKit]   local SwiftData refresh pass failed: \(error)")
        }
    }

    private func scheduleSwiftDataRefreshPasses(reason: String) {
        for workItem in pendingCloudKitRefreshes {
            workItem.cancel()
        }
        pendingCloudKitRefreshes.removeAll()

        let passes: [(delay: TimeInterval, suffix: String, refreshRootView: Bool)] = [
            (0.0, "", true),
            (1.0, " +1s", true),
            (2.0, " +2s", false)
        ]

        for pass in passes {
            let workItem = DispatchWorkItem {
                runSwiftDataRefreshPass(reason: "\(reason)\(pass.suffix)", refreshRootView: pass.refreshRootView)
            }
            pendingCloudKitRefreshes.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + pass.delay, execute: workItem)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .environment(PurchaseManager.shared)
                .preferredColorScheme(preferredColorScheme)
                .task {
                    await NotificationManager.shared.requestAuthorization()
                }
                .task {
                    // Resolve the anonymous Supabase identity, then hand that same UUID to
                    // RevenueCat so server (proxy) and client agree on one user. Non-blocking:
                    // a failure here just means AI/purchase calls surface their own errors later.
                    try? await SupabaseService.shared.ensureSession()
                    PurchaseManager.shared.configure(appUserID: SupabaseService.shared.currentUserID)
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                    scheduleSwiftDataRefreshPasses(reason: "remote store change")
                }
                .onReceive(NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)) { note in
                    guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                            as? NSPersistentCloudKitContainer.Event,
                          event.type == .import,
                          event.succeeded
                    else { return }
                    scheduleSwiftDataRefreshPasses(reason: "CloudKit import succeeded")
                }
                .onReceive(NotificationCenter.default.publisher(for: .expiredManualSync)) { _ in
                    CloudKitDebugStore.shared.record("[CloudKit] ── Manual sync triggered ────────────────────")
                    scheduleSwiftDataRefreshPasses(reason: "manual sync")
                    Task {
                        await Self.logCloudKitAccountStatus()
                        await Self.probeCloudKitRecords()
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        scheduleSwiftDataRefreshPasses(reason: "scene became active")
                    case .inactive, .background:
                        Task { @MainActor in
                            if container.mainContext.hasChanges {
                                try? container.mainContext.save()
                                CloudKitDebugStore.shared.record("[CloudKit]   saved pending changes before leaving active scene")
                            }
                            BackupService.runAutomaticBackupIfNeeded(context: container.mainContext)
                        }
                    @unknown default:
                        break
                    }
                }
        }
#if os(macOS)
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    NotificationCenter.default.post(name: .expiredShowSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
#endif
    }
}

extension Notification.Name {
    static let expiredManualSync = Notification.Name("com.swiftstudio.Expired.manualSync")
    static let expiredShowSettings = Notification.Name("com.swiftstudio.Expired.showSettings")
}

#if os(iOS)
final class ExpiredAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        print("[CloudKit] Registered for remote notifications")
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print("[CloudKit] Remote notification registration succeeded")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[CloudKit] Remote notification registration failed: \(error)")
    }
}
#elseif os(macOS)
final class ExpiredAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications(matching: [])
        print("[CloudKit] Registered for remote notifications")
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print("[CloudKit] Remote notification registration succeeded")
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[CloudKit] Remote notification registration failed: \(error)")
    }
}
#endif
