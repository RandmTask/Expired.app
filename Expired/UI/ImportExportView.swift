import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Single entry point for backup import and export, opened from one "Import / Export"
/// row in Settings' Data & Backup section (per Lumina Library precedent, 2026-08-19 —
/// Deon: "make import/export just one button"). Both directions and the unencrypted-
/// data warning live here instead of two separate Settings rows.
struct ImportExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [SubscriptionItem]

    @State private var showExportWarning = false
    @State private var showingExporter = false
    @State private var exportDocument: BackupDocument?
    @State private var showingImporter = false
    @State private var importResultMessage: String?
    @State private var backupErrorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Haptics.fire(.light)
                        showExportWarning = true
                    } label: {
                        HStack {
                            rowIcon("square.and.arrow.up", color: .blue)
                            Text("Export Backup").foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Export")
                } footer: {
                    Text("Writes an unencrypted JSON file with every subscription and document (icons excluded). Includes account emails, usernames, and passwords; keep it private.")
                }

                Section {
                    Button {
                        Haptics.fire(.light)
                        showingImporter = true
                    } label: {
                        HStack {
                            rowIcon("square.and.arrow.down", color: .blue)
                            Text("Import Backup").foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Import")
                } footer: {
                    Text("Merges an Expired JSON backup by item — new items are added, matching items are updated. Nothing is ever deleted by an import.")
                }
            }
            .navigationTitle("Import / Export")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.fire(.light)
                        dismiss()
                    }
                }
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "Expired Backup"
            ) { result in
                exportDocument = nil
                switch result {
                case .success: Haptics.fire(.success)
                case .failure(let error):
                    Haptics.fire(.error)
                    backupErrorMessage = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { handleImport($0) }
            .alert("Export Backup", isPresented: $showExportWarning) {
                Button("Continue") { prepareExport() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This backup is not encrypted and includes account emails, usernames, and passwords. Only save it somewhere private.")
            }
            .alert("Import Complete", isPresented: Binding(
                get: { importResultMessage != nil },
                set: { if !$0 { importResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importResultMessage ?? "")
            }
            .alert("Backup Error", isPresented: Binding(
                get: { backupErrorMessage != nil },
                set: { if !$0 { backupErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backupErrorMessage ?? "")
            }
        }
    }

    /// Fixed-width icon slot — mirrors Settings' own `rowIcon` so this sheet stays
    /// visually identical to the row it was opened from.
    @ViewBuilder
    private func rowIcon(_ name: String, color: Color = .secondary) -> some View {
        Image(systemName: name)
            .font(.system(size: 16))
            .frame(width: 22, alignment: .center)
            .foregroundStyle(color)
    }

    private func prepareExport() {
        do {
            let data = try BackupService.export(allItems)
            exportDocument = BackupDocument(data: data)
            showingExporter = true
        } catch {
            Haptics.fire(.error)
            backupErrorMessage = "Could not create backup: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let url = try? result.get().first else { return }
        guard url.startAccessingSecurityScopedResource() else {
            Haptics.fire(.warning)
            backupErrorMessage = "Could not access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            let file = try BackupService.decode(data)
            let counts = BackupService.merge(file, into: modelContext, existing: allItems)
            importResultMessage = "Imported \(counts.added) new, updated \(counts.updated)."
            Haptics.fire(.success)
            Task { await NotificationManager.shared.refreshAll(context: modelContext) }
        } catch {
            Haptics.fire(.error)
            backupErrorMessage = "Could not read backup: \(error.localizedDescription)"
        }
    }
}
