import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Backup wire format
//
// A plain, human-readable JSON snapshot of every SubscriptionItem (subscriptions,
// documents, and archived rows) plus their notification rules. Icon image data is
// intentionally excluded — it is re-fetchable via "Refresh Icons" and would bloat
// the file. The format is a portable, off-CloudKit safety copy for disaster recovery.

struct BackupFile: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()
    var items: [BackupItem]
}

struct BackupNotification: Codable {
    var offsetType: String
    var value: Int
    var isCritical: Bool
    var customDate: Date?
}

struct BackupItem: Codable {
    var id: UUID
    var itemType: String?
    var name: String
    var provider: String
    var iconSource: String
    var cost: Double?
    var currency: String
    var billingCycle: String
    var nextRenewalDate: Date
    var trialEndDate: Date?
    var expiryDate: Date?
    var isAutoRenew: Bool
    var isCancelled: Bool
    var activeUntilDate: Date?
    var personName: String
    var paymentMethod: String
    var emailUsed: String
    var phoneNumber: String
    var notes: String
    var url: String
    var documentNumber: String?
    var validFromDate: Date?
    var category: String?
    var startDate: Date?
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date
    var notifications: [BackupNotification]

    @MainActor
    init(item: SubscriptionItem) {
        id = item.id
        itemType = item.itemTypeRaw
        name = item.name
        provider = item.provider
        iconSource = item.iconSourceRaw
        cost = item.cost
        currency = item.currency
        billingCycle = item.billingCycleRaw
        nextRenewalDate = item.nextRenewalDate
        trialEndDate = item.trialEndDate
        expiryDate = item.expiryDate
        isAutoRenew = item.isAutoRenew
        isCancelled = item.isCancelled
        activeUntilDate = item.activeUntilDate
        personName = item.personName
        paymentMethod = item.paymentMethod
        emailUsed = item.emailUsed
        phoneNumber = item.phoneNumber
        notes = item.notes
        url = item.url
        documentNumber = item.documentNumber
        validFromDate = item.validFromDate
        category = item.categoryRaw
        startDate = item.startDate
        isArchived = item.isArchived
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        notifications = item.notificationsList.map {
            BackupNotification(
                offsetType: $0.offsetTypeRaw,
                value: $0.value,
                isCritical: $0.isCritical,
                customDate: $0.customDate
            )
        }
    }

    private func notificationRules() -> [NotificationRule] {
        notifications.map {
            NotificationRule(
                offsetType: NotificationOffsetType(rawValue: $0.offsetType) ?? .daysBefore,
                value: $0.value,
                isCritical: $0.isCritical,
                customDate: $0.customDate
            )
        }
    }

    /// Builds a brand-new SubscriptionItem from this backup row.
    @MainActor
    func makeItem() -> SubscriptionItem {
        let item = SubscriptionItem(
            id: id,
            itemType: ItemType(rawValue: itemType ?? "") ?? .subscription,
            name: name,
            provider: provider,
            iconSource: IconSource(rawValue: iconSource) ?? .system,
            cost: cost,
            currency: currency,
            billingCycle: BillingCycle(rawValue: billingCycle) ?? .monthly,
            nextRenewalDate: nextRenewalDate,
            trialEndDate: trialEndDate,
            expiryDate: expiryDate,
            isAutoRenew: isAutoRenew,
            isCancelled: isCancelled,
            activeUntilDate: activeUntilDate,
            personName: personName,
            paymentMethod: paymentMethod,
            emailUsed: emailUsed,
            phoneNumber: phoneNumber,
            notes: notes,
            url: url,
            documentNumber: documentNumber,
            validFromDate: validFromDate,
            startDate: startDate,
            notifications: notificationRules()
        )
        item.categoryRaw = category
        item.isArchived = isArchived
        item.updatedAt = updatedAt
        return item
    }

    /// Updates an existing row's scalar fields from this backup. Notification rules are
    /// left untouched on update to avoid orphaning/duplicating cascaded child rows; a
    /// fresh restore (into an empty store) takes the `makeItem()` path and keeps them.
    @MainActor
    func apply(to item: SubscriptionItem) {
        item.itemTypeRaw = itemType
        item.name = name
        item.provider = provider
        item.iconSourceRaw = iconSource
        item.cost = cost
        item.currency = currency
        item.billingCycleRaw = billingCycle
        item.nextRenewalDate = nextRenewalDate
        item.trialEndDate = trialEndDate
        item.expiryDate = expiryDate
        item.isAutoRenew = isAutoRenew
        item.isCancelled = isCancelled
        item.activeUntilDate = activeUntilDate
        item.personName = personName
        item.paymentMethod = paymentMethod
        item.emailUsed = emailUsed
        item.phoneNumber = phoneNumber
        item.notes = notes
        item.url = url
        item.documentNumber = documentNumber
        item.validFromDate = validFromDate
        item.categoryRaw = category
        item.startDate = startDate
        item.isArchived = isArchived
        item.updatedAt = updatedAt
    }
}

// MARK: - Service

enum BackupService {
    @MainActor
    static func export(_ items: [SubscriptionItem]) throws -> Data {
        let file = BackupFile(items: items.map(BackupItem.init(item:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupFile.self, from: data)
    }

    /// Merges a backup into the store by `id`: existing rows are updated, new rows are
    /// inserted. Nothing is ever deleted, so a partial/older backup can't lose data.
    @MainActor
    @discardableResult
    static func merge(
        _ file: BackupFile,
        into context: ModelContext,
        existing: [SubscriptionItem]
    ) -> (added: Int, updated: Int) {
        var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        var updated = 0
        for backupItem in file.items {
            if let existingItem = byID[backupItem.id] {
                backupItem.apply(to: existingItem)
                updated += 1
            } else {
                let newItem = backupItem.makeItem()
                context.insert(newItem)
                byID[backupItem.id] = newItem
                added += 1
            }
        }
        try? context.save()
        return (added, updated)
    }
}

// MARK: - Automatic backup

extension BackupService {
    static let autoBackupEnabledKey = "autoBackupEnabled"
    static let lastAutoBackupKey    = "lastAutoBackupAt"

    private static let dateStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var autoBackupEnabled: Bool {
        UserDefaults.standard.object(forKey: autoBackupEnabledKey) as? Bool ?? true
    }

    /// Runs a once-per-day backup snapshot to iCloud Drive (or local fallback) without user
    /// action. Skips the write if no items have changed since the last backup.
    /// Fetch + encode happen on the main actor; the iCloud-container lookup and file
    /// write are moved off-main (the ubiquity URL resolution can block on first access).
    @MainActor
    static func runAutomaticBackupIfNeeded(context: ModelContext, force: Bool = false) {
        guard force || autoBackupEnabled else { return }

        if !force {
            let last = UserDefaults.standard.double(forKey: lastAutoBackupKey)
            if last > 0, Calendar.current.isDateInToday(Date(timeIntervalSince1970: last)) {
                return
            }
        }

        guard let items = try? context.fetch(FetchDescriptor<SubscriptionItem>()), !items.isEmpty,
              let data = try? export(items) else { return }

        // Skip write if no items have changed since the last backup
        if !force {
            let lastBackupAt = UserDefaults.standard.double(forKey: lastAutoBackupKey)
            if lastBackupAt > 0 {
                let latestChange = items.map(\.updatedAt).max() ?? .distantPast
                if latestChange.timeIntervalSince1970 <= lastBackupAt { return }
            }
        }

        let stamp = dateStamp.string(from: Date())
        Task.detached(priority: .utility) {
            writeAutomaticBackup(data: data, stamp: stamp)
        }
    }

    /// iCloud Drive (ubiquity) Documents folder if available, else local Application Support.
    private static func backupsDirectory() -> URL? {
        let fm = FileManager.default
        if let container = fm.url(forUbiquityContainerIdentifier: nil) {
            let dir = container.appending(path: "Documents", directoryHint: .isDirectory)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let local = URL.applicationSupportDirectory
            .appending(path: "Expired/AutoBackups", directoryHint: .isDirectory)
        try? fm.createDirectory(at: local, withIntermediateDirectories: true)
        return local
    }

    private static func writeAutomaticBackup(data: Data, stamp: String) {
        guard let dir = backupsDirectory() else { return }
        let url = dir.appending(path: "Expired-Backup-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAutoBackupKey)
            pruneAutomaticBackups(in: dir, keeping: 5)
        } catch {
            // Best-effort: a failed auto-backup leaves lastAutoBackupKey unchanged so it retries.
        }
    }

    /// Keeps the most recent `keeping` dated snapshots; deletes older ones so the folder
    /// doesn't grow unbounded while still giving a few recovery points against corruption.
    private static func pruneAutomaticBackups(in dir: URL, keeping: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("Expired-Backup-") && $0.pathExtension == "json" }
            .sorted { modDate($0) > modDate($1) }
        for old in backups.dropFirst(keeping) { try? fm.removeItem(at: old) }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

// MARK: - File document

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
