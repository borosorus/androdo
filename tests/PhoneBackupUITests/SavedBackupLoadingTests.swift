import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class SavedBackupLoadingTests: XCTestCase {
    func testLateSavedFileFailureCannotReplaceAnotherSnapshotAndNeverQueriesPhone() async throws {
        let fixture = try SavedFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        await fixture.store.pauseEntryReadsForTesting(point: fixture.a.id)
        let oldRead = Task { await fixture.model.selectRestorePoint(fixture.a) }
        await fixture.store.waitForPausedEntryRead(point: fixture.a.id)
        XCTAssertTrue(fixture.model.isLoadingRestorePoint)
        XCTAssertNil(fixture.model.restorePointError)
        await fixture.model.selectRestorePoint(fixture.b)
        await fixture.store.resumeEntryReadsForTesting(point: fixture.a.id, failing: true)
        await oldRead.value
        XCTAssertEqual(fixture.model.selectedRestorePoint?.id, fixture.b.id)
        XCTAssertEqual(fixture.model.restoreEntries.map(\.path), [try RemotePath("/sdcard/B")])
        XCTAssertFalse(fixture.model.isLoadingRestorePoint)
        XCTAssertNil(fixture.model.restorePointError)
        XCTAssertNil(fixture.model.errorMessage)
        let reads = await fixture.remote.recordedChildrenCalls(on: fixture.device.id)
        XCTAssertTrue(reads.isEmpty)
    }

    func testEmptySavedContentsAreDifferentFromReadFailureAndRetryRecovers() async throws {
        let fixture = try SavedFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        await fixture.model.selectRestorePoint(fixture.a)
        XCTAssertTrue(fixture.model.restoreEntries.isEmpty)
        XCTAssertNil(fixture.model.restorePointError)
        await fixture.store.failNextEntryReadForTesting(point: fixture.a.id)
        await fixture.model.selectRestorePoint(fixture.a)
        XCTAssertNotNil(fixture.model.restorePointError)
        XCTAssertFalse(fixture.model.isLoadingRestorePoint)
        await fixture.model.selectRestorePoint(fixture.a)
        XCTAssertNil(fixture.model.restorePointError)
        XCTAssertTrue(fixture.model.restoreEntries.isEmpty)
    }
}

@MainActor
private struct SavedFixture {
    let root: URL
    let a = RestorePoint(createdAt: Date(timeIntervalSince1970: 10), state: .completed, entryCount: 0, totalBytes: 0)
    let b = RestorePoint(createdAt: Date(timeIntervalSince1970: 20), state: .completed, entryCount: 1, totalBytes: 0)
    let device: AndroidDevice
    let repository: BackupRepositoryInfo
    let remote: FakeDeviceTransport
    let store = FakeBackupRepositoryStore()
    let model: AppModel
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        device = AndroidDevice(id: try DeviceID(serial: "saved-fixture"), state: .device)
        repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/fixture"), deviceID: device.id, displayName: "Fixture")
        remote = FakeDeviceTransport(devices: [device])
        suite = "AndrodoSavedTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: remote, remoteAccess: remote),
                         preferences: AppPreferences(defaults: defaults), loadOnStart: false)
    }
    func prepare() async {
        await store.seed(repository: repository, restorePoints: [a, b], entries: [a.id: [], b.id: [BackupEntry(path: try! RemotePath("/sdcard/B"), kind: .directory, size: 0, modifiedAt: nil, contentHash: nil)]])
        await model.chooseBackupLocation(root)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
