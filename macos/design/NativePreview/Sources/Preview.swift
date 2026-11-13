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
            MainWindow(initialColumnVisibility: CommandLine.arguments.contains("--collapsed") ? .detailOnly : .all)
                .environment(fixture.model)
                .environment(fixture.model.fileBrowser)
                .controlSize(.large)
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowCapture(ready: fixture.ready, fixture: fixture))
                .task {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(15))
                        fixture.cleanup()
                        NSApp.terminate(nil)
                    }
                    await fixture.load()
                }
        }
        .defaultSize(width: fixture.size.width, height: fixture.size.height)
    }
}

@MainActor @Observable
final class PreviewFixture {
    let model: AppModel
    let size: NSSize
    var ready = false
    private let store = FakeBackupRepositoryStore()
    private let transport: FakeDeviceTransport
    private let device = AndroidDevice(id: try! DeviceID(serial: "fictional-preview"), state: .device, model: CommandLine.arguments.contains("--long-name") ? "Pixel 9 Pro with a deliberately long device name" : "Pixel 9")
    private let root: URL
    private let suite = "AndrodoNativePreview.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() {
        size = CommandLine.arguments.contains("--compact") ? NSSize(width: 900, height: 600) : NSSize(width: 1120, height: 720)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("androdo-fixture-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Android Backups", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        transport = FakeDeviceTransport(devices: [device])
        let firstUse = CommandLine.arguments.contains("--first-use")
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: firstUse ? nil : transport,
                                               remoteAccess: firstUse ? nil : transport),
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
        await model.refreshDevices()
        await model.chooseBackupLocation(root)
        model.setBackupSelection(BackupSelection(scope: .selected(entries.map(\.path))))
        if CommandLine.arguments.contains("--backups") {
            model.section = .backups
            await model.selectRestorePoint(point)
        }
        ready = true
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
                if let frameView = window.contentView?.superview,
                   let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: output))
                    }
                }
                fixture.cleanup()
                NSApp.terminate(nil)
            }
        }
    }
}
