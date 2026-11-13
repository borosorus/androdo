import PhoneBackupCore
import SwiftUI
import UniformTypeIdentifiers

struct PhoneFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteBrowserModel.self) private var browser
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { Task { await browser.goUp() } } label: { Image(systemName: "chevron.left") }
                    .disabled(browser.currentDirectory.parent == nil || browser.isLoading)
                    .accessibilityLabel("Go to parent folder")
                ForEach(Array(browser.breadcrumbs.enumerated()), id: \.offset) { _, path in
                    Button(path.name ?? "/") { Task { await browser.navigate(to: path) } }
                        .disabled(browser.isLoading || path == browser.currentDirectory)
                    if path != browser.currentDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer()
                Picker("Sort by", selection: Binding(get: { browser.sortColumn }, set: { browser.sort(by: $0, ascending: browser.sortAscending) })) {
                    ForEach(RemoteSortColumn.allCases, id: \.self) { column in Text(column.rawValue.capitalized).tag(column) }
                }.frame(width: 120)
                Button {
                    browser.sort(by: browser.sortColumn, ascending: !browser.sortAscending)
                } label: {
                    Image(systemName: browser.sortAscending ? "arrow.up" : "arrow.down")
                }.accessibilityLabel(browser.sortAscending ? "Sort ascending" : "Sort descending")
                Button { Task { await browser.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(browser.isLoading || browser.device?.state != .device)
                    .accessibilityLabel("Refresh folder")
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()

            if browser.isLoading && browser.entries.isEmpty {
                ProgressView("Opening \(browser.currentDirectory.description)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.device?.state != .device {
                ContentUnavailableView("Connect an Android device", systemImage: "cable.connector.slash", description: Text("Connect and authorize a phone to browse shared files."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = browser.errorMessage {
                ContentUnavailableView {
                    Label("Folder unavailable", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await browser.refresh() } }
                    Button("Back") { Task { await browser.goUp() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.entries.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text(browser.currentDirectory.description))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(browser.entries, selection: $browser.selection) {
                    TableColumn("Name") { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.kind == .directory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.kind == .directory ? Color.accentColor : Color.secondary)
                            Text(entry.name).lineLimit(1)
                                .onTapGesture(count: 2) { if entry.kind == .directory { Task { await browser.open(entry) } } }
                                .contextMenu {
                                    if entry.kind == .directory {
                                        Button("Open Folder") { Task { await browser.open(entry) } }
                                    }
                                }
                                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                                    guard entry.kind == .directory else { return false }
                                    return receiveFinderFiles(providers, destination: entry.path,
                                                              expectedDirectory: browser.currentDirectory)
                                }
                        }.accessibilityElement(children: .combine)
                    }
                    TableColumn("Kind") { entry in Text(entry.kind.rawValue.capitalized) }
                    TableColumn("Size") { entry in
                        Text(entry.kind == .file ? UIFormatting.bytes(entry.size ?? 0) : "—")
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Modified") { entry in
                        Text(entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
                .onSubmit { openSelectedFolder() }
                .onKeyPress(.return) {
                    openSelectedFolder()
                    return .handled
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                    receiveFinderFiles(providers, destination: browser.currentDirectory,
                                       expectedDirectory: browser.currentDirectory)
                }
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .padding(8).allowsHitTesting(false)
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Text("\(browser.selection.count) selected").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if browser.selection.count == 1, let path = browser.selection.first,
                   let entry = browser.entries.first(where: { $0.path == path }),
                   let deviceID = browser.device?.id, entry.kind == .file || entry.kind == .directory {
                    RemoteFilePromiseDragSource(entries: [entry], deviceID: deviceID, model: model).frame(width: 145, height: 30)
                        .accessibilityLabel("Drag selected item to Finder")
                }
                Button("Copy to Mac…") { choosePhoneExportDestination() }
                    .disabled(browser.selection.isEmpty || model.isBusy)
                Button("Copy from Mac…") { chooseMacSources() }
                    .disabled(browser.device?.state != .device || model.isBusy)
                    .buttonStyle(.borderedProminent)
            }.padding(16)
            if model.isPlanningCopy { ProgressView("Preparing file copy plan…").padding(.horizontal, 16).padding(.bottom, 10) }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            receiveFinderFiles(providers, destination: browser.currentDirectory,
                               expectedDirectory: browser.currentDirectory)
        }
        .navigationTitle("Files")
        .task {
            await openSharedStorageWhenReady()
        }
        .onChange(of: browser.device?.id) { _, _ in Task { await openSharedStorageWhenReady() } }
        .onChange(of: browser.device?.state) { _, _ in Task { await openSharedStorageWhenReady() } }
    }

    private func openSelectedFolder() {
        guard browser.selection.count == 1, let path = browser.selection.first,
              let entry = browser.entries.first(where: { $0.path == path }), entry.kind == .directory else { return }
        Task { await browser.open(entry) }
    }

    private func openSharedStorageWhenReady() async {
        guard browser.device?.state == .device, !browser.hasOpenedRoot else { return }
        await browser.openRoot()
    }

    private func choosePhoneExportDestination() {
        let roots = Array(browser.selection)
        guard let folder = NativeFilePanels.chooseFolder(prompt: "Copy Android Files to Mac", message: "Selected files and folders will be copied beneath this folder.") else { return }
        Task { await model.planPhoneToMacCopy(roots: roots, destination: folder) }
    }

    private func chooseMacSources() {
        guard let sources = NativeFilePanels.chooseFilesAndFolders(prompt: "Choose Mac Files to Copy", message: "The selected files and folders will be copied into \(browser.currentDirectory.description) on the phone.") else { return }
        Task { await model.planMacToPhoneCopy(sources: sources, destination: browser.currentDirectory) }
    }

    private func receiveFinderFiles(_ providers: [NSItemProvider], destination: RemotePath,
                                   expectedDirectory: RemotePath) -> Bool {
        let device = browser.device
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(provider) { urls.append(url) }
            }
            guard browser.device?.id == device?.id, browser.currentDirectory == expectedDirectory else {
                model.reportError("The phone folder changed while Finder was providing files. Drop the files again in the intended folder.")
                return
            }
            guard !urls.isEmpty else {
                model.reportError("Finder did not provide any local files that can be copied.")
                return
            }
            await model.planMacToPhoneCopy(sources: urls, destination: destination)
        }
        return !providers.isEmpty
    }

    private func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                continuation.resume(returning: error == nil ? object as? URL : nil)
            }
        }
    }
}
