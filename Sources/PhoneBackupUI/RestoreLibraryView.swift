import PhoneBackupCore
import SwiftUI

struct RestoreLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var showingOmissionConfirmation = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Backups").font(.largeTitle.weight(.semibold))
                    Text("Browse restore points and export files to this Mac, even when the phone is disconnected.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.backupLocation == nil ? "Choose Backup Folder…" : "Change Folder…") {
                    if let folder = NativeFilePanels.chooseFolder(prompt: "Open Backup Folder", message: "Select the folder containing PhoneBackup device repositories.") {
                        Task { await model.chooseBackupLocation(folder) }
                    }
                }.disabled(model.isBusy)
            }.padding(24)
            Divider()
            if model.requiresRepositoryRecoveryConfirmation {
                ContentUnavailableView {
                    Label("Backup location needs attention", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(model.errorMessage ?? "The previously used repository was not found. Choose the original backup folder or explicitly authorize this location as a new repository.")
                } actions: {
                    Button("Choose Existing Folder…") {
                        if let folder = NativeFilePanels.chooseFolder(prompt: "Locate Existing Backup Folder") { Task { await model.chooseBackupLocation(folder) } }
                    }
                    Button("Use as New Backup Location", role: .destructive) { model.authorizeNewRepositoryAtSelectedLocation() }
                }
            } else if model.repositories.isEmpty {
                ContentUnavailableView("No backup repository", systemImage: "externaldrive", description: Text("Choose a folder to open or create a backup repository. A connected phone is not needed to browse existing backups."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    repositoryColumn.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                    Divider()
                    pointColumn.frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    Divider()
                    RestorePointBrowser().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if model.isOperationRunning || model.recoveryAttempt != nil || model.operationEvent != nil || !model.pendingAttempts.isEmpty {
                Divider()
                OperationStatusView(showingOmissionConfirmation: $showingOmissionConfirmation)
                    .padding(16)
            }
        }
        .confirmationDialog("Finish this backup with skipped paths?", isPresented: $showingOmissionConfirmation, titleVisibility: .visible) {
            Button("Finish with omissions", role: .destructive) { Task { await model.finishBackupWithOmissions() } }
            Button("Keep incomplete", role: .cancel) {}
        } message: { Text("The restore point will be marked incomplete and will list the paths that could not be saved.") }
    }

    private var repositoryColumn: some View {
        List(selection: Binding(get: { model.selectedRepositoryID }, set: { id in if let id { Task { await model.selectRepository(id) } } })) {
            Section("Devices") {
                ForEach(model.repositories) { repository in
                    Label(repository.displayName, systemImage: "externaldrive").tag(repository.id)
                        .help(repository.location.path)
                }
            }
        }.listStyle(.sidebar)
    }

    private var pointColumn: some View {
        List(selection: Binding(get: { model.selectedRestorePoint?.id }, set: { id in
            if let point = model.restorePoints.first(where: { $0.id == id }) { Task { await model.selectRestorePoint(point) } }
        })) {
            Section("Restore points") {
                ForEach(model.restorePoints) { point in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(point.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                            if point.state == .incomplete || !point.omissions.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        }
                        Text("\(point.entryCount) items · \(UIFormatting.bytes(point.totalBytes))\(point.omissions.isEmpty ? "" : " · \(point.omissions.count) omissions")")
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(point.id)
                }
            }
        }.listStyle(.inset)
    }
}
