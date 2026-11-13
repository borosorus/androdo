import PhoneBackupCore
import SwiftUI

struct DeviceOverview: View {
    @Environment(AppModel.self) private var model
    @State private var showingSelection = false
    @State private var showingOmissionConfirmation = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 30)).foregroundStyle(.tint)
                        .frame(width: 58, height: 58)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.selectedDevice?.model ?? "Connect an Android device")
                            .font(.title2.weight(.semibold))
                        Text(model.selectedDevice.map { "\($0.id.serial) · \($0.state == .device ? "Ready" : String(describing: $0.state))" } ?? "Connect by USB and authorize this Mac")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Browse Files…") { Task { await model.browseFiles() } }
                        .disabled(model.isBusy || model.selectedDevice?.state != .device)
                }

                if let message = model.statusMessage { MessageBanner(text: message) }

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Backup destination", systemImage: "externaldrive")
                                .font(.headline)
                            Spacer()
                            Button(model.backupLocation == nil ? "Choose Folder…" : "Change…") {
                                if let folder = NativeFilePanels.chooseFolder(prompt: "Choose Backup Folder", message: "PhoneBackup creates a device repository inside this folder.") {
                                    Task { await model.chooseBackupLocation(folder) }
                                }
                            }.disabled(model.isBusy)
                        }
                        if let url = model.backupLocation {
                            Label(url.path, systemImage: "folder")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        } else {
                            Text("Choose a local or external folder. Backups stay on this Mac and are not uploaded.")
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("What to back up", systemImage: "checklist")
                                .font(.headline)
                            Spacer()
                            Button("Choose Folders…") { showingSelection = true }
                                .disabled(model.isBusy || model.selectedDevice == nil)
                        }
                        Text(selectionSummary)
                            .foregroundStyle(.secondary)
                        if model.isShowingBackupReview || model.isPlanningBackup { EmptyView() }
                        HStack {
                            Button {
                                Task { await model.reviewBackup() }
                            } label: {
                                if model.isPlanningBackup { ProgressView().controlSize(.small); Text("Preparing plan…") }
                                else { Label("Back Up Now", systemImage: "arrow.down.to.line") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isBusy || model.backupLocation == nil || model.selectedDevice == nil)
                            if model.isPlanningBackup {
                                Button("Cancel") { model.cancelPlanning() }
                            }
                            Spacer()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }

                if model.isOperationRunning || model.recoveryAttempt != nil || model.operationEvent != nil || !model.pendingAttempts.isEmpty {
                    OperationStatusView(showingOmissionConfirmation: $showingOmissionConfirmation)
                }
            }
            .padding(28)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Device")
        .sheet(isPresented: $showingSelection) { BackupSelectionEditor() }
        .confirmationDialog("Finish this backup with skipped paths?", isPresented: $showingOmissionConfirmation, titleVisibility: .visible) {
            Button("Finish with omissions", role: .destructive) { Task { await model.finishBackupWithOmissions() } }
            Button("Keep incomplete", role: .cancel) {}
        } message: {
            Text("The restore point will be marked incomplete and will list the paths that could not be saved.")
        }
    }

    private var selectionSummary: String {
        switch model.backupSelection.scope {
        case .allSharedStorage:
            let excluded = model.backupSelection.excludedRoots.count
            return excluded == 0 ? "All shared files on the device (/sdcard)" : "All shared files except \(excluded) excluded folder(s)"
        case .selected(let roots):
            guard !roots.isEmpty else { return "No folders selected" }
            let picked = roots.map(\.description).joined(separator: " · ")
            if model.backupSelection.excludedRoots.isEmpty { return picked }
            return "\(picked) · \(model.backupSelection.excludedRoots.count) excluded"
        }
    }
}

struct BackupSelectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RemoteEntry] = []

    private let root = try! RemotePath("/sdcard")

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose backup folders").font(.title2.weight(.semibold))
                    Text("Folders are listed only when you open them.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            Toggle(isOn: Binding(
                get: { if case .allSharedStorage = model.backupSelection.scope { true } else { false } },
                set: { model.setBackupSelection($0 ? BackupSelection(scope: .allSharedStorage) : BackupSelection()) }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("All shared files").fontWeight(.medium)
                    Text("Includes files exposed under /sdcard, including accessible Android media/data/obb folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            Divider()
            if model.isLoadingFolder && entries.isEmpty {
                ProgressView("Opening /sdcard…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("No folders available", systemImage: "folder.badge.questionmark", description: Text("Connect and authorize a device to browse shared storage."))
            } else {
                List {
                    ForEach(entries) { entry in
                        RemoteSelectionRow(entry: entry, depth: 0)
                    }
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                Text(selectedSummary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .frame(minWidth: 600, minHeight: 480)
        .task { entries = await model.listRemoteChildren(of: root).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }

    private var selectedSummary: String {
        if case .selected(let roots) = model.backupSelection.scope { return "\(roots.count) folder(s) selected" }
        return "All shared files selected"
    }
}

private struct RemoteSelectionRow: View {
    @Environment(AppModel.self) private var model
    let entry: RemoteEntry
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
            ForEach(children) { child in RemoteSelectionRow(entry: child, depth: depth + 1) }
        }
    }

    private var selectionBinding: Binding<Bool> {
        Binding(get: { isSelected }, set: { setSelected($0) })
    }

    private var isBlockedByAncestorExclusion: Bool {
        model.backupSelection.excludedRoots.contains { $0 != entry.path && entry.path.isEqualOrDescendant(of: $0) }
    }

    private var isSelected: Bool {
        model.backupSelection.includes(entry.path)
    }

    private func setSelected(_ selected: Bool) {
        var roots: [RemotePath] = []
        var exclusions = model.backupSelection.excludedRoots
        switch model.backupSelection.scope {
        case .allSharedStorage:
            if selected {
                exclusions.removeAll { $0 == entry.path || entry.path.isEqualOrDescendant(of: $0) }
            } else {
                exclusions.removeAll { $0.isEqualOrDescendant(of: entry.path) }
                exclusions.append(entry.path)
            }
            model.setBackupSelection(BackupSelection(scope: .allSharedStorage, excludedRoots: exclusions))
            return
        case .selected(let existing): roots = existing
        }
        if selected {
            exclusions.removeAll { $0 == entry.path || entry.path.isEqualOrDescendant(of: $0) }
            if !roots.contains(where: { entry.path.isEqualOrDescendant(of: $0) }) { roots.append(entry.path) }
        } else {
            roots.removeAll { $0.isEqualOrDescendant(of: entry.path) }
            if roots.contains(where: { entry.path.isEqualOrDescendant(of: $0) }) {
                exclusions.removeAll { $0.isEqualOrDescendant(of: entry.path) }
                exclusions.append(entry.path)
            }
        }
        model.setBackupSelection(BackupSelection(scope: .selected(roots), excludedRoots: exclusions))
    }

    private func loadChildren() async {
        loading = true
        children = await model.listRemoteChildren(of: entry.path).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loading = false
    }
}
