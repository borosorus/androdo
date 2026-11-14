import Foundation
import XCTest
@testable import PhoneBackupCore

final class PhoneBackupCoreTests: XCTestCase {
    func testRemotePathRejectsTraversalAndNormalizesComponents() throws {
        XCTAssertEqual(try RemotePath("/sdcard/Pictures").description, "/sdcard/Pictures")
        XCTAssertThrowsError(try RemotePath("/sdcard/../private"))
        XCTAssertThrowsError(try RemotePath("/sdcard//Pictures"))
        XCTAssertThrowsError(try RemotePath("relative/path"))
        XCTAssertThrowsError(try JSONDecoder().decode(DeviceID.self, from: Data("\"\"".utf8)))
    }

    func testRemotePathIdentityPreservesUnicodeNormalizationBytes() throws {
        let composed = try RemotePath("/sdcard/é.jpg")
        let decomposed = try RemotePath("/sdcard/e\u{301}.jpg")

        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
        XCTAssertNotEqual(
            try JSONDecoder().decode(RemotePath.self, from: JSONEncoder().encode(composed)),
            try JSONDecoder().decode(RemotePath.self, from: JSONEncoder().encode(decomposed))
        )
        XCTAssertEqual(
            BackupSelection(scope: .selected([decomposed, composed])).scope,
            .selected([composed, decomposed].sorted(by: RemotePath.bytewiseLess))
        )
    }

    func testSelectionMakesSharedStorageScopeExplicit() throws {
        let empty = BackupSelection()
        let all = BackupSelection(scope: .allSharedStorage)
        let partial = BackupSelection(scope: .allSharedStorage, excludedRoots: [try RemotePath("/sdcard/Android/data")])

        XCTAssertFalse(empty.selectsEverything)
        XCTAssertTrue(all.selectsEverything)
        XCTAssertFalse(partial.selectsEverything)
    }

    func testModelsRoundTripThroughCodable() throws {
        let deviceID = try DeviceID(value: "test-serial")
        let device = fixtureDevice(id: deviceID, state: .device, model: "Pixel", product: "pixel")
        let path = try RemotePath("/sdcard/DCIM/photo.jpg")
        let event = OperationEvent(
            operationID: OperationID(),
            phase: .transferring,
            progress: OperationProgress(completedItems: 1, totalItems: 2, completedBytes: 4, totalBytes: 8),
            warnings: [OperationWarning(code: .inaccessiblePath, path: path, message: "Access denied")]
        )

        let decodedDevice = try JSONDecoder().decode(AndroidDevice.self, from: JSONEncoder().encode(device))
        XCTAssertEqual(decodedDevice.id, device.id)
        XCTAssertEqual(decodedDevice.state, device.state)
        XCTAssertTrue(decodedDevice.sessions.isEmpty, "ADB routes must never be encoded")
        XCTAssertEqual(try JSONDecoder().decode(OperationEvent.self, from: JSONEncoder().encode(event)), event)
        XCTAssertTrue(EngineError.inaccessiblePath(path).recoveryActions.contains(.chooseAccessiblePaths))
        XCTAssertEqual(
            EngineError.destinationConflict(TransferConflict(destination: "/path", kind: .fileExists)).recoveryActions,
            [.allowReplacement]
        )
        XCTAssertEqual(
            EngineError.destinationConflict(TransferConflict(destination: "/path", kind: .unsafePath)).recoveryActions,
            [.chooseDestination]
        )
        XCTAssertThrowsError(try JSONDecoder().decode(RemotePath.self, from: Data("\"/sdcard/../private\"".utf8)))
    }

    func testOperationPhasesAllowOnlyForwardTransitions() {
        XCTAssertTrue(OperationPhase.scanning.canTransition(to: .planning))
        XCTAssertTrue(OperationPhase.planning.canTransition(to: .transferring))
        XCTAssertTrue(OperationPhase.transferring.canTransition(to: .verifying))
        XCTAssertTrue(OperationPhase.verifying.canTransition(to: .committing))
        XCTAssertTrue(OperationPhase.committing.canTransition(to: .completed))
        XCTAssertFalse(OperationPhase.completed.canTransition(to: .transferring))
        XCTAssertFalse(OperationPhase.transferring.canTransition(to: .scanning))
    }

    func testFakeTransportListsOnlyImmediateChildrenInStableOrder() async throws {
        let deviceID = try DeviceID(value: "fake-1")
        let device = fixtureDevice(id: deviceID, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let root = try RemotePath("/sdcard")
        let folder = try root.appending("Pictures")
        let nestedFile = try folder.appending("photo.jpg")
        await transport.seed(RemoteEntry(path: nestedFile, kind: .file), on: deviceID)
        await transport.seed(RemoteEntry(path: folder, kind: .directory), on: deviceID)

        let connected = try await transport.connectedDevices()
        let session = try XCTUnwrap(connected.devices.first?.preferredSession)
        let rootChildren = try await transport.children(of: root, on: session)
        let folderChildren = try await transport.children(of: folder, on: session)
        XCTAssertEqual(connected.devices, [device])
        XCTAssertEqual(rootChildren.map(\.path), [folder])
        XCTAssertEqual(folderChildren.map(\.path), [nestedFile])
    }

    func testFakeTransportCopiesBytesBothDirections() async throws {
        let deviceID = try DeviceID(value: "fake-1")
        let device = fixtureDevice(id: deviceID, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let session = try XCTUnwrap(device.preferredSession)
        let remotePath = try RemotePath("/sdcard/Documents/note.txt")
        let original = Data("round trip".utf8)
        await transport.seed(RemoteEntry(path: remotePath, kind: .file, size: Int64(original.count)), on: deviceID, data: original)
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: localURL) }

        try await transport.pull(from: remotePath, on: session, to: localURL)
        XCTAssertEqual(try Data(contentsOf: localURL), original)

        try Data("updated".utf8).write(to: localURL)
        try await transport.push(from: localURL, to: remotePath, on: session)
        let secondCopy = localURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: secondCopy) }
        try await transport.pull(from: remotePath, on: session, to: secondCopy)
        XCTAssertEqual(try Data(contentsOf: secondCopy), Data("updated".utf8))
    }

    func testFakeRepositoryListsRestorePointsAndImmediateEntries() async throws {
        let deviceID = try DeviceID(value: "fake-1")
        let repository = BackupRepositoryInfo(location: URL(fileURLWithPath: "/tmp/PhoneBackup"), deviceID: deviceID, displayName: "Phone")
        let earlier = RestorePoint(createdAt: Date(timeIntervalSince1970: 1), state: .completed, entryCount: 1, totalBytes: 3)
        let later = RestorePoint(createdAt: Date(timeIntervalSince1970: 2), state: .completed, entryCount: 2, totalBytes: 7)
        let folder = try RemotePath("/sdcard/Pictures")
        let image = try folder.appending("photo.jpg")
        let note = try RemotePath("/sdcard/Documents/note.txt")
        let store = FakeBackupRepositoryStore()
        await store.seed(
            repository: repository,
            restorePoints: [earlier, later],
            entries: [later.id: [
                BackupEntry(path: image, kind: .file, size: 4, modifiedAt: nil, contentHash: "hash"),
                BackupEntry(path: note, kind: .file, size: 3, modifiedAt: nil, contentHash: "hash-2"),
            ]]
        )

        let repositories = try await store.repositories()
        let restorePoints = try await store.restorePoints(in: repository.id)
        let visibleEntries = try await store.entries(in: repository.id, point: later.id, below: folder)
        XCTAssertEqual(repositories, [repository])
        XCTAssertEqual(restorePoints, [later, earlier])
        XCTAssertEqual(visibleEntries.map(\.path), [image])
    }
}
