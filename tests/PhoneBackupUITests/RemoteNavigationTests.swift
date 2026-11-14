import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class RemoteNavigationTests: XCTestCase {
    private let id = try! DeviceID(value: "navigation-fixture")

    func testConcurrentInitialOpensShareOneShallowRequest() async throws {
        let remote = ControlledDirectoryAccess()
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        let root = RemoteBrowserModel.sharedStorage
        let first = Task { await browser.openRoot() }
        let second = Task { await browser.openRoot() }
        let third = Task { await browser.openRoot() }
        await remote.waitForRequest(root)
        await remote.finish(root, entries: [])
        await first.value; await second.value; await third.value
        let calls = await remote.calls
        XCTAssertEqual(calls, [root])
        XCTAssertTrue(browser.hasOpenedRoot)
        XCTAssertFalse(browser.isLoading)
    }

    func testSupersededRequestIsCancelledAndLateFailureCannotReplaceNewFolder() async throws {
        let remote = ControlledDirectoryAccess(ignoreCancellation: true)
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        let a = try RemotePath("/sdcard/A")
        let b = try RemotePath("/sdcard/B")
        let old = Task { await browser.navigate(to: a) }
        await remote.waitForRequest(a)
        let current = Task { await browser.navigate(to: b) }
        await remote.waitForRequest(b)
        XCTAssertEqual(browser.displayedDirectory, b)
        XCTAssertTrue(browser.entries.isEmpty)
        await remote.finish(b, entries: [])
        await current.value
        await remote.fail(a)
        await old.value
        XCTAssertEqual(browser.currentDirectory, b)
        XCTAssertNil(browser.errorMessage)
        XCTAssertFalse(browser.isLoading)
        let cancellations = await remote.cancellations
        XCTAssertTrue(cancellations.contains(a))
    }

    func testExplicitCancelRestoresThePreviousListing() async throws {
        let remote = ControlledDirectoryAccess()
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        let root = RemoteBrowserModel.sharedStorage
        let folder = try root.appending("A")
        let rootTask = Task { await browser.openRoot() }
        await remote.waitForRequest(root)
        await remote.finish(root, entries: [RemoteEntry(path: folder, kind: .directory)])
        await rootTask.value
        let pending = Task { await browser.navigate(to: folder) }
        await remote.waitForRequest(folder)
        browser.cancelNavigation()
        await pending.value
        XCTAssertEqual(browser.currentDirectory, root)
        XCTAssertEqual(browser.entries.map(\.path), [folder])
        XCTAssertFalse(browser.isLoading)
        XCTAssertNil(browser.errorMessage)
    }

    func testBackForwardUsesVisitedCacheWhileRefreshAndInvalidationReadAgain() async throws {
        let remote = FakeDeviceTransport(devices: [fixtureDevice(id: id, state: .device)])
        let root = RemoteBrowserModel.sharedStorage
        let folder = try root.appending("A")
        await remote.seed(RemoteEntry(path: folder, kind: .directory), on: id)
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        await browser.openRoot()
        await browser.navigate(to: folder)
        await browser.goBack()
        XCTAssertEqual(browser.currentDirectory, root)
        XCTAssertTrue(browser.isShowingCachedContents)
        await browser.goForward()
        await browser.refresh()
        var calls = await remote.recordedChildrenCalls(on: id)
        XCTAssertEqual(calls, [root, folder, folder])
        browser.invalidateVisitedFolders()
        await browser.goBack()
        calls = await remote.recordedChildrenCalls(on: id)
        XCTAssertEqual(calls, [root, folder, folder, root])
    }

    func testCachedNavigationWhileAnotherFolderLoadsCannotRestoreSuspendedRows() async throws {
        let remote = ControlledDirectoryAccess()
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        let root = RemoteBrowserModel.sharedStorage
        let a = try root.appending("A")
        let b = try a.appending("B")
        let c = try b.appending("C")
        func visit(_ path: RemotePath, entries: [RemoteEntry]) async {
            let task = Task { await browser.navigate(to: path) }
            await remote.waitForRequest(path)
            await remote.finish(path, entries: entries)
            await task.value
        }
        await visit(a, entries: [RemoteEntry(path: b, kind: .directory)])
        await visit(b, entries: [RemoteEntry(path: c, kind: .directory)])
        let pending = Task { await browser.navigate(to: c) }
        await remote.waitForRequest(c)
        await browser.navigate(to: a)
        await pending.value
        browser.cancelNavigation()
        XCTAssertEqual(browser.currentDirectory, a)
        XCTAssertEqual(browser.entries.map(\.path), [b])
        let next = Task { await browser.navigate(to: c) }
        await remote.waitForRequest(c)
        browser.cancelNavigation()
        await next.value
        XCTAssertEqual(browser.currentDirectory, a)
        XCTAssertEqual(browser.entries.map(\.path), [b])
    }

    func testLeavingAFailedFolderPreservesTheErrorAndRootFailureIsNotOpened() async throws {
        let remote = FakeDeviceTransport(devices: [fixtureDevice(id: id, state: .device)])
        let root = RemoteBrowserModel.sharedStorage
        await remote.seed(RemoteEntry(path: root, kind: .directory), on: id)
        await remote.failNext(.inaccessiblePath(root), operation: .children, at: root, on: id)
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        await browser.openRoot()
        let error = browser.errorMessage
        XCTAssertNotNil(error)
        XCTAssertFalse(browser.hasOpenedRoot)
        browser.cancelNavigation() // Same action as leaving Phone Files.
        XCTAssertEqual(browser.errorMessage, error)
        XCTAssertFalse(browser.hasOpenedRoot)
    }

    func testOversizedRefreshEvictsAnOlderCachedListing() async throws {
        let root = RemoteBrowserModel.sharedStorage
        let folder = try root.appending("Folder")
        let remote = ImmediateDirectoryAccess()
        await remote.set([RemoteEntry(path: folder, kind: .directory)], at: root)
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        await browser.openRoot()
        let large = try (0..<20_001).map { RemoteEntry(path: try root.appending("file-\($0).txt"), kind: .file, size: 0) }
        await remote.set(large, at: root)
        await browser.refresh()
        await browser.navigate(to: folder)
        await browser.goBack()
        XCTAssertEqual(browser.entries.count, large.count)
        let calls = await remote.calls
        XCTAssertEqual(calls.filter { $0 == root }.count, 3)
    }

    func testNavigationAndRefreshKeepSelectionInsideVisibleRows() async throws {
        let remote = FakeDeviceTransport(devices: [fixtureDevice(id: id, state: .device)])
        let root = RemoteBrowserModel.sharedStorage
        let folder = try root.appending("A")
        let file = try folder.appending("file.txt")
        await remote.seed(RemoteEntry(path: file, kind: .file, size: 1), on: id, data: Data([1]))
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        await browser.openRoot()
        browser.selection = [folder]
        await browser.navigate(to: folder)
        XCTAssertTrue(browser.selection.isEmpty)
        browser.selection = [root, file]
        await browser.refresh()
        XCTAssertEqual(browser.selection, [file])
        await remote.remove(file, on: id)
        await browser.refresh()
        XCTAssertTrue(browser.selection.isEmpty)
    }

    func testDeviceChangeDiscardsPendingResponseAndVisitedCache() async throws {
        let remote = ControlledDirectoryAccess(ignoreCancellation: true)
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(fixtureDevice(id: id, state: .device))
        let root = RemoteBrowserModel.sharedStorage
        let pending = Task { await browser.openRoot() }
        await remote.waitForRequest(root)
        browser.setDevice(nil)
        await remote.finish(root, entries: [RemoteEntry(path: try root.appending("old"), kind: .directory)])
        await pending.value
        XCTAssertTrue(browser.entries.isEmpty)
        XCTAssertFalse(browser.hasOpenedRoot)
        XCTAssertTrue(browser.history.isEmpty)
    }
}

private actor ControlledDirectoryAccess: RemoteFileAccess {
    private struct Pending {
        let token: UUID
        let continuation: CheckedContinuation<[RemoteEntry], any Error>
    }
    private var pending: [RemotePath: Pending] = [:]
    private var waiters: [RemotePath: [CheckedContinuation<Void, Never>]] = [:]
    private let ignoreCancellation: Bool
    private(set) var calls: [RemotePath] = []
    private(set) var cancellations: [RemotePath] = []

    init(ignoreCancellation: Bool = false) { self.ignoreCancellation = ignoreCancellation }

    func children(of path: RemotePath, on session: DeviceSession) async throws -> [RemoteEntry] {
        let token = UUID()
        calls.append(path)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[path] = Pending(token: token, continuation: continuation)
                (waiters.removeValue(forKey: path) ?? []).forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancel(path, token: token) }
        }
    }

    func waitForRequest(_ path: RemotePath) async {
        if pending[path] != nil { return }
        await withCheckedContinuation { waiters[path, default: []].append($0) }
    }
    func finish(_ path: RemotePath, entries: [RemoteEntry]) { pending.removeValue(forKey: path)?.continuation.resume(returning: entries) }
    func fail(_ path: RemotePath) { pending.removeValue(forKey: path)?.continuation.resume(throwing: EngineError.inaccessiblePath(path)) }
    private func cancel(_ path: RemotePath, token: UUID) {
        cancellations.append(path)
        guard !ignoreCancellation, pending[path]?.token == token else { return }
        pending.removeValue(forKey: path)?.continuation.resume(throwing: CancellationError())
    }
    func metadata(of path: RemotePath, on session: DeviceSession) async throws -> RemoteEntry { throw EngineError.missingPath(path) }
    func pull(from path: RemotePath, on session: DeviceSession, to localURL: URL) async throws { throw EngineError.missingPath(path) }
    func push(from localURL: URL, to path: RemotePath, on session: DeviceSession) async throws { throw EngineError.missingPath(path) }
}


private actor ImmediateDirectoryAccess: RemoteFileAccess {
    private var listings: [RemotePath: [RemoteEntry]] = [:]
    private(set) var calls: [RemotePath] = []
    func set(_ entries: [RemoteEntry], at path: RemotePath) { listings[path] = entries }
    func children(of path: RemotePath, on session: DeviceSession) async throws -> [RemoteEntry] { calls.append(path); return listings[path] ?? [] }
    func metadata(of path: RemotePath, on session: DeviceSession) async throws -> RemoteEntry { throw EngineError.missingPath(path) }
    func pull(from path: RemotePath, on session: DeviceSession, to localURL: URL) async throws { throw EngineError.missingPath(path) }
    func push(from localURL: URL, to path: RemotePath, on session: DeviceSession) async throws { throw EngineError.missingPath(path) }
}
