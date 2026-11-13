import Foundation
import XCTest
@testable import PhoneBackupCore

final class RestoreEngineTests: XCTestCase {
    func testLocalRestorePreservesSelectedSubtreeAndEmptyDirectories() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.base],
                                     target: .localFolder(destination, sourceBase: fixture.base))

        let plan = try await engine.planRestore(request)
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(plan.directoryCount, 2)
        XCTAssertTrue(plan.conflicts.isEmpty)
        let operation = try await engine.startRestore(plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .completed)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("photo.jpg")), fixture.bytes)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Empty").path,
                                                      isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let result = await engine.result(for: operation)
        XCTAssertEqual(result?.items.filter { $0.state == .publishedAndVerified }.count, 3)
    }

    func testPhoneRestoreMapsToAlternateFolderAndVerifiesPublishedBytes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.repository.deviceID, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let destination = try RemotePath("/sdcard/RestoreTrial")
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store, remote: remote)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .phoneFolder(destination, sourceBase: fixture.base))

        let plan = try await engine.planRestore(request)
        XCTAssertEqual(plan.mappings.first?.destination, .phone(try destination.appending("photo.jpg")))
        let operation = try await engine.startRestore(plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .completed)
        let output = fixture.root.appendingPathComponent("remote-copy")
        try await remote.pull(from: try destination.appending("photo.jpg"), on: device.id, to: output)
        XCTAssertEqual(try Data(contentsOf: output), fixture.bytes)
    }

    func testPhoneRestoreRejectsSourceBaseThatDoesNotContainSelection() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.repository.deviceID, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let destination = try RemotePath("/sdcard/RestoreTrial")
        let unrelatedBase = try RemotePath("/sdcard/Other")
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store, remote: remote)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .phoneFolder(destination, sourceBase: unrelatedBase))

        do {
            _ = try await engine.planRestore(request)
            XCTFail("Expected an unrelated source base to be rejected")
        } catch let error as EngineError {
            guard case .invalidRemotePath = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLocalRestoreReportsPartialBatchFailureAndKeepsPublishedFiles() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstPath = try fixture.base.appending("a.jpg")
        let secondPath = try fixture.base.appending("z.jpg")
        let firstBytes = Data("first verified file".utf8)
        let secondBytes = Data("second file will become unavailable".utf8)
        let firstSource = fixture.root.appendingPathComponent("first-source")
        let secondSource = fixture.root.appendingPathComponent("second-source")
        try firstBytes.write(to: firstSource)
        try secondBytes.write(to: secondSource)
        let first = try await fixture.store.importFile(from: firstSource, expectedSize: Int64(firstBytes.count),
                                                       into: fixture.repository.id)
        let second = try await fixture.store.importFile(from: secondSource, expectedSize: Int64(secondBytes.count),
                                                        into: fixture.repository.id)
        let point = try await fixture.store.publish(
            RestorePointManifest(selection: BackupSelection(scope: .selected([firstPath, secondPath])), entries: [
                BackupEntry(path: firstPath, kind: .file, size: first.size, modifiedAt: nil, contentHash: first.sha256),
                BackupEntry(path: secondPath, kind: .file, size: second.size, modifiedAt: nil, contentHash: second.sha256),
            ]), in: fixture.repository.id
        )
        let destination = fixture.root.appendingPathComponent("partial-export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: point.id,
                                     selectedRoots: [firstPath, secondPath],
                                     target: .localFolder(destination, sourceBase: fixture.base))
        let plan = try await engine.planRestore(request)
        await fixture.store.removeObjectForTesting(second, in: fixture.repository.id)

        let operation = try await engine.startRestore(plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        let maybeResult = await engine.result(for: operation)
        let result = try XCTUnwrap(maybeResult)
        XCTAssertEqual(events.last?.phase, .incomplete)
        XCTAssertEqual(result.items.map(\.state), [.publishedAndVerified, .failed])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("a.jpg")), firstBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("z.jpg").path))
    }

    func testPhoneRestoreReportsPublishedButUnverifiedItem() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.repository.deviceID, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let destination = try RemotePath("/sdcard/RestoreTrial")
        let targetFile = try destination.appending("photo.jpg")
        await remote.reportNextPublicationUnverified(at: targetFile)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store, remote: remote)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .phoneFolder(destination, sourceBase: fixture.base))
        let plan = try await engine.planRestore(request)

        let operation = try await engine.startRestore(plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        let maybeResult = await engine.result(for: operation)
        let result = try XCTUnwrap(maybeResult)
        XCTAssertEqual(events.last?.phase, .incomplete)
        XCTAssertEqual(result.items.map(\.state), [.publishedUnverified])
        let output = fixture.root.appendingPathComponent("published-unverified")
        try await remote.pull(from: targetFile, on: device.id, to: output)
        XCTAssertEqual(try Data(contentsOf: output), fixture.bytes)
    }

    func testLocalRestoreCancellationReportsUnfinishedItemsWithoutPublishing() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("cancelled-export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        await fixture.store.delayStagingForTesting(.seconds(30))
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .localFolder(destination, sourceBase: fixture.base))
        let plan = try await engine.planRestore(request)

        let operation = try await engine.startRestore(plan.id)
        await engine.cancel(operation)
        let events = await collectEvents(from: engine, operation: operation)
        let maybeResult = await engine.result(for: operation)
        let result = try XCTUnwrap(maybeResult)
        XCTAssertEqual(events.last?.phase, .cancelled)
        XCTAssertEqual(result.items.map(\.state), [.cancelled])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("photo.jpg").path))
    }

    func testReplacementMustMatchTheReviewedDestinationIdentity() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("photo.jpg")
        try Data("old".utf8).write(to: target)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .localFolder(destination, sourceBase: fixture.base))

        let firstPlan = try await engine.planRestore(request)
        let conflict = try XCTUnwrap(firstPlan.conflicts.first)
        XCTAssertTrue(conflict.replaceable)
        do {
            _ = try await engine.startRestore(firstPlan.id)
            XCTFail("Expected explicit replacement approval")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let reviewedPlan = try await engine.planRestore(request)
        let reviewedConflict = try XCTUnwrap(reviewedPlan.conflicts.first)
        try Data("changed after review".utf8).write(to: target)
        do {
            _ = try await engine.startRestore(reviewedPlan.id, replacing: [reviewedConflict.id])
            XCTFail("Expected changed destination identity to invalidate approval")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("changed after review".utf8))

        let finalPlan = try await engine.planRestore(request)
        let finalConflict = try XCTUnwrap(finalPlan.conflicts.first)
        let operation = try await engine.startRestore(finalPlan.id, replacing: [finalConflict.id])
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(try Data(contentsOf: target), fixture.bytes)
    }

    func testLocalRestorePinsResolvedSymlinkRoot() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let actual = fixture.root.appendingPathComponent("long/deeper/actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .localFolder(alias, sourceBase: fixture.base))

        let plan = try await engine.planRestore(request)
        XCTAssertEqual(plan.mappings.first?.destination, .local(actual.appendingPathComponent("photo.jpg")))
        let operation = try await engine.startRestore(plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .completed)
        XCTAssertEqual(try Data(contentsOf: actual.appendingPathComponent("photo.jpg")), fixture.bytes)
    }

    func testReplacingChosenLocalRootAfterPlanningInvalidatesPlan() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        let replacement = fixture.root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file],
                                     target: .localFolder(destination, sourceBase: fixture.base))
        let plan = try await engine.planRestore(request)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: replacement)

        do {
            _ = try await engine.startRestore(plan.id)
            XCTFail("Expected the changed destination root to invalidate the plan")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.appendingPathComponent("photo.jpg").path))
    }

    func testMappedExportCannotWriteIntoManagedRepository() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("repository-name")
        let bytes = Data("must not enter backup repository".utf8)
        try bytes.write(to: source)
        let reference = try await fixture.store.importFile(from: source, expectedSize: Int64(bytes.count),
                                                           into: fixture.repository.id)
        let managedPath = try fixture.base.appending("PhoneBackup")
        let point = try await fixture.store.publish(
            RestorePointManifest(selection: BackupSelection(scope: .selected([managedPath])), entries: [
                BackupEntry(path: managedPath, kind: .file, size: reference.size, modifiedAt: nil,
                            contentHash: reference.sha256),
            ]), in: fixture.repository.id
        )
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: point.id,
                                     selectedRoots: [managedPath], target: .localFolder(fixture.root, sourceBase: fixture.base))

        do {
            _ = try await engine.planRestore(request)
            XCTFail("Expected managed repository destination to be rejected")
        } catch let error as EngineError {
            guard case .repositoryIO = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("PhoneBackup").path))
    }

    func testCaseAliasInAncestorBlocksLocalRestorePlan() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstPath = try fixture.base.appending("Foo").appending("a.jpg")
        let secondPath = try fixture.base.appending("foo").appending("b.jpg")
        let firstSource = fixture.root.appendingPathComponent("first")
        let secondSource = fixture.root.appendingPathComponent("second")
        try Data("one".utf8).write(to: firstSource)
        try Data("two".utf8).write(to: secondSource)
        let first = try await fixture.store.importFile(from: firstSource, expectedSize: 3, into: fixture.repository.id)
        let second = try await fixture.store.importFile(from: secondSource, expectedSize: 3, into: fixture.repository.id)
        let point = try await fixture.store.publish(
            RestorePointManifest(selection: BackupSelection(scope: .selected([firstPath, secondPath])), entries: [
                BackupEntry(path: firstPath, kind: .file, size: first.size, modifiedAt: nil, contentHash: first.sha256),
                BackupEntry(path: secondPath, kind: .file, size: second.size, modifiedAt: nil, contentHash: second.sha256),
            ]), in: fixture.repository.id
        )
        let destination = fixture.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store)
        let request = RestoreRequest(repository: fixture.repository.id, point: point.id,
                                     selectedRoots: [firstPath, secondPath],
                                     target: .localFolder(destination, sourceBase: fixture.base))

        let plan = try await engine.planRestore(request)
        XCTAssertTrue(plan.conflicts.contains { $0.kind == .caseOrUnicodeAlias })
        do {
            _ = try await engine.startRestore(plan.id)
            XCTFail("Expected ancestor case alias to block the batch")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMissingAndroidTargetCanBeReplannedWithExplicitReplacementPolicy() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let device = AndroidDevice(id: fixture.repository.deviceID, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let targetFolder = try RemotePath("/sdcard/RestoreTrial")
        let targetFile = try targetFolder.appending("photo.jpg")
        let engine = DefaultRestoreEngine(repositoryStore: fixture.store, remote: remote)
        let request = RestoreRequest(repository: fixture.repository.id, point: fixture.point.id,
                                     selectedRoots: [fixture.file], target: .phoneFolder(targetFolder, sourceBase: fixture.base),
                                     replaceMissingPhoneTargets: [targetFile])

        let plan = try await engine.planRestore(request)
        let conflict = try XCTUnwrap(plan.conflicts.first)
        XCTAssertEqual(conflict.observedIdentity, RestoreConflict.approvedMissingTargetIdentity)
        let operation = try await engine.startRestore(plan.id, replacing: [conflict.id])
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .completed)
    }

    private func makeFixture() async throws -> (root: URL, store: FakeBackupRepositoryStore,
                                                repository: BackupRepositoryInfo, point: RestorePoint,
                                                base: RemotePath, file: RemotePath, bytes: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let deviceID = try DeviceID(serial: "restore-engine")
        let repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/device-engine"),
                                              deviceID: deviceID, displayName: "Test device")
        let store = FakeBackupRepositoryStore()
        await store.seed(repository: repository)
        let base = try RemotePath("/sdcard/Pictures")
        let empty = try base.appending("Empty")
        let file = try base.appending("photo.jpg")
        let bytes = Data("verified image bytes".utf8)
        let source = root.appendingPathComponent("source.jpg")
        try bytes.write(to: source)
        let reference = try await store.importFile(from: source, expectedSize: Int64(bytes.count), into: repository.id)
        let point = try await store.publish(
            RestorePointManifest(selection: BackupSelection(scope: .selected([base])), entries: [
                BackupEntry(path: base, kind: .directory, size: 0, modifiedAt: nil, contentHash: nil),
                BackupEntry(path: empty, kind: .directory, size: 0, modifiedAt: nil, contentHash: nil),
                BackupEntry(path: file, kind: .file, size: reference.size, modifiedAt: Date(timeIntervalSince1970: 100),
                            contentHash: reference.sha256),
            ]), in: repository.id
        )
        return (root, store, repository, point, base, file, bytes)
    }

    private func collectEvents(from engine: DefaultRestoreEngine, operation: OperationID) async -> [OperationEvent] {
        let stream = await engine.events(for: operation)
        var result: [OperationEvent] = []
        for await event in stream { result.append(event) }
        return result
    }
}
