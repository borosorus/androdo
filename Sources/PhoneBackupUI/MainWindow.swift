import AppKit
import PhoneBackupCore
import SwiftUI

public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var showingADBPanel = false

    public init() {}

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List {
                Section("ANDROID DEVICES") {
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
                    Button {
                        Task { await model.browseFiles() }
                    } label: {
                        Label("Browse Files…", systemImage: "folder.badge.gearshape")
                    }.disabled(model.isBusy || model.selectedDevice?.state != .device)
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isBusy || !model.hasADB)
                }

                Section("LIBRARY") {
                    Button {
                        model.section = .backups
                    } label: {
                        Label("Backups", systemImage: "externaldrive")
                            .foregroundStyle(model.section == .backups ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    Button {
                        model.section = .activity
                    } label: {
                        Label("Activity", systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(model.section == .activity ? Color.accentColor : Color.primary)
                    }.buttonStyle(.plain)
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
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.hasADB {
                    Button("Locate ADB…") { showingADBPanel = true }
                }
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

struct MessageBanner: View {
    let text: String
    var symbol = "info.circle"
    var isWarning = false

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(isWarning ? Color.orange : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background((isWarning ? Color.orange : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
