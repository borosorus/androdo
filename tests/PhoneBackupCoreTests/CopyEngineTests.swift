import Foundation
import XCTest
@testable import PhoneBackupCore

final class CopyEngineTests: XCTestCase {
    func testPhoneToMacCopiesSelectedFolderIncludingEmptyDirectories() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let sourceRoot = try RemotePath("/sdcard/Pictures/Twitter")
        let empty = try sourceRoot.appending("Empty")
        let nested = try sourceRoot.appending("Album")
        let photo = try nested.appending("one.jpg")
        await remote.seed(RemoteEntry(path: sourceRoot, kind: .directory), on: fixture.device)
        await remote.seed(RemoteEntry(path: empty, kind: .directory), on: fixture.device)
        await remote.seed(RemoteEntry(path: nested, kind: .directory), on: fixture.device)
        await remote.seed(RemoteEntry(path: photo, kind: .file, size: Int64(fixture.bytes.count), modifiedAt: Date()),
                          on: fixture.device, data: fixture.bytes)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.phoneToMac(device: fixture.device, roots: [sourceRoot], destination: destination))
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(plan.directoryCount, 3)
        XCTAssertTrue(plan.conflicts.isEmpty)

        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        XCTAssertEqual(events.last?.phase, .completed)
        let copied = destination.appendingPathComponent("Twitter/Album/one.jpg")
        XCTAssertEqual(try Data(contentsOf: copied), fixture.bytes)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Twitter/Empty").path,
                                                      isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testMacToPhoneCopiesFolderWithoutCreatingRestorePoint() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("Twitter", isDirectory: true)
        let nested = source.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty", isDirectory: true),
                                                withIntermediateDirectories: true)
        try fixture.bytes.write(to: nested.appendingPathComponent("one.jpg"))
        let destination = try RemotePath("/sdcard/RestoreTrial")
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source], destination: destination))
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(plan.directoryCount, 3)

        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        XCTAssertEqual(events.last?.phase, .completed)
        let copied = try destination.appending("Twitter").appending("Album").appending("one.jpg")
        let localCopy = fixture.root.appendingPathComponent("phone-copy")
        try await remote.pull(from: copied, on: fixture.device, to: localCopy)
        XCTAssertEqual(try Data(contentsOf: localCopy), fixture.bytes)
        let points = try await fixture.store.restorePoints(in: fixture.repository.id)
        XCTAssertEqual(points.count, 0)
        let attempts = try await fixture.store.backupAttempts(in: fixture.repository.id)
        XCTAssertEqual(attempts.count, 0)
    }

    func testMacToPhoneCreatesMissingDestinationParentsForSingleFile() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("single.jpg")
        try fixture.bytes.write(to: source)
        let destination = try RemotePath("/sdcard/NewFolder/Nested")
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source], destination: destination))

        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        XCTAssertEqual(events.last?.phase, .completed)
        let target = try destination.appending("single.jpg")
        let output = fixture.root.appendingPathComponent("single-phone-copy")
        try await remote.pull(from: target, on: fixture.device, to: output)
        XCTAssertEqual(try Data(contentsOf: output), fixture.bytes)
    }

    func testMacToPhoneRequiresFreshExplicitReplacementApproval() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("new.jpg")
        try fixture.bytes.write(to: source)
        let destination = try RemotePath("/sdcard/RestoreTrial")
        let target = try destination.appending("new.jpg")
        let old = RemoteEntry(path: target, kind: .file, size: 3, modifiedAt: Date(timeIntervalSince1970: 1))
        await remote.seed(old, on: fixture.device, data: Data("old".utf8))
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)

        let firstPlan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source], destination: destination))
        let conflict = try XCTUnwrap(firstPlan.conflicts.first)
        XCTAssertTrue(conflict.replaceable)
        do {
            _ = try await engine.startCopy(firstPlan.id)
            XCTFail("Expected explicit replacement approval")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let reviewed = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source], destination: destination))
        let reviewedConflict = try XCTUnwrap(reviewed.conflicts.first)
        await remote.seed(RemoteEntry(path: target, kind: .file, size: 7, modifiedAt: Date()),
                          on: fixture.device, data: Data("changed".utf8))
        do {
            _ = try await engine.startCopy(reviewed.id, replacing: [reviewedConflict.id])
            XCTFail("Expected stale replacement approval to be rejected")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let preserved = fixture.root.appendingPathComponent("preserved-phone-file")
        try await remote.pull(from: target, on: fixture.device, to: preserved)
        XCTAssertEqual(try Data(contentsOf: preserved), Data("changed".utf8))
    }

    func testMacToPhoneCanExplicitlyReplaceMissingTargetWhenNoOverwriteIsUnavailable() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("new.jpg")
        try fixture.bytes.write(to: source)
        let destination = try RemotePath("/sdcard/RestoreTrial")
        let target = try destination.appending("new.jpg")
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let request = CopyRequest.macToPhone(device: fixture.device, sources: [source], destination: destination,
                                             replaceMissingTargets: [target])
        let plan = try await engine.planCopy(request)
        let conflict = try XCTUnwrap(plan.conflicts.first)
        XCTAssertEqual(conflict.observedIdentity, RestoreConflict.approvedMissingTargetIdentity)
        let operation = try await engine.startCopy(plan.id, replacing: [conflict.id])
        let events = await collectEvents(engine, operation)
        XCTAssertEqual(events.last?.phase, .completed)
        let result = await engine.result(for: operation)
        XCTAssertEqual(result?.items.map(\.state), [.publishedAndVerified])
    }

    func testDuplicatePhoneBasenamesAreRejectedBeforeTransfer() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let first = try RemotePath("/sdcard/First/same.jpg")
        let second = try RemotePath("/sdcard/Second/same.jpg")
        await remote.seed(RemoteEntry(path: first, kind: .file, size: 1), on: fixture.device, data: Data("1".utf8))
        await remote.seed(RemoteEntry(path: second, kind: .file, size: 1), on: fixture.device, data: Data("2".utf8))
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        do {
            _ = try await engine.planCopy(.phoneToMac(device: fixture.device, roots: [first, second], destination: destination))
            XCTFail("Expected duplicate target paths to be rejected")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMacToPhoneRejectsSymlinkSourceAndChangedSource() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let realFile = fixture.root.appendingPathComponent("real.jpg")
        try fixture.bytes.write(to: realFile)
        let symlink = fixture.root.appendingPathComponent("alias.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFile)
        let destination = try RemotePath("/sdcard/RestoreTrial")
        do {
            _ = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [symlink], destination: destination))
            XCTFail("Expected a selected symbolic link to be rejected")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [realFile], destination: destination))
        try Data("source changed after review".utf8).write(to: realFile)
        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        XCTAssertEqual(events.last?.phase, .failed)
        let target = try destination.appending("real.jpg")
        if case .missing = try await remote.inspectDestination(target, on: fixture.device) {} else {
            XCTFail("Changed source must not be published")
        }
    }

    func testPhoneToMacDoesNotFollowSelectedRemoteSymlink() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let link = try RemotePath("/sdcard/linked.jpg")
        await remote.seed(RemoteEntry(path: link, kind: .symbolicLink), on: fixture.device)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        do {
            _ = try await engine.planCopy(.phoneToMac(device: fixture.device, roots: [link], destination: destination))
            XCTFail("Expected a selected remote symbolic link to be rejected")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testPhoneToMacRejectsSourceBeneathSymlinkAncestor() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let link = try RemotePath("/sdcard/Link")
        let file = try RemotePath("/sdcard/Link/album/photo.jpg")
        await remote.seed(RemoteEntry(path: link, kind: .symbolicLink), on: fixture.device)
        await remote.seed(RemoteEntry(path: file, kind: .file, size: Int64(fixture.bytes.count)),
                          on: fixture.device, data: fixture.bytes)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        do {
            _ = try await engine.planCopy(.phoneToMac(device: fixture.device, roots: [file], destination: destination))
            XCTFail("Expected a symlinked source ancestor to be rejected")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testPhoneToMacCannotWriteIntoSiblingManagedRepository() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = try RemotePath("/sdcard/photo.jpg")
        await remote.seed(RemoteEntry(path: source, kind: .file, size: 1), on: fixture.device, data: Data("x".utf8))
        let siblingRepository = fixture.root.appendingPathComponent("PhoneBackup/another-device", isDirectory: true)
        try FileManager.default.createDirectory(at: siblingRepository, withIntermediateDirectories: true)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        do {
            _ = try await engine.planCopy(.phoneToMac(device: fixture.device, roots: [source],
                                                      destination: siblingRepository))
            XCTFail("Expected all destinations inside the managed repository root to be rejected")
        } catch let error as EngineError {
            guard case .repositoryIO = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCopyRejectsDirectoryRemovedAfterPlanning() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source],
                                                         destination: try RemotePath("/sdcard/RestoreTrial")))
        try FileManager.default.removeItem(at: source)

        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        XCTAssertEqual(events.last?.phase, .failed)
        if case .missing = try await remote.inspectDestination(try RemotePath("/sdcard/RestoreTrial/Empty"),
                                                               on: fixture.device) {} else {
            XCTFail("Removed source directory must not be reported as copied")
        }
    }

    func testUnexpectedPublicationErrorReportsPartialOutputsAccurately() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let destination = try RemotePath("/sdcard/Batch")
        var sources: [URL] = []
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            let url = fixture.root.appendingPathComponent(name)
            try fixture.bytes.write(to: url)
            sources.append(url)
        }
        await remote.failNextPublicationWithoutEngineError(at: try destination.appending("b.jpg"))
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: sources, destination: destination))

        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        let result = await engine.result(for: operation)
        XCTAssertEqual(events.last?.phase, .incomplete)
        XCTAssertEqual(result?.items.map(\.state), [.publishedAndVerified, .failed, .skipped])
        let first = fixture.root.appendingPathComponent("published-a")
        try await remote.pull(from: try destination.appending("a.jpg"), on: fixture.device, to: first)
        XCTAssertEqual(try Data(contentsOf: first), fixture.bytes)
        if case .missing = try await remote.inspectDestination(try destination.appending("c.jpg"), on: fixture.device) {} else {
            XCTFail("Items after the failure must remain untouched")
        }
    }

    func testCopyReportsPublishedButUnverifiedDestination() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("photo.jpg")
        try fixture.bytes.write(to: source)
        let destination = try RemotePath("/sdcard/Batch")
        let target = try destination.appending("photo.jpg")
        await remote.reportNextPublicationUnverified(at: target)
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source], destination: destination))

        let operation = try await engine.startCopy(plan.id)
        let events = await collectEvents(engine, operation)
        let result = await engine.result(for: operation)
        XCTAssertEqual(events.last?.phase, .incomplete)
        XCTAssertEqual(result?.items.map(\.state), [.publishedUnverified])
    }

    func testCopyCanBeCancelledDuringLocalStaging() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.device, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let source = fixture.root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: source.path, contents: Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 256 * 1024 * 1024)
        try handle.close()
        let destination = try RemotePath("/sdcard/Batch")
        let engine = DefaultCopyEngine(remote: remote, repositories: fixture.store)
        let plan = try await engine.planCopy(.macToPhone(device: fixture.device, sources: [source], destination: destination))

        let operation = try await engine.startCopy(plan.id)
        try await Task.sleep(for: .milliseconds(10))
        await engine.cancel(operation)
        let events = await collectEvents(engine, operation)
        let result = await engine.result(for: operation)
        XCTAssertEqual(events.last?.phase, .cancelled)
        XCTAssertEqual(result?.items.map(\.state), [.cancelled])
        if case .missing = try await remote.inspectDestination(try destination.appending("large.bin"), on: fixture.device) {} else {
            XCTFail("Cancelled local staging must not publish a destination")
        }
    }

    private func makeFixture() async throws -> (root: URL, store: FakeBackupRepositoryStore,
                                                  repository: BackupRepositoryInfo, device: DeviceID, bytes: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let device = try DeviceID(serial: "copy-engine")
        let repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/device"),
                                              deviceID: device, displayName: "Copy fixture")
        let store = FakeBackupRepositoryStore()
        await store.seed(repository: repository)
        return (root, store, repository, device, Data("verified copy bytes".utf8))
    }

    private func collectEvents(_ engine: DefaultCopyEngine, _ operation: OperationID) async -> [OperationEvent] {
        let stream = await engine.events(for: operation)
        var events: [OperationEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}
