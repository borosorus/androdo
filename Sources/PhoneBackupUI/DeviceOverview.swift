import PhoneBackupCore
import SwiftUI

struct DeviceOverview: View {
    @Environment(AppModel.self) private var model
    @State private var showingSelection = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AppPageHeader(title: "Overview", subtitle: "Choose what to save, then review the backup before it starts.")

                GroupBox("Android device") {
                    HStack(spacing: 14) {
                        Image(systemName: deviceSymbol)
                            .font(.system(size: 25))
                            .foregroundStyle(model.selectedDevice?.state == .device ? Color.accentColor : Color.secondary)
                            .frame(width: 48, height: 48)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.selectedDevice?.model ?? "No device connected")
                                .font(.headline)
                            Text(deviceStatus)
                                .font(.callout).foregroundStyle(.secondary)
                            if let device = model.selectedDevice {
                                Text(device.id.serial).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                if let message = model.statusMessage { MessageBanner(text: message) }

                GroupBox("Backup destination") {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Location") {
                            Text(model.backupLocation?.path ?? "Choose a folder on this Mac")
                                .foregroundStyle(model.backupLocation == nil ? Color.secondary : Color.primary)
                                .lineLimit(2).textSelection(.enabled)
                        }
                        Text("Backups remain on this Mac or the external drive you choose.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button(model.backupLocation == nil ? "Choose Folder…" : "Change Folder…") {
                                guard let folder = NativeFilePanels.chooseFolder(
                                    prompt: "Choose Backup Folder",
                                    message: "PhoneBackup creates a device repository inside this folder.") else { return }
                                Task { await model.chooseBackupLocation(folder) }
                            }
                            .disabled(model.isBusy)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox("What to back up") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(selectionTitle, systemImage: "checklist").font(.headline)
                            Spacer()
                            Button("Choose Folders…") { showingSelection = true }
                                .disabled(model.isBusy || model.selectedDevice?.state != .device)
                        }
                        Text(selectionDetail).foregroundStyle(.secondary)
                        if !selectionPathRows.isEmpty {
                            DisclosureGroup(selectionDisclosureTitle) {
                                ForEach(selectionPathRows) { row in
                                    HStack(spacing: 8) {
                                        Image(systemName: row.isExcluded ? "minus.circle" : "folder")
                                            .foregroundStyle(row.isExcluded ? Color.secondary : Color.accentColor)
                                        Text(row.path.description).lineLimit(1).textSelection(.enabled)
                                        if row.isExcluded {
                                            Text("Excluded").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.top, 4)
                            }
                            .font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                HStack {
                    if model.isPlanningBackup {
                        ProgressView("Preparing backup plan…")
                        Button("Cancel") { model.cancelPlanning() }.keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            Task { await model.reviewBackup() }
                        } label: {
                            Label("Back Up Now", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.backupLocation == nil || model.selectedDevice?.state != .device)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .navigationTitle("Overview")
        .sheet(isPresented: $showingSelection) { BackupSelectionEditor() }
    }

    private var deviceSymbol: String {
        model.selectedDevice?.state == .device ? "iphone.gen3" : "cable.connector.slash"
    }

    private var deviceStatus: String {
        guard let device = model.selectedDevice else { return "Connect by USB and authorize this Mac." }
        return switch device.state {
        case .device: "Connected and ready"
        case .unauthorized: "Unlock the phone and allow USB debugging."
        case .offline: "The phone is offline. Reconnect the USB cable."
        case .bootloader, .recovery, .sideload: "Android is in a maintenance mode. Restart it to browse shared files."
        case .unknown(let state): "Unrecognized device state: \(state)"
        }
    }

    private var selectionTitle: String {
        switch model.backupSelection.scope {
        case .allSharedStorage: "All shared files"
        case .selected(let roots): roots.isEmpty ? "No folders selected" : "\(roots.count) selected"
        }
    }

    private var selectionDetail: String {
        switch model.backupSelection.scope {
        case .allSharedStorage:
            let excluded = model.backupSelection.excludedRoots.count
            return excluded == 0 ? "Files Android exposes under /sdcard." : "Shared storage, excluding \(excluded) folder(s)."
        case .selected(let roots):
            return roots.isEmpty ? "Choose the folders you want in each restore point." : "Only the selected files and folders are included."
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

struct BackupSelectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RemoteEntry] = []
    @State private var draftSelection: BackupSelection?

    private let root = try! RemotePath("/sdcard")

    var body: some View {
        VStack(spacing: 0) {
            AppPageHeader(title: "Choose backup folders", subtitle: "Folders are listed only when you open them.")
            Divider()
            Toggle(isOn: allSharedFilesBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("All shared files").fontWeight(.medium)
                    Text("Includes files exposed under /sdcard, including accessible Android media, data, and obb folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            if model.isLoadingFolder && entries.isEmpty {
                ProgressView("Opening /sdcard…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, entries.isEmpty {
                ContentUnavailableView("Folders unavailable", systemImage: "folder.badge.questionmark", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No folders available", systemImage: "folder.badge.questionmark", description: Text("Connect and authorize a device to browse shared storage."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        RemoteSelectionRow(entry: entry, selection: selectionBinding, depth: 0)
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text(draftSummary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.setBackupSelection(currentSelection)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: 600, minHeight: 480)
        .onAppear { draftSelection = model.backupSelection }
        .task {
            let result = await model.listRemoteChildren(of: root)
            entries = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var currentSelection: BackupSelection { draftSelection ?? model.backupSelection }

    private var selectionBinding: Binding<BackupSelection> {
        Binding(get: { currentSelection }, set: { draftSelection = $0 })
    }

    private var allSharedFilesBinding: Binding<Bool> {
        Binding(get: {
            if case .allSharedStorage = currentSelection.scope { true } else { false }
        }, set: { enabled in
            selectionBinding.wrappedValue = enabled ? BackupSelection(scope: .allSharedStorage) : BackupSelection()
        })
    }

    private var draftSummary: String {
        switch currentSelection.scope {
        case .allSharedStorage:
            return currentSelection.excludedRoots.isEmpty ? "All shared files selected" : "All shared files · \(currentSelection.excludedRoots.count) excluded"
        case .selected(let roots): return "\(roots.count) file(s) or folder(s) selected"
        }
    }
}

enum BackupSelectionEditing {
    static func set(_ isSelected: Bool, path: RemotePath, in selection: BackupSelection) -> BackupSelection {
        var roots: [RemotePath]
        var exclusions = selection.excludedRoots
        switch selection.scope {
        case .allSharedStorage:
            if isSelected {
                exclusions.removeAll { $0 == path || path.isEqualOrDescendant(of: $0) }
            } else {
                exclusions.removeAll { $0.isEqualOrDescendant(of: path) }
                exclusions.append(path)
            }
            return BackupSelection(scope: .allSharedStorage, excludedRoots: exclusions)
        case .selected(let existing): roots = existing
        }

        if isSelected {
            exclusions.removeAll { $0 == path || path.isEqualOrDescendant(of: $0) }
            if !roots.contains(where: { path.isEqualOrDescendant(of: $0) }) { roots.append(path) }
        } else {
            let coveredBySelectedAncestor = roots.contains { $0 != path && path.isEqualOrDescendant(of: $0) }
            roots.removeAll { $0.isEqualOrDescendant(of: path) }
            if coveredBySelectedAncestor {
                exclusions.removeAll { $0.isEqualOrDescendant(of: path) }
                exclusions.append(path)
            }
        }
        return BackupSelection(scope: .selected(roots), excludedRoots: exclusions)
    }
}

private struct RemoteSelectionRow: View {
    @Environment(AppModel.self) private var model
    let entry: RemoteEntry
    @Binding var selection: BackupSelection
    let depth: Int
    @State private var children: [RemoteEntry] = []
    @State private var expanded = false
    @State private var loading = false

    var body: some View {
        HStack(spacing: 8) {
            if entry.kind == .directory {
                Button {
                    expanded.toggle()
                    if expanded && children.isEmpty { Task { await loadChildren() } }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).frame(width: 18)
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse \(entry.name)" : "Open \(entry.name)")
            } else { Spacer().frame(width: 18) }
            Toggle(isOn: selectionBinding) {
                Label(entry.name, systemImage: entry.kind == .directory ? "folder" : "doc")
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .disabled(isBlockedByAncestorExclusion)
            .help(isBlockedByAncestorExclusion ? "This item is excluded by a parent folder. Select that parent to include it again." : entry.path.description)
            Spacer()
            if let size = entry.size, entry.kind == .file { Text(UIFormatting.bytes(size)).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.leading, CGFloat(depth * 18))
        .padding(.vertical, 2)
        if expanded {
            if loading { ProgressView().controlSize(.small).padding(.leading, CGFloat((depth + 1) * 18)) }
            ForEach(children) { child in RemoteSelectionRow(entry: child, selection: $selection, depth: depth + 1) }
        }
    }

    private var selectionBinding: Binding<Bool> {
        Binding(get: { selection.includes(entry.path) }, set: { selected in
            selection = BackupSelectionEditing.set(selected, path: entry.path, in: selection)
        })
    }

    private var isBlockedByAncestorExclusion: Bool {
        selection.excludedRoots.contains { $0 != entry.path && entry.path.isEqualOrDescendant(of: $0) }
    }

    private func loadChildren() async {
        loading = true
        let result = await model.listRemoteChildren(of: entry.path)
        children = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loading = false
    }
}
