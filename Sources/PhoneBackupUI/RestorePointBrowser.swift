import PhoneBackupCore
import SwiftUI

struct RestorePointBrowser: View {
    @Environment(AppModel.self) private var model
    @State private var showingPhoneRestore = false

    var body: some View {
        VStack(spacing: 0) {
            if let point = model.selectedRestorePoint {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "archivebox.fill").font(.title2).foregroundStyle(AppIdentity.copper)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(point.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(point.entryCount) items · \(UIFormatting.bytes(point.totalBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Button("Restore to Phone…") { showingPhoneRestore = true }
                            .disabled(model.selectedRestoreRoots.isEmpty || model.isBusy)
                        Button("Export…") { chooseExportFolder() }
                            .disabled(model.selectedRestoreRoots.isEmpty || model.isBusy)
                        Spacer(minLength: 0)
                    }.controlSize(.small)
                }.padding(18)
                Divider()
                if model.restoreEntries.isEmpty {
                    ContentUnavailableView("This restore point has no stored entries", systemImage: "doc.questionmark")
                } else {
                    List {
                        ForEach(rootEntries) { entry in RestoreEntryRow(entry: entry, allEntries: model.restoreEntries, depth: 0) }
                    }.listStyle(.inset)
                }
                if point.state == .incomplete || !point.omissions.isEmpty {
                    MessageBanner(text: "\(point.omissions.count) paths were skipped in this restore point.", symbol: "exclamationmark.triangle", isWarning: true).padding(12)
                }
            } else {
                ContentUnavailableView("Select a restore point", systemImage: "clock.arrow.circlepath", description: Text("Choose a dated backup to browse or restore its files."))
            }
        }
        .sheet(isPresented: $showingPhoneRestore) { PhoneRestoreDestinationSheet() }
    }

    private var rootEntries: [BackupEntry] {
        let paths = Set(model.restoreEntries.map(\.path))
        return model.restoreEntries.filter { entry in
            guard let parent = entry.path.parent else { return true }
            return !paths.contains(parent)
        }.sorted { $0.path.description.localizedStandardCompare($1.path.description) == .orderedAscending }
    }

    private func chooseExportFolder() {
        guard let folder = NativeFilePanels.chooseFolder(prompt: "Export Restore Point", message: "Selected files will be written beneath this folder.") else { return }
        Task { await model.planLocalExport(to: folder) }
    }
}

private struct RestoreEntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: BackupEntry
    let allEntries: [BackupEntry]
    let depth: Int
    @State private var isExpanded = false

    var body: some View {
        Group {
            if entry.kind == .directory && !children.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children) { child in RestoreEntryRow(entry: child, allEntries: allEntries, depth: depth + 1) }
                } label: {
                    rowContent
                }
            } else {
                rowContent
            }
        }
        .padding(.leading, CGFloat(depth * 12))
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.selectedRestoreRoots.contains(entry.path) }, set: { _ in model.toggleRestoreRoot(entry.path) })) {
                Label(entry.path.name ?? entry.path.description, systemImage: entry.kind == .directory ? "folder.fill" : "doc")
                    .lineLimit(1)
            }.toggleStyle(.checkbox).disabled(model.isBusy)
            Spacer()
            if entry.kind == .file { Text(UIFormatting.bytes(entry.size)).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
    }

    private var children: [BackupEntry] {
        allEntries.filter { $0.path.parent == entry.path }
            .sorted { $0.path.description.localizedStandardCompare($1.path.description) == .orderedAscending }
    }
}
