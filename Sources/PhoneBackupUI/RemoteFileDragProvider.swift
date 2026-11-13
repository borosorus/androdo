import AppKit
import PhoneBackupCore
import SwiftUI
import UniformTypeIdentifiers

private final class PromiseCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: Error?) { handler(error) }
}

struct RemoteFilePromiseDragSource: NSViewRepresentable {
    let entries: [RemoteEntry]
    let deviceID: DeviceID
    let model: AppModel

    func makeNSView(context: Context) -> PromiseDragHandleView {
        let view = PromiseDragHandleView()
        view.entries = entries
        view.deviceID = deviceID
        view.model = model
        return view
    }

    func updateNSView(_ view: PromiseDragHandleView, context: Context) {
        view.entries = entries
        view.deviceID = deviceID
        view.model = model
    }
}

private struct RemotePromiseItem: Sendable {
    let entry: RemoteEntry
    let deviceID: DeviceID
}

@MainActor
final class PromiseDragHandleView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var entries: [RemoteEntry] = []
    var deviceID: DeviceID?
    weak var model: AppModel?
    private var dragStarted = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: nil)
        image?.draw(in: NSRect(x: 9, y: (bounds.height - 14) / 2, width: 14, height: 14))
        ("Drag to Finder" as NSString).draw(at: NSPoint(x: 29, y: (bounds.height - 14) / 2),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }

    override func mouseDown(with event: NSEvent) { dragStarted = false }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, model != nil, let deviceID, !entries.isEmpty else { return }
        dragStarted = true
        let items = entries.map { entry -> NSDraggingItem in
            let provider = NSFilePromiseProvider(fileType: Self.typeIdentifier(for: entry), delegate: self)
            provider.userInfo = RemotePromiseItem(entry: entry, deviceID: deviceID)
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(bounds, contents: snapshot())
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? RemotePromiseItem)?.entry.name ?? "Android file"
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        let item = filePromiseProvider.userInfo as? RemotePromiseItem
        let completion = PromiseCompletion(completionHandler)
        Task { @MainActor [weak self] in
            guard let self, let item else {
                completion.call(CocoaError(.fileReadUnknown))
                return
            }
            do {
                guard let model = self.model else { throw CocoaError(.userCancelled) }
                try await model.writeRemoteFilePromise(item.entry, from: item.deviceID, to: url)
                completion.call(nil)
            } catch {
                completion.call(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        return image
    }

    private static func typeIdentifier(for entry: RemoteEntry) -> String {
        if entry.kind == .directory { return UTType.folder.identifier }
        let ext = URL(fileURLWithPath: entry.name).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type.identifier }
        return UTType.data.identifier
    }
}
