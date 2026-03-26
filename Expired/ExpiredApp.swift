import SwiftUI
import SwiftData

@main
struct ExpiredApp: App {
    let container: ModelContainer

    init() {
        container = Self.makeContainer()
    }

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([SubscriptionItem.self, NotificationRule.self])

        // Pin the store to a fixed URL so it survives schema changes and
        // never accidentally opens a different file on fallback.
        let storeURL = URL.applicationSupportDirectory
            .appending(path: "Expired", directoryHint: .isDirectory)
            .appending(path: "default.store")

        // Ensure the directory exists
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        print("[ExpiredApp] Store URL: \(storeURL.path)")

        // Try CloudKit-backed store at the fixed URL
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

        // Fall back to local-only at the SAME fixed URL
        do {
            let config = ModelConfiguration(
                schema: schema,
                url: storeURL
            )
            let c = try ModelContainer(for: schema, configurations: config)
            print("[ExpiredApp] Local store opened successfully")
            return c
        } catch {
            print("[ExpiredApp] Store failed (likely schema mismatch): \(error)")
            // Delete the incompatible store files so the app can start fresh.
            // This happens when new non-optional fields are added without a migration plan.
            deleteSQLiteFiles(at: storeURL)
        }

        // Re-try with a clean store
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let c = try ModelContainer(for: schema, configurations: config)
            print("[ExpiredApp] Fresh store opened after deleting old schema")
            return c
        } catch {
            print("[ExpiredApp] Fresh store also failed: \(error)")
        }

        // Absolute last resort: fresh in-memory container
        // (data won't persist — but the app won't crash)
        print("[ExpiredApp] WARNING: falling back to in-memory store")
        return try! ModelContainer(for: schema,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Removes the SQLite store triple (.sqlite, .sqlite-shm, .sqlite-wal) at the given URL.
    private static func deleteSQLiteFiles(at url: URL) {
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
