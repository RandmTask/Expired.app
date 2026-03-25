import SwiftUI
import SwiftData

@main
struct ExpiredApp: App {
    let container: ModelContainer

    init() {
        do {
            let schema = Schema([SubscriptionItem.self, NotificationRule.self])
            // Use CloudKit container for iCloud sync
            let config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .automatic
            )
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Fall back to local-only if CloudKit unavailable
            do {
                let schema = Schema([SubscriptionItem.self, NotificationRule.self])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
        }
#if os(macOS)
        .defaultSize(width: 900, height: 680)
#endif
    }
}
