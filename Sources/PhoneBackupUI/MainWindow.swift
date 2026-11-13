import AppKit
import PhoneBackupCore
import SwiftUI

public struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingADBSetup = false
    @State private var showingRecentOperations = false
    @State private var showingOmissionConfirmation = false

    public init(initialColumnVisibility: NavigationSplitViewVisibility = .all) {
        _columnVisibility = State(initialValue: initialColumnVisibility)
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding<AppSection?>(get: { model.section }, set: { section in if let section { model.section = section } })) {
                Section("Backups") {
                    Label { Text("Overview") } icon: { SidebarGlyph(symbol: "rectangle.portrait", color: AppIdentity.blue) }.tag(AppSection.device)
                    Label { Text("Saved Backups") } icon: { SidebarGlyph(symbol: "externaldrive.fill", color: AppIdentity.copper) }.tag(AppSection.backups)
                }
                Section("Phone") {
                    Label { Text("Phone Files") } icon: { SidebarGlyph(symbol: "folder.fill", color: AppIdentity.blue) }.tag(AppSection.files)
                }
                Section {
                    if model.devices.isEmpty {
                        Label(model.hasADB ? "Not connected" : "Connection setup needed", systemImage: "cable.connector.slash")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.devices) { device in
                        Button {
                            model.selectDevice(device)
                            model.section = .device
                        } label: {
                            DeviceSidebarRow(device: device, isSelected: model.selectedDevice?.id == device.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isBusy)
                        .accessibilityLabel("Select \(device.model ?? "Android device") \(device.id.serial)")
                    }
                } header: {
                    HStack {
                        Text("Connected devices")
                        Spacer()
                        Button { Task { await model.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).disabled(model.isBusy || !model.hasADB)
                            .help("Refresh connected devices").accessibilityLabel("Refresh connected devices")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 320)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if !model.hasADB {
                        Button("Set Up Connection…") { showingADBSetup = true }.disabled(model.isBusy)
                    } else {
                        SettingsLink { Label("Settings", systemImage: "gearshape") }
                    }
                    Spacer()
                }
                .font(.callout).buttonStyle(.borderless)
                .padding(14)
            }
        } detail: {
            Group {
                switch model.section {
                case .device: DeviceOverview()
                case .files: PhoneFilesView()
                case .backups: RestoreLibraryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsOperationStatus {
                    OperationStatusView(showingOmissionConfirmation: $showingOmissionConfirmation)
                        .padding(14)
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
        .background {
            WindowTitlebarBranding(columnVisibility: $columnVisibility).frame(width: 0, height: 0)
        }
        .toolbar(removing: .sidebarToggle)
        .tint(AppIdentity.blue)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingRecentOperations = true } label: {
                    Label("Recent Operations", systemImage: "clock.arrow.circlepath")
                }
                .help("Recent operations")
            }
        }
        .sheet(isPresented: $model.isShowingBackupReview) {
            BackupReviewSheet()
        }
        .sheet(isPresented: $model.isShowingExportReview) {
            LocalExportReviewSheet()
        }
        .sheet(isPresented: $model.isShowingCopyReview) { CopyReviewSheet() }
        .alert(PhoneBackupCore.applicationName, isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearStatus() } }
        )) {
            Button("OK", role: .cancel) { model.clearStatus() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showingADBSetup) { ADBSetupView() }
        .sheet(isPresented: $showingRecentOperations) { RecentOperationsSheet() }
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
