import PhoneBackupCore
import SwiftUI

struct PhoneRestoreDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderPicker = false
    @State private var folderBrowser: RemoteBrowserModel?

    var body: some View {
        ReviewSheetLayout(title: "Restore to Android",
                          subtitle: "Choose where the selected files should go. Existing files are reviewed before replacement.",
                          minimumWidth: 540, minimumHeight: 360) {
            VStack(alignment: .leading, spacing: 12) {
                if let repository = model.selectedRepository {
                    Label("Backup device: \(repository.displayName)", systemImage: "cable.connector")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !hasRepositoryDevice {
                    MessageBanner(text: "Connect and authorize the Android device associated with this restore point to continue.", symbol: "cable.connector.slash", isWarning: true)
                }
                Button { planPhoneRestore(to: nil) } label: {
                    destinationRow("Original paths", detail: "Write files back to the Android paths stored in this restore point.", symbol: "arrow.uturn.backward")
                }.buttonStyle(.plain).disabled(!hasRepositoryDevice)
                Button { openFolderPicker() } label: {
                    destinationRow("Choose a phone folder…", detail: "Place the selected files beneath another shared-storage folder.", symbol: "folder")
                }.buttonStyle(.plain).disabled(!hasRepositoryDevice)
            }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .sheet(isPresented: $showingFolderPicker) {
            if let folderBrowser {
                PhoneFolderPicker(browser: folderBrowser) { path in
                    await model.planPhoneRestore(to: path)
                    let succeeded = model.isShowingExportReview
                    if succeeded { dismiss() }
                    return succeeded
                }
            }
        }
    }

    private var hasRepositoryDevice: Bool {
        guard let repository = model.selectedRepository else { return false }
        return model.devices.contains { $0.id == repository.deviceID && $0.state == .device }
    }

    private func planPhoneRestore(to folder: RemotePath?) {
        Task {
            await model.planPhoneRestore(to: folder)
            if model.isShowingExportReview { dismiss() }
        }
    }

    private func openFolderPicker() {
        guard let repository = model.selectedRepository,
              let browser = model.makeRemoteBrowser(for: repository.deviceID) else { return }
        folderBrowser = browser
        showingFolderPicker = true
    }

    private func destinationRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle()).padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PhoneFolderPicker: View {
    @Environment(\.dismiss) private var dismiss
    let browser: RemoteBrowserModel
    let choose: (RemotePath) async -> Bool

    var body: some View {
        @Bindable var browser = browser
        ReviewSheetLayout(title: "Choose Phone Folder", subtitle: "Open folders to see their immediate children.",
                          minimumWidth: 520, minimumHeight: 440) {
            VStack(spacing: 0) {
                HStack {
                    Button { Task { await browser.goUp() } } label: { Label("Up", systemImage: "chevron.left") }
                        .disabled(browser.currentDirectory.parent == nil || browser.isLoading)
                    Text(browser.currentDirectory.description).font(.headline).lineLimit(1).textSelection(.enabled)
                    Spacer()
                    Button("Refresh") { Task { await browser.refresh() } }
                        .disabled(browser.isLoading)
                }.padding(.bottom, 12)
                Divider()
                if browser.isLoading {
                    ProgressView("Opening folder…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = browser.errorMessage {
                    ContentUnavailableView("Folder unavailable", systemImage: "folder.badge.questionmark", description: Text(error))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(browser.entries.filter { $0.kind == .directory }) { entry in
                            Button { Task { await browser.open(entry) } } label: {
                                Label(entry.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }.listStyle(.inset)
                }
            }
            .frame(height: 330)
            .task { if !browser.hasOpenedRoot { await browser.navigate(to: try! RemotePath("/sdcard")) } }
        } footer: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Use This Folder") {
                Task {
                    if await choose(browser.currentDirectory) { dismiss() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(browser.isLoading || browser.errorMessage != nil)
            .keyboardShortcut(.defaultAction)
        }
    }
}
