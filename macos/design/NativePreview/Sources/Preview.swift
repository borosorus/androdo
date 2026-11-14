import AppKit
import Observation
import PhoneBackupCore
import PhoneBackupUI
import SwiftUI

/// Separate development executable. It never constructs live services or reads standard preferences.
@main
struct NativePreviewApp: App {
    @State private var fixture = PreviewFixture()

    var body: some Scene {
        WindowGroup("Androdo · Fictional preview") {
            Group {
                if fixture.isProgressPreview {
                    if fixture.ready { OperationProgressWindow() }
                    else { ProgressView("Preparing fictional progress…") }
                } else if CommandLine.arguments.contains("--restore") || CommandLine.arguments.contains("--restore-review") {
                    if fixture.ready { PhoneRestoreDestinationSheet() }
                    else { ProgressView("Preparing fictional restore…") }
                } else if CommandLine.arguments.contains("--scope") {
                    if fixture.ready, let device = fixture.model.selectedDevice {
                        BackupSelectionEditor(device: device, selection: fixture.model.backupSelection)
                    } else { ProgressView("Loading fictional scope…") }
                } else {
                    MainWindow(initialColumnVisibility: CommandLine.arguments.contains("--collapsed") ? .detailOnly : .all)
                }
            }
                .environment(fixture.model)
                .environment(fixture.model.fileBrowser)
                .controlSize(.large)
                .frame(minWidth: fixture.size.width, minHeight: fixture.size.height)
                .background(WindowCapture(ready: fixture.ready, fixture: fixture))
                .task {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(15))
                        fixture.terminatePreview()
                    }
                    await fixture.load()
                }
        }
        .defaultSize(width: fixture.size.width, height: fixture.size.height)

        OperationProgressScene(model: fixture.model)
    }
}

@MainActor @Observable
final class PreviewFixture {
    let model: AppModel
    let size: NSSize
    var ready = false
    let isProgressPreview = CommandLine.arguments.contains("--progress") || CommandLine.arguments.contains("--progress-planning") || CommandLine.arguments.contains("--progress-failure")
    private let progressEngine = PreviewProgressCopyEngine()
    private let store = FakeBackupRepositoryStore()
    private let transport: FakeDeviceTransport
    private let device = AndroidDevice(id: try! DeviceID(serial: "fictional-preview"), state: .device, model: CommandLine.arguments.contains("--long-name") ? "Pixel 9 Pro with a deliberately long device name" : "Pixel 9")
    private let root: URL
    private let suite = "AndrodoNativePreview.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        size = isProgressPreview ? NSSize(width: 600, height: CommandLine.arguments.contains("--progress-failure") ? 440 : 280) : CommandLine.arguments.contains("--compact") ? NSSize(width: 900, height: 600) : NSSize(width: 1120, height: 720)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("androdo-fixture-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Android Backups", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        transport = FakeDeviceTransport(devices: [device])
        let firstUse = CommandLine.arguments.contains("--first-use")
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: firstUse ? nil : transport,
                                               remoteAccess: firstUse ? nil : transport,
                                               remoteDestinationAccess: firstUse ? nil : transport,
                                               backupEngine: firstUse ? nil : DefaultBackupEngine(remote: transport, repositoryStore: store),
                                               copyEngine: progressEngine),
                         preferences: AppPreferences(defaults: defaults), loadOnStart: false,
                         adbResolver: { _ in nil })
        NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
    }

    func load() async {
        if CommandLine.arguments.contains("--first-use") { ready = true; return }
        let point = RestorePoint(createdAt: Date(), state: .completed, entryCount: 128, totalBytes: 842_000_000)
        let repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/fixture"), deviceID: device.id, displayName: "Pixel 9")
        let entries = [BackupEntry(path: try! RemotePath("/sdcard/Pictures"), kind: .directory, size: 0, modifiedAt: nil, contentHash: nil),
                       BackupEntry(path: try! RemotePath("/sdcard/Documents"), kind: .directory, size: 0, modifiedAt: nil, contentHash: nil)]
        await store.seed(repository: repository, restorePoints: [point], entries: [point.id: entries])
        for entry in entries { await transport.seed(RemoteEntry(path: entry.path, kind: entry.kind), on: device.id) }
        await transport.seed(RemoteEntry(path: try! RemotePath("/sdcard/Pictures/Example.jpg"), kind: .file, size: 1), on: device.id, data: Data([1]))
        await model.refreshDevices()
        await model.chooseBackupLocation(root)
        model.setBackupSelection(BackupSelection(scope: .selected(entries.map(\.path))))
        if isProgressPreview || CommandLine.arguments.contains("--progress-window-check") {
            if CommandLine.arguments.contains("--progress-planning") {
                Task { await model.planPhoneToMacCopy(roots: [entries[0].path], destination: root) }
                await progressEngine.waitForPlanning()
            } else {
                await model.planPhoneToMacCopy(roots: [entries[0].path], destination: root)
                await model.startCopy(replacing: [])
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while model.operationEvent == nil && ContinuousClock.now < deadline { await Task.yield() }
                if CommandLine.arguments.contains("--progress-failure") {
                    while model.isBusy && ContinuousClock.now < deadline { await Task.yield() }
                }
            }
            ready = true
            return
        }
        if CommandLine.arguments.contains("--files") { model.section = .files }
        if CommandLine.arguments.contains("--result") || CommandLine.arguments.contains("--restore") || CommandLine.arguments.contains("--restore-review") || CommandLine.arguments.contains("--phone-handoff") {
            await model.reviewBackup()
            await model.startBackup()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.isBusy && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
        if CommandLine.arguments.contains("--backups") {
            model.section = .backups
            await model.selectRestorePoint(point)
        }
        if CommandLine.arguments.contains("--restore") || CommandLine.arguments.contains("--restore-review") || CommandLine.arguments.contains("--phone-handoff") {
            if let saved = try? await store.restorePoints(in: repository.id).first(where: { $0.id != point.id }) {
                await model.selectRestorePoint(saved)
                model.toggleRestoreRoot(entries[0].path)
                if CommandLine.arguments.contains("--restore-review") {
                    await model.planPhoneRestore(to: nil, policy: .replaceFiles)
                }
            }
        }
        if CommandLine.arguments.contains("--phone-handoff") {
            model.section = .backups
            model.isShowingPhoneRestoreSetup = true
            Task { @MainActor in
                // Present the actual setup first, then exercise a fast preparation handoff.
                try? await Task.sleep(for: .milliseconds(180))
                await model.planPhoneRestore(to: nil, policy: .replaceFiles)
            }
        }
        ready = true
    }

    func checkProgressWindowLifecycle(mainWindow: NSWindow) async -> Bool {
        guard let first = NSApp.windows.first(where: { $0.title == "Androdo — Progress" && $0.isVisible }),
              model.progressSession?.isPresented == true else { return false }
        let session = model.progressSession?.id
        first.performClose(nil)
        try? await Task.sleep(for: .milliseconds(100))
        guard model.progressSession?.isPresented == false, !first.isVisible, model.isOperationRunning else { return false }
        model.showProgress()
        try? await Task.sleep(for: .milliseconds(160))
        guard let reopened = NSApp.windows.first(where: { $0.title == "Androdo — Progress" && $0.isVisible }),
              model.progressSession?.id == session else { return false }
        // With no main view observer, the progress window must still dismiss itself.
        mainWindow.close()
        if CommandLine.arguments.contains("--progress-window-done") {
            await progressEngine.complete()
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while model.isBusy && ContinuousClock.now < deadline { await Task.yield() }
            guard model.progressSession?.isFinished == true, reopened.isVisible else { return false }
            model.dismissProgress()
            try? await Task.sleep(for: .milliseconds(100))
            return model.progressSession == nil && !reopened.isVisible
        }
        model.backgroundProgress()
        try? await Task.sleep(for: .milliseconds(100))
        guard !reopened.isVisible, model.isOperationRunning else { return false }
        await progressEngine.complete()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isBusy && ContinuousClock.now < deadline { await Task.yield() }
        guard model.progressSession?.isPresented == false,
              !NSApp.windows.contains(where: { $0.title == "Androdo — Progress" && $0.isVisible }) else { return false }
        return true
    }

    func terminatePreview() {
        cleanup()
        // AppKit otherwise vetoes termination while our fictional review sheet is attached.
        for window in NSApp.windows { window.preventsApplicationTerminationWhenModal = false }
        NSApp.terminate(nil)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

private struct WindowCapture: NSViewRepresentable {
    let ready: Bool
    let fixture: PreviewFixture

    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) {
        view.fixture = fixture
        view.ready = ready
        view.scheduleIfReady()
    }

    final class CaptureView: NSView {
        var fixture: PreviewFixture?
        var ready = false
        private var scheduled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleIfReady() }

        func scheduleIfReady() {
            guard ready, !scheduled, let window, let fixture,
                  let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else { return }
            scheduled = true
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // Let the native toolbar and SwiftUI layout finish on this window only.
                try? await Task.sleep(for: .milliseconds(400))
                // The requested size is the usable content area, excluding unified toolbar chrome.
                let inset = (window.contentView?.bounds.height ?? window.frame.height) - window.contentLayoutRect.height
                window.setContentSize(NSSize(width: fixture.size.width, height: fixture.size.height + max(0, inset)))
                window.contentView?.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(100))
                // Catch review state being cleared by setup/review view lifecycle changes.
                if CommandLine.arguments.contains("--phone-handoff") {
                    try? await Task.sleep(for: .milliseconds(700))
                }
                if CommandLine.arguments.contains("--restore-review") || CommandLine.arguments.contains("--phone-handoff"),
                   fixture.model.restorePlan?.fileCount != 1 || !fixture.model.isShowingExportReview {
                    let description = "Fictional phone handoff lost review: files=\(fixture.model.restorePlan?.fileCount ?? -1), visible=\(fixture.model.isShowingExportReview), setup=\(fixture.model.isShowingPhoneRestoreSetup)"
                    try? Data(description.utf8).write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("failure.txt"))
                    fixture.terminatePreview()
                    return
                }
                if CommandLine.arguments.contains("--progress-window-check") {
                    guard await fixture.checkProgressWindowLifecycle(mainWindow: window) else {
                        try? Data("Fictional progress window lifecycle assertion failed".utf8).write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("failure.txt"))
                        fixture.terminatePreview(); return
                    }
                    // Save the already retained main view after the lifecycle assertions.
                }
                let captureWindow = CommandLine.arguments.contains("--phone-handoff") ? window.attachedSheet ?? window : window
                if let frameView = captureWindow.contentView?.superview,
                   let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: output))
                    }
                }
                if CommandLine.arguments.contains("--phone-handoff-cancel") {
                    let event = window.attachedSheet.flatMap { sheet in
                        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
                    }
                    let handled = event.map { window.attachedSheet?.performKeyEquivalent(with: $0) == true } ?? false
                    try? await Task.sleep(for: .milliseconds(400))
                    if !handled || fixture.model.isShowingExportReview || fixture.model.restorePlan != nil || window.attachedSheet != nil {
                        try? FileManager.default.removeItem(atPath: output)
                        try? Data("Fictional phone review Escape dismissal failed".utf8).write(to: URL(fileURLWithPath: output).deletingLastPathComponent().appendingPathComponent("failure.txt"))
                    }
                }
                fixture.terminatePreview()
            }
        }
    }
}

/// Development-only deterministic progress. It never reads or publishes files.
private actor PreviewProgressCopyEngine: CopyEngine {
    private let operation = OperationID()
    private var planningWaiter: CheckedContinuation<Void, Never>?
    private var planningGate: CheckedContinuation<Void, Never>?
    private var isPlanning = false
    private var subscribers: [AsyncStream<OperationEvent>.Continuation] = []

    func planCopy(_ request: CopyRequest) async throws -> CopyPlan {
        if CommandLine.arguments.contains("--progress-planning") {
            await withCheckedContinuation { continuation in
                planningGate = continuation
                isPlanning = true
                planningWaiter?.resume()
                planningWaiter = nil
            }
        }
        return CopyPlan(request: request, mappings: [], conflicts: [], totalBytes: 100_000_000, fileCount: 20, directoryCount: 1)
    }
    func waitForPlanning() async {
        if isPlanning { return }
        await withCheckedContinuation { planningWaiter = $0 }
    }
    func startCopy(_ plan: CopyPlanID, replacing conflicts: Set<UUID>) async throws -> OperationID { operation }
    func events(for operation: OperationID) async -> AsyncStream<OperationEvent> {
        let failed = CommandLine.arguments.contains("--progress-failure")
        return AsyncStream { continuation in
            continuation.yield(OperationEvent(operationID: operation, phase: failed ? .failed : .transferring,
                progress: OperationProgress(completedItems: 7, totalItems: 21, completedBytes: 34_000_000, totalBytes: 100_000_000),
                failure: failed ? .deviceUnavailable(try! DeviceID(serial: "fictional-preview")) : nil))
            if failed { continuation.finish() }
            else { subscribers.append(continuation) }
        }
    }
    func complete() {
        for continuation in subscribers {
            continuation.yield(OperationEvent(operationID: operation, phase: .completed,
                progress: OperationProgress(completedItems: 21, totalItems: 21, completedBytes: 100_000_000, totalBytes: 100_000_000)))
            continuation.finish()
        }
    }
    func result(for operation: OperationID) async -> CopyBatchResult? { nil }
    func cancel(_ operation: OperationID) async {}
}
