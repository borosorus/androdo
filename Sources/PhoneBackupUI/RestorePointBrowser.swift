import PhoneBackupCore
import SwiftUI

struct RestorePointBrowser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let point = model.selectedRestorePoint {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Restore point contents").font(.title3.weight(.semibold))
                        Text("\(point.createdAt.formatted(date: .long, time: .shortened)) · \(model.restoreEntries.count) stored entries")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button("Export Selected…") { chooseExportFolder() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedRestoreRoots.isEmpty || model.isBusy)
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
                    MessageBanner(text: "This restore point has \(point.omissions.count) recorded omission(s). Some selected device paths were not saved.", symbol: "exclamationmark.triangle", isWarning: true).padding(12)
                }
            } else {
                ContentUnavailableView("Select a restore point", systemImage: "clock.arrow.circlepath", description: Text("Restore points are immutable snapshots. Browse them without connecting the phone."))
            }
        }
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

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.selectedRestoreRoots.contains(entry.path) }, set: { _ in model.toggleRestoreRoot(entry.path) })) {
                Label(entry.path.name ?? entry.path.description, systemImage: entry.kind == .directory ? "folder" : "doc")
                    .lineLimit(1)
            }.toggleStyle(.checkbox).disabled(model.isBusy)
            Spacer()
            if entry.kind == .file { Text(UIFormatting.bytes(entry.size)).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.leading, CGFloat(depth * 18))
        .padding(.vertical, 2)
        ForEach(children) { child in RestoreEntryRow(entry: child, allEntries: allEntries, depth: depth + 1) }
    }

    private var children: [BackupEntry] {
        allEntries.filter { $0.path.parent == entry.path }
            .sorted { $0.path.description.localizedStandardCompare($1.path.description) == .orderedAscending }
    }
}
