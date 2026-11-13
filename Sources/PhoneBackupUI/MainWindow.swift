import AppKit
import PhoneBackupCore
import SwiftUI

public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showingADBPanel = false
    @State private var showingOmissionConfirmation = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding<AppSection?>(get: { model.section }, set: { section in if let section { model.section = section } })) {
                Section("DEVICES") {
                    if model.devices.isEmpty {
                        Label(model.hasADB ? "No device connected" : "ADB not found", systemImage: "cable.connector.slash")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { device in
                        Button {
                            model.selectDevice(device)
                            model.section = .device
                        } label: {
                            DeviceSidebarRow(device: device, isSelected: model.selectedDevice?.id == device.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select \(device.model ?? "Android device") \(device.id.serial)")
                    }
                }

                Section("PHONE") {
                    Label("Overview", systemImage: "iphone.gen3").tag(AppSection.device)
                    Label("Files", systemImage: "folder").tag(AppSection.files)
                        .foregroundStyle(model.selectedDevice?.state == .device ? Color.primary : Color.secondary)
                }

                Section("LIBRARY") {
                    Label("Backups", systemImage: "externaldrive").tag(AppSection.backups)
                    Label("Activity", systemImage: "clock.arrow.circlepath").tag(AppSection.activity)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(PhoneBackupCore.applicationName)
            .safeAreaInset(edge: .bottom) {
                if model.backupLocation != nil {
                    Label("On this Mac", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        } detail: {
            Group {
                switch model.section {
                case .device: DeviceOverview()
                case .files: PhoneFilesView()
                case .backups: RestoreLibraryView()
                case .activity: ActivityView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsOperationStatus {
                    ScrollView {
                        OperationStatusView(showingOmissionConfirmation: $showingOmissionConfirmation)
                            .padding(16)
                    }
                    .frame(maxHeight: 280)
                    .background(.bar)
                }
            }
            .confirmationDialog("Finish this backup with skipped paths?", isPresented: $showingOmissionConfirmation, titleVisibility: .visible) {
                Button("Finish with omissions", role: .destructive) { Task { await model.finishBackupWithOmissions() } }
                Button("Keep incomplete", role: .cancel) {}
            } message: {
                Text("The restore point will be marked incomplete and will list the paths that could not be saved.")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(model.hasADB ? "Change ADB…" : "Locate ADB…") { showingADBPanel = true }
                    .disabled(model.isBusy)
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy || !model.hasADB)
            }
        }
        .sheet(isPresented: $model.isShowingBackupReview) {
            BackupReviewSheet()
        }
        .sheet(isPresented: $model.isShowingExportReview) {
            LocalExportReviewSheet()
        }
        .sheet(isPresented: $model.isShowingCopyReview) { CopyReviewSheet() }
        .alert("PhoneBackup", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearStatus() } }
        )) {
            Button("OK", role: .cancel) { model.clearStatus() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .fileImporter(isPresented: $showingADBPanel, allowedContentTypes: [.unixExecutable], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.locateADB(at: url) }
            case .failure(let error): model.reportError(error.localizedDescription)
            }
        }
    }

    private var showsOperationStatus: Bool {
        model.isOperationRunning || model.recoveryAttempt != nil || model.operationEvent != nil || !model.pendingAttempts.isEmpty
    }
}
private struct DeviceSidebarRow: View {
    let device: AndroidDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.state == .device ? "cable.connector" : "exclamationmark.circle")
                .foregroundStyle(device.state == .device ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.model ?? "Android device")
                    .lineLimit(1)
                Text(device.state == .device ? "Connected" : String(describing: device.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isSelected { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

public enum NativeFilePanels {
    @MainActor
    public static func chooseFolder(prompt: String, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    public static func chooseFilesAndFolders(prompt: String, message: String? = nil) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

public enum UIFormatting {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func destination(_ value: RestoreDestination) -> String {
        switch value {
        case .local(let url): url.path
        case .phone(let path): path.description
        }
    }
}
