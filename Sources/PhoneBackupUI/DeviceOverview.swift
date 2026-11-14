import PhoneBackupCore
import SwiftUI

struct DeviceOverview: View {
    @Environment(AppModel.self) private var model
    @State private var selectionSession: BackupSelectionSession?
    @State private var showingConnectionSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceBackupHero(name: model.selectedDevice?.model ?? "Your Android",
                                 status: deviceStatus,
                                 connected: model.selectedDevice?.state == .device) {
                    DeviceBackupSummaryView(state: model.deviceBackupSummary, canRetry: !model.isBusy) {
                        Task { await model.retryDeviceBackupSummary() }
                    }
                } action: {
                    primaryAction
                }

                if let message = model.statusMessage, model.selectedDevice != nil, model.operationEvent == nil { MessageBanner(text: message) }

                VStack(spacing: 0) {
                    OverviewSettingRow(title: "Back up to", symbol: "externaldrive.fill") {
                        if let location = model.backupLocation {
                            Text(location.lastPathComponent).fontWeight(.medium)
                            DisclosureGroup("Show location") {
                                Text(location.path).font(.caption).textSelection(.enabled)
                            }.font(.caption)
                        } else {
                            Text("Choose a backup folder")
                        }
                    } action: {
                        Button(model.backupLocation == nil ? "Choose…" : "Change…") { chooseBackupFolder() }
                            .disabled(model.isBusy)
                    }
                    Divider().padding(.leading, 72)
                    OverviewSettingRow(title: "Included files", symbol: "folder.fill", color: AppIdentity.teal) {
                        Text(selectionTitle)
                        if !selectionPathRows.isEmpty {
                            DisclosureGroup(selectionDisclosureTitle) {
                                ForEach(selectionPathRows) { row in
                                    HStack(spacing: 6) {
                                        Image(systemName: row.isExcluded ? "minus.circle" : "folder")
                                        Text(row.path.description).lineLimit(1).textSelection(.enabled)
                                        if row.isExcluded { Text("Excluded").font(.caption) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.top, 4)
                            }.font(.caption)
                        }
                    } action: {
                        Button("Choose…") { beginSelection() }
                            .disabled(model.isBusy || model.selectedDevice?.state != .device)
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.06)) }

                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(AppIdentity.copper)
                    VStack(alignment: .leading, spacing: 4) {
                        if case .loaded(let summary) = model.deviceBackupSummary {
                            Text(summary.points.count == 1 ? "1 restore point" : "\(summary.points.count) restore points").font(.callout.weight(.medium))
                            if summary.incompleteCount > 0 {
                                Text("\(summary.points.count - summary.incompleteCount) complete · \(summary.incompleteCount) incomplete")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Backup library").font(.callout.weight(.medium))
                        }
                    }
                    Spacer()
                    Button(model.backupLocation == nil ? "Open Backup Folder…" : "Browse Backups") {
                        if model.backupLocation == nil { chooseBackupFolder() }
                        else { Task { await model.browseDeviceBackups() } }
                    }.disabled(model.isBusy)
                }.padding(.horizontal, 18)

            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.vertical, 28)
        }
        .navigationTitle("Overview")
        .sheet(item: $selectionSession) { session in
            BackupSelectionEditor(device: session.device, selection: session.selection)
        }
        .sheet(isPresented: $showingConnectionSetup) { ConnectionSetupView() }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.isPlanningBackup {
            Button("Show Progress") { model.showProgress() }
        } else if model.isBusy {
            Text(model.isOperationRunning ? "Operation in progress…" : "Preparing…")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Button {
                switch readiness {
                case .connection: showingConnectionSetup = true
                case .location: chooseBackupFolder()
                case .selection: beginSelection()
                case .ready: Task { await model.reviewBackup() }
                case .busy: break
                }
            } label: {
                Text(primaryActionTitle)
            }
            .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
        }
    }

    private var readiness: BackupReadiness {
        BackupReadiness.resolve(hasADB: model.hasADB, device: model.selectedDevice,
                                hasLocation: model.backupLocation != nil,
                                needsLocationRecovery: model.backupLocationNeedsAttention,
                                selection: model.backupSelection, isBusy: model.isBusy)
    }

    private var primaryActionTitle: String {
        switch readiness {
        case .connection: connectionActionTitle
        case .location: "Choose Backup Folder…"
        case .selection: "Choose Files…"
        case .ready: "Back Up…"
        case .busy: "Preparing…"
        }
    }

    private var connectionActionTitle: String {
        guard model.hasADB else { return "Set Up Connection…" }
        guard let state = model.selectedDevice?.state else { return "Connect Your Phone…" }
        return switch state {
        case .unauthorized: "Authorize This Mac…"
        case .offline: "Reconnect Phone…"
        case .device: "Connection Setup…"
        case .bootloader, .recovery, .sideload: "Restart Phone Normally…"
        case .unknown: "Check Connection…"
        }
    }

    private func beginSelection() {
        guard !model.isBusy, let device = model.selectedDevice, device.state == .device else { return }
        selectionSession = BackupSelectionSession(device: device, selection: model.backupSelection)
    }

    private func chooseBackupFolder() {
        guard let folder = NativeFilePanels.chooseFolder(prompt: "Choose Backup Folder",
                                                        message: "Androdo creates a device repository inside this folder.") else { return }
        Task { await model.chooseBackupLocation(folder) }
    }

    private var deviceStatus: String {
        guard model.hasADB else { return "Set up the Android connection to get started." }
        guard let device = model.selectedDevice else { return "Connect your phone over USB or Wi-Fi." }
        return switch device.state {
        case .device: connectedRouteDescription(device)
        case .unauthorized: "Unlock the phone and allow USB debugging, or pair it in Connection Setup."
        case .offline: "The phone is offline. Check USB or Wireless debugging, then refresh."
        case .bootloader, .recovery, .sideload: "Android is in a maintenance mode. Restart it to browse shared files."
        case .unknown(let state): "Unrecognized device state: \(state)"
        }
    }

    private func connectedRouteDescription(_ device: AndroidDevice) -> String {
        let hasUSB = device.sessions.contains { $0.connection.kind == .usb }
        let hasWiFi = device.sessions.contains { $0.connection.kind == .wireless }
        if hasUSB && hasWiFi { return "Connected by USB and Wi-Fi. Transfers prefer USB while it’s connected." }
        if hasWiFi { return "Connected over Wi-Fi." }
        if hasUSB { return "Connected by USB." }
        return "Connected through ADB."
    }

    private var selectionTitle: String {
        switch model.backupSelection.scope {
        case .allSharedStorage: "All shared files"
        case .selected(let roots):
            if roots.isEmpty { "No folders selected" }
            else {
                roots.prefix(2).map { $0.name ?? $0.description }.joined(separator: ", ")
                    + (roots.count > 2 ? " +\(roots.count - 2) more" : "")
            }
        }
    }

    private var selectionDisclosureTitle: String {
        switch model.backupSelection.scope {
        case .allSharedStorage: "Show excluded folders"
        case .selected: model.backupSelection.excludedRoots.isEmpty ? "Show selected folders" : "Show selected and excluded folders"
        }
    }

    private var selectionPathRows: [BackupScopePathRow] {
        let rows: [BackupScopePathRow]
        switch model.backupSelection.scope {
        case .allSharedStorage:
            rows = model.backupSelection.excludedRoots.map { BackupScopePathRow(path: $0, isExcluded: true) }
        case .selected(let roots):
            rows = roots.map { BackupScopePathRow(path: $0, isExcluded: false) }
                + model.backupSelection.excludedRoots.map { BackupScopePathRow(path: $0, isExcluded: true) }
        }
        return rows.sorted {
            if $0.path == $1.path { return !$0.isExcluded && $1.isExcluded }
            return RemotePath.bytewiseLess($0.path, $1.path)
        }
    }
}

private struct BackupScopePathRow: Identifiable {
    let path: RemotePath
    let isExcluded: Bool
    var id: String { "\(isExcluded ? "excluded" : "selected"): \(path.description)" }
}
