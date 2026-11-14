import PhoneBackupCore
import SwiftUI
import UniformTypeIdentifiers

struct PhoneFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemoteBrowserModel.self) private var browser
    @State private var isDropTargeted = false
    @State private var showingADBSetup = false

    private let developerOptionsURL = URL(string: "https://developer.android.com/studio/debug/dev-options#enable")!

    var body: some View {
        @Bindable var browser = browser
        VStack(spacing: 0) {
            HStack {
                Label("On \(browser.device?.model ?? "your phone") · USB", systemImage: "cable.connector")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 18).padding(.top, 12)
            RemoteBrowserNavigationBar(browser: browser)
            Divider()

            if browser.isLoading {
                ProgressView("Opening \(browser.displayedDirectory.description)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.device?.state != .device {
                ContentUnavailableView {
                    Label("Connect an Android device", systemImage: "cable.connector.slash")
                } description: {
                    Text(connectionUnavailableDescription)
                } actions: {
                    Button(model.hasADB ? "Connection Setup…" : "Set Up Connection…") {
                        showingADBSetup = true
                    }
                    Link("How to enable Developer options…", destination: developerOptionsURL)
                }
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
            } else if !browser.hasOpenedRoot {
                ContentUnavailableView {
                    Label("Phone shared storage", systemImage: "folder")
                } description: { Text("Open storage to browse the folders Android exposes.") } actions: {
                    Button("Open Shared Storage") { Task { await browser.openRoot() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.entries.isEmpty {
                ContentUnavailableView("This folder is empty", systemImage: "folder", description: Text(browser.currentDirectory.description))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(browser.entries, selection: $browser.selection) {
                    TableColumn("Name") { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.kind == .directory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.kind == .directory ? AppIdentity.blue : Color.secondary)
                            Text(entry.name).lineLimit(1)
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
                .contextMenu(forSelectionType: RemotePath.self) { paths in
                    if let entry = selectedFolder(in: paths) {
                        Button("Open Folder") { Task { await browser.open(entry) } }
                    }
                } primaryAction: { paths in
                    openFolder(in: paths)
                }
                .onKeyPress(.return) {
                    openFolder(in: browser.visibleSelection)
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
                Text(browser.isLoading ? "Opening folder…" : browser.selection.isEmpty ? "\(browser.entries.count) items" : "\(browser.visibleSelection.count) selected").font(.callout).foregroundStyle(.secondary)
                if browser.isShowingCachedContents { Text("Cached").font(.caption).foregroundStyle(.tertiary).help("Refresh to check the phone for changes.") }
                Spacer()
                if !browser.isLoading, browser.errorMessage == nil, browser.visibleSelection.count == 1, let path = browser.selection.first,
                   let entry = browser.entries.first(where: { $0.path == path }),
                   let deviceID = browser.device?.id, entry.kind == .file || entry.kind == .directory {
                    RemoteFilePromiseDragSource(entries: [entry], deviceID: deviceID, model: model).frame(width: 155, height: 34)
                        .accessibilityLabel("Drag selected item to Finder")
                }
                Button("Copy to Mac…") { choosePhoneExportDestination() }
                    .disabled(browser.visibleSelection.isEmpty || model.isBusy || browser.isLoading || browser.errorMessage != nil)
                Button("Copy from Mac…") { chooseMacSources() }
                    .disabled(browser.device?.state != .device || model.isBusy || browser.isLoading || browser.errorMessage != nil || !browser.hasOpenedRoot)
            }.padding(16)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            receiveFinderFiles(providers, destination: browser.currentDirectory,
                               expectedDirectory: browser.currentDirectory)
        }
        .navigationTitle("File Explorer")
        .onDisappear { browser.cancelNavigation() }
        .task {
            await openSharedStorageWhenReady()
        }
        .onChange(of: browser.device?.id) { _, _ in Task { await openSharedStorageWhenReady() } }
        .onChange(of: browser.device?.state) { _, _ in Task { await openSharedStorageWhenReady() } }
        .sheet(isPresented: $showingADBSetup) { ADBSetupView() }
    }

    private func selectedFolder(in paths: Set<RemotePath>) -> RemoteEntry? {
        guard !browser.isLoading, paths.count == 1, let path = paths.first else { return nil }
        return browser.entries.first { $0.path == path && $0.kind == .directory }
    }

    private func openFolder(in paths: Set<RemotePath>) {
        if let entry = selectedFolder(in: paths) { Task { await browser.open(entry) } }
    }

    private func openSharedStorageWhenReady() async {
        guard browser.device?.state == .device, !browser.hasOpenedRoot else { return }
        await browser.openRoot()
    }

    private var connectionUnavailableDescription: String {
        guard model.hasADB else { return "Set up ADB on this Mac, then prepare and authorize your phone to browse shared files." }
        guard let state = browser.device?.state else { return "Connect your phone with a data-capable USB cable, unlock it, and choose Check Again in Connection Setup." }
        switch state {
        case .device: "This phone is ready. Open shared storage to browse files."
        case .unauthorized: "Unlock your phone and approve the “Allow USB debugging?” prompt for this Mac."
        case .offline: "Android lists this phone as offline. Reconnect the cable and unlock the phone."
        case .bootloader, .recovery, .sideload: "Restart Android normally, then choose Check Again in Connection Setup."
        case .unknown: "Check the USB debugging setup on your phone, then choose Check Again."
        }
    }

    private func choosePhoneExportDestination() {
        let roots = Array(browser.visibleSelection)
        guard let folder = NativeFilePanels.chooseFolder(prompt: "Copy Android Files to Mac", message: "Selected files and folders will be copied beneath this folder.") else { return }
        Task { await model.planPhoneToMacCopy(roots: roots, destination: folder) }
    }

    private func chooseMacSources() {
        guard let sources = NativeFilePanels.chooseFilesAndFolders(prompt: "Choose Mac Files to Copy", message: "The selected files and folders will be copied into \(browser.currentDirectory.description) on the phone.") else { return }
        Task { await model.planMacToPhoneCopy(sources: sources, destination: browser.currentDirectory) }
    }

    private func receiveFinderFiles(_ providers: [NSItemProvider], destination: RemotePath,
                                   expectedDirectory: RemotePath) -> Bool {
        guard !browser.isLoading, browser.errorMessage == nil, browser.hasOpenedRoot,
              browser.device?.state == .device, !model.isBusy else { return false }
        let device = browser.device
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(provider) { urls.append(url) }
            }
            guard !browser.isLoading, browser.errorMessage == nil,
                  browser.device?.id == device?.id, browser.currentDirectory == expectedDirectory else {
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
