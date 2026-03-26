import SwiftUI
import SwiftData

@main
struct ExpiredApp: App {
    // Persisted user preference for iCloud sync (default: on)
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled = true

    let container: ModelContainer

    init() {
        // Read the preference before the App property wrappers are initialised
        let syncOn = UserDefaults.standard.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        container = Self.makeContainer(iCloudSync: syncOn)
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

        print("[ExpiredApp] Store URL: \(storeURL.path) iCloud=\(iCloudSync)")
        print("[ExpiredApp] Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("[ExpiredApp] CloudKit container: iCloud.\(Bundle.main.bundleIdentifier ?? "unknown")")

        // Try preferred store type first
        if iCloudSync {
            do {
                let config = ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .automatic
                )
                let c = try ModelContainer(for: schema, configurations: config)
                print("[ExpiredApp] CloudKit store opened successfully")
                return c
            } catch {
                print("[ExpiredApp] CloudKit store failed: \(error)")
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
        }
#if os(macOS)
        .defaultSize(width: 900, height: 680)
#endif
    }
}
