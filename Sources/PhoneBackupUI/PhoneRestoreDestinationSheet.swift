import PhoneBackupCore
import SwiftUI

public struct PhoneRestoreDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderPicker = false
    @State private var folderBrowser: RemoteBrowserModel?
    @State private var useOriginalPaths = true
    @State private var selectedFolder: RemotePath?
    @State private var policy: PhoneRestoreConflictPolicy?
    @State private var showingReview = false
    @State private var reviewedPlanID: RestorePlanID?

    public init(reviewPlanID: RestorePlanID? = nil) {
        _reviewedPlanID = State(initialValue: reviewPlanID)
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showingReview {
                LocalExportReviewSheet(backToSetup: {
                    showingReview = false
                    reviewedPlanID = nil
                    model.isShowingPhoneRestoreSetup = true
                    model.cancelExportReview()
                })
            } else {
                setup
            }
        }
        .interactiveDismissDisabled(model.isStartingOperation || model.isPlanningExport)
        .onChange(of: model.isShowingExportReview, initial: true) { _, visible in
            if visible, let plan = model.restorePlan {
                policy = plan.request.phoneConflictPolicy
                if case .phoneFolder(let folder, _) = plan.request.target {
                    useOriginalPaths = false
                    selectedFolder = folder
                }
                showingReview = true
            }
            else if showingReview { dismiss() }
        }
        .onDisappear {
            if let reviewedPlanID, model.restorePlan?.id == reviewedPlanID { model.cancelExportReview() }
        }
    }

    private var setup: some View {
        ReviewSheetLayout(title: "Restore to Android",
                          subtitle: "Choose where to restore and how to handle existing files.",
                          minimumWidth: 580, minimumHeight: 440) {
            VStack(alignment: .leading, spacing: 20) {
                if let repository = model.selectedRepository {
                    Label(repository.displayName, systemImage: "cable.connector")
                        .font(.headline)
                }
                if !hasRepositoryDevice {
                    MessageBanner(text: "Connect and authorize the Android device associated with this restore point to continue.", symbol: "cable.connector.slash", isWarning: true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Destination").font(.headline)
                    Picker("Destination", selection: $useOriginalPaths) {
                        Text("Original paths").tag(true)
                        Text("Another folder").tag(false)
                    }.pickerStyle(.segmented).labelsHidden()
                    if useOriginalPaths {
                        Text("Restore to the Android paths saved in this backup.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Label(selectedFolder?.description ?? "Choose a phone folder", systemImage: "folder")
                                .lineLimit(2).textSelection(.enabled)
                            Spacer()
                            Button("Choose…") { openFolderPicker() }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Existing files").font(.headline)
                    Picker("Existing files", selection: $policy) {
                        Text("Choose how to handle existing files…").tag(Optional<PhoneRestoreConflictPolicy>.none)
                        Text("Stop if a file exists").tag(Optional(PhoneRestoreConflictPolicy.stopIfFileExists))
                        Text("Replace files in this restore").tag(Optional(PhoneRestoreConflictPolicy.replaceFiles))
                    }.labelsHidden()
                    Text(policyExplanation).font(.callout).foregroundStyle(.secondary)
                }
                .disabled(!hasRepositoryDevice || model.isPlanningExport)
                if let error = model.errorMessage {
                    MessageBanner(text: error, symbol: "exclamationmark.triangle", isWarning: true)
                }
            }
            .disabled(model.isPlanningExport)
        } footer: {
            Button("Cancel") {
                model.isShowingPhoneRestoreSetup = false
                model.cancelRestorePlanning()
                dismiss()
            }.keyboardShortcut(.cancelAction)
            Button("Review Restore") {
                guard let policy else { return }
                Task { await model.planPhoneRestore(to: useOriginalPaths ? nil : selectedFolder, policy: policy) }
            }
            .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
            .disabled(!hasRepositoryDevice || model.isBusy || policy == nil || (!useOriginalPaths && selectedFolder == nil))
            .keyboardShortcut(.defaultAction)
        }
        .sheet(isPresented: $showingFolderPicker) {
            if let folderBrowser {
                PhoneFolderPicker(browser: folderBrowser) { path in
                    selectedFolder = path
                    return true
                }
            }
        }
    }

    private var policyExplanation: String {
        switch policy {
        case .none: "Choose how to handle existing files. Nothing is written until you review and confirm the restore."
        case .stopIfFileExists: "Existing files block the restore. Some Android storage requires replacement permission even for new files."
        case .replaceFiles: "Replace matching files with the saved versions. Also allows creating files on Android storage that requires replacement permission. Folders and unsafe paths are never replaced."
        }
    }

    private var hasRepositoryDevice: Bool {
        guard let repository = model.selectedRepository else { return false }
        return model.devices.contains { $0.id == repository.deviceID && $0.state == .device }
    }

    private func openFolderPicker() {
        guard let repository = model.selectedRepository,
              let browser = model.makeRemoteBrowser(for: repository.deviceID) else { return }
        folderBrowser = browser
        showingFolderPicker = true
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
            .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
            .disabled(browser.isLoading || browser.errorMessage != nil || !browser.hasOpenedRoot)
            .keyboardShortcut(.defaultAction)
        }
    }
}
