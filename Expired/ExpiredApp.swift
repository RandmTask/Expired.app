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
            print("[ExpiredApp] Local store failed: \(error)")
        }

        // Absolute last resort: fresh in-memory container
        // (data won't persist — but the app won't crash)
        print("[ExpiredApp] WARNING: falling back to in-memory store")
        return try! ModelContainer(for: schema,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
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
