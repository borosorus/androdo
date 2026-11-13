import PhoneBackupCore
import SwiftUI

struct RestoreLibraryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.requiresRepositoryRecoveryConfirmation {
                ContentUnavailableView {
                    Label("Backup location needs attention", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(model.errorMessage ?? "The previous repository was not found. Locate it or choose a new backup location.")
                } actions: {
                    Button("Choose Existing Folder…") { chooseLocation() }
                    Button("Use as New Backup Location", role: .destructive) { model.authorizeNewRepositoryAtSelectedLocation() }
                        .disabled(model.isBusy)
                }
            } else if model.repositories.isEmpty {
                ContentUnavailableView {
                    Label("Your backup library", systemImage: "externaldrive.fill")
                } description: {
                    Text("Open a backup folder to browse its restore points.")
                } actions: {
                    Button("Open Backup Folder…") { chooseLocation() }.disabled(model.isBusy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        Picker("Device", selection: Binding(get: { model.selectedRepositoryID }, set: { id in
                            if let id { Task { await model.selectRepository(id) } }
                        })) {
                            ForEach(model.repositories) { repository in
                                Text(repository.displayName).tag(Optional(repository.id))
                            }
                        }
                        .labelsHidden().disabled(model.isBusy)
                        .padding(14)
                        Divider()
                        pointColumn
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 290)
                    RestorePointBrowser().frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Backups")
        .toolbar {
            ToolbarItem {
                Button { chooseLocation() } label: { Label("Open Backup Folder…", systemImage: "folder.badge.gearshape") }
                    .disabled(model.isBusy)
            }
        }
    }

    private func chooseLocation() {
        if let folder = NativeFilePanels.chooseFolder(prompt: "Open Backup Folder") {
            Task { await model.chooseBackupLocation(folder) }
        }
    }

    private var pointColumn: some View {
        List(selection: Binding(get: { model.selectedRestorePoint?.id }, set: { id in
            if let point = model.restorePoints.first(where: { $0.id == id }) { Task { await model.selectRestorePoint(point) } }
        })) {
            Section("Restore points") {
                ForEach(model.restorePoints) { point in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(AppIdentity.copper).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(point.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.callout.weight(.semibold))
                            Text(point.createdAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text("\(point.entryCount) items · \(UIFormatting.bytes(point.totalBytes))")
                                .font(.caption).foregroundStyle(.secondary)
                            if point.state == .incomplete || !point.omissions.isEmpty {
                                Label("Incomplete · \(point.omissions.count) skipped", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                Label("Complete", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 6).tag(point.id)
                }
            }
        }.listStyle(.inset)
        .overlay {
            if model.restorePoints.isEmpty {
                ContentUnavailableView("No restore points", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}
