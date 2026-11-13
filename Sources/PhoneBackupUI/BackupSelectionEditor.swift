import PhoneBackupCore
import SwiftUI

struct BackupSelectionSession: Identifiable {
    let id = UUID()
    let device: AndroidDevice
    let selection: BackupSelection
}

public struct BackupSelectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    // The original phone stays fixed even if a parent view is reconstructed.
    @State private var device: AndroidDevice
    @State private var draft: BackupScopeDraft
    @State private var browser: RemoteBrowserModel?
    @State private var applicationError: String?

    public init(device: AndroidDevice, selection: BackupSelection) {
        _device = State(initialValue: device)
        _draft = State(initialValue: BackupScopeDraft(selection))
    }

    public var body: some View {
        VStack(spacing: 0) {
            AppPageHeader(title: "Choose Backup Files", subtitle: device.model ?? "Android device")
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    if let browser {
                        RemoteBrowserNavigationBar(browser: browser)
                        Divider()
                        directoryContents(browser)
                        Divider()
                        HStack {
                            Text("\(browser.visibleSelection.count) selected").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Exclude Selected") { draft.exclude(browser.visibleSelection) }
                                .disabled(browser.isLoading || !browser.visibleSelection.contains(where: draft.selection.includes) || model.isBusy)
                            Button("Include Selected") { draft.include(browser.visibleSelection) }
                                .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
                                .disabled(browser.isLoading || !draft.canInclude(browser.visibleSelection) || model.isBusy)
                        }.padding(14)
                        if browser.visibleSelection.contains(where: draft.hasExcludedAncestor) {
                            Text("A parent folder is excluded. Remove that exclusion from the scope list to include items inside it.")
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
                        }
                    } else { ProgressView("Opening phone storage…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(minWidth: 460)
                scopeTray.frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            }
            Divider()
            HStack(spacing: 12) {
                if let applicationError { Text(applicationError).font(.callout).foregroundStyle(.secondary) }
                else { Text(draft.allSharedFiles ? "All shared files · \(draft.selection.excludedRoots.count) excluded" : "\(draft.includedRoots.count) included locations")
                    .font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    if model.applyBackupSelection(draft.selection, for: device.id) { dismiss() }
                    else { applicationError = "The phone changed or became unavailable. Reopen the selection to continue." }
                }
                .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }.padding(18)
        }
        .frame(minWidth: 780, minHeight: 540)
        .controlSize(.large)
        .task {
            guard browser == nil, isCurrentDevice else { return }
            let created = model.makeRemoteBrowser(for: device.id)
            browser = created
            await created?.openRoot()
        }
        .onChange(of: model.selectedDevice?.id) { _, _ in if !isCurrentDevice { dismiss() } }
        .onChange(of: model.selectedDevice?.state) { _, _ in if !isCurrentDevice { dismiss() } }
        .onDisappear { browser?.cancelNavigation() }
    }

    private var isCurrentDevice: Bool { model.selectedDevice?.id == device.id && model.selectedDevice?.state == .device }
    private var canApply: Bool { isCurrentDevice && !model.isBusy && browser?.isLoading != true }

    @ViewBuilder
    private func directoryContents(_ browser: RemoteBrowserModel) -> some View {
        @Bindable var browser = browser
        if browser.isLoading {
            ProgressView("Opening \(browser.displayedDirectory.description)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browser.errorMessage {
            ContentUnavailableView {
                Label("Folder unavailable", systemImage: "folder.badge.questionmark")
            } description: { Text(error) } actions: { Button("Retry") { Task { await browser.refresh() } } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(browser.entries, selection: $browser.selection) {
                TableColumn("Name") { entry in
                    Label(entry.name, systemImage: entry.kind == .directory ? "folder.fill" : "doc")
                        .labelStyle(.titleAndIcon).lineLimit(1)
                }
                TableColumn("Backup") { entry in
                    Text(draft.status(for: entry.path)).font(.callout).foregroundStyle(.secondary)
                }.width(min: 80, ideal: 115, max: 170)
                TableColumn("Size") { entry in
                    Text(entry.kind == .file ? UIFormatting.bytes(entry.size ?? 0) : "—").foregroundStyle(.secondary)
                }.width(min: 50, ideal: 65, max: 100)
            }
            .contextMenu(forSelectionType: RemotePath.self) { paths in
                if let entry = folder(in: paths, browser: browser) {
                    Button("Open Folder") { Task { await browser.open(entry) } }
                }
            } primaryAction: { paths in openFolder(in: paths, browser: browser) }
            .onKeyPress(.return) { openFolder(in: browser.visibleSelection, browser: browser); return .handled }
            .overlay { if browser.entries.isEmpty { ContentUnavailableView("Empty folder", systemImage: "folder") } }
        }
    }

    private var scopeTray: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Backup scope").font(.headline)
                if draft.allSharedFiles {
                    Label("All shared files", systemImage: "externaldrive").font(.callout.weight(.medium))
                } else if draft.includedRoots.isEmpty {
                    Text("Select files or folders, then choose Include Selected.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(draft.includedRoots, id: \.self) { path in
                        scopeRow(path, excluded: false) { draft.removeIncluded(path) }
                    }
                }
                if !draft.selection.excludedRoots.isEmpty {
                    Divider()
                    Text("Excluded").font(.callout.weight(.semibold))
                    ForEach(draft.selection.excludedRoots, id: \.self) { path in
                        scopeRow(path, excluded: true) { draft.removeExclusion(path) }
                    }
                }
                Divider()
                DisclosureGroup("Advanced") {
                    Toggle("All shared files", isOn: Binding(get: { draft.allSharedFiles }, set: { draft.setAllSharedFiles($0) }))
                        .toggleStyle(.checkbox).font(.callout).padding(.top, 8)
                    Text("Includes accessible Android media and shared app folders. Exclusions are kept when switching modes.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }.padding(18)
        }
        .background(.quaternary.opacity(0.12))
    }

    private func scopeRow(_ path: RemotePath, excluded: Bool, remove: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: excluded ? "minus.circle" : "checkmark.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(path.name ?? "/").font(.callout.weight(.medium))
                Text(path.description).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel(excluded ? "Remove exclusion for \(path.description)" : "Remove \(path.description) from backup")
        }
    }

    private func folder(in paths: Set<RemotePath>, browser: RemoteBrowserModel) -> RemoteEntry? {
        guard !browser.isLoading, paths.count == 1, let path = paths.first else { return nil }
        return browser.entries.first { $0.path == path && $0.kind == .directory }
    }
    private func openFolder(in paths: Set<RemotePath>, browser: RemoteBrowserModel) {
        if let entry = folder(in: paths, browser: browser) { Task { await browser.open(entry) } }
    }
}
