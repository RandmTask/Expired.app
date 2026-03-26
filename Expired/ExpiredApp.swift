import SwiftUI
import SwiftData
import CloudKit

@main
struct ExpiredApp: App {
    // Persisted user preference for iCloud sync (default: on)
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true

    let container: ModelContainer

    init() {
        // Enable verbose CoreData + CloudKit mirroring logs at runtime.
        // Equivalent to the -com.apple.CoreData.CloudKitDebug 3 launch argument.
        UserDefaults.standard.set(3, forKey: "com.apple.CoreData.CloudKitDebug")

        // Read the preference before the App property wrappers are initialised
        let syncOn = UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        container = Self.makeContainer(iCloudSync: syncOn)

        // NSPersistentStoreRemoteChangeNotification fires at the CoreData store level.
        // We observe it and explicitly call refreshAllObjects() on the main context so
        // SwiftUI @Query properties re-evaluate. Without this, remote changes arrive in
        // the SQLite store but the in-memory context (and therefore the UI) never sees them.
        let modelContainer = container   // local copy for capture
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSPersistentStoreRemoteChangeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            print("[CloudKit] ⬇ Remote store change received")
            // SwiftData's mainContext is backed by NSManagedObjectContext with
            // automaticallyMergesChangesFromParent = true. Calling save() is enough
            // to flush any pending state and cause @Query descriptors to re-evaluate.
            try? modelContainer.mainContext.save()
            print("[CloudKit]   mainContext saved — @Query views will refresh ✓")
        }

        // NSPersistentCloudKitContainer.eventChangedNotification fires when an
        // import/export/setup operation completes. This is the high-level signal.
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
                print("[CloudKit] ✗ \(typeStr) event FAILED: \(error)")
            } else if event.succeeded {
                print("[CloudKit] ✓ \(typeStr) event succeeded")
            } else {
                print("[CloudKit] … \(typeStr) event in progress")
            }
        }

        Task {
            await Self.logCloudKitAccountStatus()
            await Self.probeCloudKitRecords()
        }
    }

    /// Directly queries CloudKit to check if any SubscriptionItem records exist
    /// in the container. This bypasses SwiftData entirely — if records show up
    /// here but not in the app, the issue is SwiftData mirroring. If no records
    /// show up here, the iOS devices aren't writing to the cloud at all.
    static func probeCloudKitRecords() async {
        print("[CloudKit] ── Direct container probe ────────────────────")
        let ckContainer = CKContainer(identifier: "iCloud.com.swiftstudio.Expired")
        let db = ckContainer.privateCloudDatabase

        // SwiftData stores records with "CD_" prefix. We query by a known field
        // rather than recordName since recordName isn't queryable by default.
        let query = CKQuery(recordType: "CD_SubscriptionItem", predicate: NSPredicate(format: "CD_name != %@", ""))
        do {
            let (results, _) = try await db.records(matching: query, resultsLimit: 5)
            let successes = results.compactMap { try? $0.1.get() }
            if successes.isEmpty {
                print("[CloudKit] ⚠ No CD_SubscriptionItem records found in private DB")
                print("[CloudKit]   → Either iOS hasn't synced yet, or schema not deployed")
                print("[CloudKit]   → Check CloudKit Console: icloud.developer.apple.com")
            } else {
                print("[CloudKit] ✓ Found \(successes.count) CD_SubscriptionItem record(s) in private DB")
                for r in successes {
                    print("[CloudKit]   • \(r.recordID.recordName): \(r["CD_name"] as? String ?? "(no name)")")
                }
            }
        } catch let error as CKError {
            switch error.code {
            case .unknownItem:
                print("[CloudKit] ⚠ Record type CD_SubscriptionItem doesn't exist in container")
                print("[CloudKit]   → Schema not yet deployed. Run app on iOS first, or deploy via CloudKit Console")
            case .notAuthenticated:
                print("[CloudKit] ✗ Not authenticated — sign into iCloud in System Settings")
            case .networkUnavailable, .networkFailure:
                print("[CloudKit] ✗ Network error: \(error.localizedDescription)")
            case .requestRateLimited:
                print("[CloudKit] ⚠ Rate limited — wait and try again")
            case .invalidArguments:
                print("[CloudKit] ⚠ Query field not queryable in CloudKit Console")
                print("[CloudKit]   → Go to icloud.developer.apple.com > Schema > CD_SubscriptionItem")
                print("[CloudKit]   → Set CD_name field to 'Queryable' and deploy to Production")
            default:
                print("[CloudKit] ✗ CKError \(error.code.rawValue): \(error.localizedDescription)")
            }
        } catch {
            print("[CloudKit] ✗ Probe failed: \(error)")
        }
        print("[CloudKit] ────────────────────────────────────────────")
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
            case .available:      print("[ExpiredApp] iCloud account: available ✓")
            case .noAccount:      print("[ExpiredApp] iCloud account: NO ACCOUNT — user not signed in to iCloud")
            case .restricted:     print("[ExpiredApp] iCloud account: restricted — parental controls or MDM")
            case .couldNotDetermine: print("[ExpiredApp] iCloud account: could not determine — check network")
            case .temporarilyUnavailable: print("[ExpiredApp] iCloud account: temporarily unavailable")
            @unknown default:     print("[ExpiredApp] iCloud account: unknown status \(status.rawValue)")
            }
        } catch {
            print("[ExpiredApp] iCloud account check failed: \(error)")
        }
        // Fetch the CloudKit user record ID — this is unique per Apple ID.
        // Compare this value across Mac, iPhone, and iPad.
        // If they differ, the devices are on different iCloud accounts and will
        // each have their own isolated private database — explaining why data
        // added on one device never appears on another.
        do {
            let userID = try await ckContainer.userRecordID()
            print("[ExpiredApp] CloudKit user record ID: \(userID.recordName)")
            print("[ExpiredApp] ⚠ Compare this value across all devices — must be identical for sync to work")
        } catch {
            print("[ExpiredApp] CloudKit user record ID fetch failed: \(error)")
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

        print("[ExpiredApp] ── Launch diagnostics ──────────────────────")
        print("[ExpiredApp] Platform: \(platformName)")
        print("[ExpiredApp] Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("[ExpiredApp] CloudKit container: iCloud.com.swiftstudio.Expired")
        print("[ExpiredApp] Store URL: \(storeURL.path)")
        print("[ExpiredApp] iCloud sync enabled: \(iCloudSync)")
        print("[ExpiredApp] ────────────────────────────────────────────")

        // Try preferred store type first
        if iCloudSync {
            do {
                let config = ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .automatic
                )
                let c = try ModelContainer(for: schema, configurations: config)
                print("[ExpiredApp] CloudKit store opened successfully ✓")
                return c
            } catch {
                print("[ExpiredApp] CloudKit store FAILED: \(error)")
                print("[ExpiredApp] Falling back to local-only store")
            }
        }

        // Local-only store
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let c = try ModelContainer(for: schema, configurations: config)
            print("[ExpiredApp] Local store opened successfully")
            return c
        } catch {
            print("[ExpiredApp] Store failed (likely schema mismatch): \(error)")
            Self.deleteSQLiteFiles(at: storeURL)
        }

        // Re-try after clearing incompatible store
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let c = try ModelContainer(for: schema, configurations: config)
            print("[ExpiredApp] Fresh store opened after deleting old schema")
            return c
        } catch {
            print("[ExpiredApp] Fresh store also failed: \(error)")
        }

        print("[ExpiredApp] WARNING: falling back to in-memory store")
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

    /// Removes the SQLite store triple (.sqlite, .sqlite-shm, .sqlite-wal) at the given URL.
    static func deleteSQLiteFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            try? fm.removeItem(at: file)
            print("[ExpiredApp] Deleted: \(file.lastPathComponent)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .task {
                    await NotificationManager.shared.requestAuthorization()
                }
#if os(macOS)
                // On macOS, CloudKit processes remote changes on scene phase transitions.
                // We also respond to manual refresh requests from Settings.
                .onReceive(NotificationCenter.default.publisher(for: .expiredManualSync)) { _ in
                    print("[CloudKit] ── Manual sync triggered ────────────────────")
                    Task {
                        await Self.logCloudKitAccountStatus()
                        await Self.probeCloudKitRecords()
                    }
                }
#endif
        }
#if os(macOS)
        .defaultSize(width: 900, height: 680)
#endif
    }
}

extension Notification.Name {
    static let expiredManualSync = Notification.Name("com.swiftstudio.Expired.manualSync")
}

