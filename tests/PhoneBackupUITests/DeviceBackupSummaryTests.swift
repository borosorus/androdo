import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class DeviceBackupSummaryTests: XCTestCase {
    func testOverviewRemainsBoundToDisplayedDeviceWhileLibraryBrowsesAnother() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        let complete = fixture.point(time: 10)
        let warning = OperationWarning(code: .inaccessiblePath, message: "Fixture omission")
        let omitted = fixture.point(time: 30, omissions: [warning])
        let incomplete = fixture.point(time: 20, state: .incomplete)
        let other = fixture.point(time: 100)
        await fixture.store.seed(repository: fixture.repository, restorePoints: [complete, omitted, incomplete])
        await fixture.store.seed(repository: fixture.otherRepository, restorePoints: [other])
        await fixture.model.refreshDevices()
        await fixture.model.chooseBackupLocation(fixture.root)
        await fixture.model.selectRepository(fixture.otherRepository.id)

        guard case .loaded(let summary) = fixture.model.deviceBackupSummary else { return XCTFail("Expected device history") }
        XCTAssertEqual(summary.latestComplete?.id, complete.id)
        XCTAssertEqual(summary.incompleteCount, 2)
        XCTAssertEqual(summary.latestIncomplete?.id, omitted.id)
        XCTAssertEqual(fixture.model.restorePoints, [other])
        let listed = await fixture.transport.recordedChildrenCalls(on: fixture.device.id)
        XCTAssertTrue(listed.isEmpty)
    }

    func testAbsentHistoryAndReadFailureAreDifferentAndRetryRecovers() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        await fixture.model.refreshDeviceBackupSummary()
        XCTAssertEqual(fixture.model.deviceBackupSummary, .noDevice)
        await fixture.model.refreshDevices()
        XCTAssertEqual(fixture.model.deviceBackupSummary, .noLocation)
        await fixture.model.chooseBackupLocation(fixture.root)
        XCTAssertEqual(fixture.model.deviceBackupSummary, .loaded(DeviceBackupSummary(points: [])))
        await fixture.store.seed(repository: fixture.repository)
        await fixture.model.chooseBackupLocation(fixture.root)
        XCTAssertEqual(fixture.model.deviceBackupSummary, .loaded(DeviceBackupSummary(points: [])))
        await fixture.store.failNextRestorePointReadForTesting(in: fixture.repository.id)
        await fixture.model.refreshDeviceBackupSummary()
        XCTAssertEqual(fixture.model.deviceBackupSummary, .unavailable)
        XCTAssertNil(fixture.model.errorMessage)
        await fixture.model.refreshDeviceBackupSummary()
        XCTAssertEqual(fixture.model.deviceBackupSummary, .loaded(DeviceBackupSummary(points: [])))
    }

    func testFailedRepositoryOpenStaysUnavailableUntilRetryReopensIt() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        let complete = fixture.point(time: 10)
        await fixture.store.seed(repository: fixture.repository, restorePoints: [complete])
        await fixture.model.refreshDevices()
        await fixture.store.failNextRepositoryOpenForTesting()
        await fixture.model.chooseBackupLocation(fixture.root)
        XCTAssertEqual(fixture.model.deviceBackupSummary, .unavailable)
        XCTAssertTrue(fixture.model.backupLocationNeedsAttention)

        await fixture.model.refreshDeviceBackupSummary()
        await fixture.model.refreshDevices()
        XCTAssertEqual(fixture.model.deviceBackupSummary, .unavailable)
        XCTAssertTrue(fixture.model.backupLocationNeedsAttention)

        await fixture.model.retryDeviceBackupSummary()
        guard case .loaded(let summary) = fixture.model.deviceBackupSummary else { return XCTFail("Expected reopened history") }
        XCTAssertEqual(summary.latestComplete?.id, complete.id)
        XCTAssertFalse(fixture.model.backupLocationNeedsAttention)
    }

    func testRetryAfterFailedStartupDiscoveryPreservesKnownRepositoryRecoveryGate() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        let preferences = fixture.preferences
        preferences.locationBookmark = try fixture.root.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        preferences.knownRepositoryIDs = [fixture.repository.id.id]
        await fixture.store.failNextRepositoryOpenForTesting()
        let model = AppModel(services: AppServices(repositoryStore: fixture.store, deviceTransport: fixture.transport),
                             preferences: preferences, loadOnStart: true)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (!model.requiresRepositoryRecoveryConfirmation || model.isBusy) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.requiresRepositoryRecoveryConfirmation)
        XCTAssertEqual(model.backupLocation, fixture.root)

        await model.retryDeviceBackupSummary()

        XCTAssertTrue(model.requiresRepositoryRecoveryConfirmation)
        XCTAssertTrue(model.backupLocationNeedsAttention)
        XCTAssertEqual(preferences.knownRepositoryIDs, [fixture.repository.id.id])
        XCTAssertEqual(model.deviceBackupSummary, .unavailable)

        await fixture.store.seed(repository: fixture.repository, restorePoints: [fixture.point(time: 10)])
        await model.retryDeviceBackupSummary()
        XCTAssertFalse(model.requiresRepositoryRecoveryConfirmation)
        XCTAssertFalse(model.backupLocationNeedsAttention)
        guard case .loaded(let summary) = model.deviceBackupSummary else { return XCTFail("Expected rediscovered original history") }
        XCTAssertNotNil(summary.latestComplete)
    }

    func testLateSuccessCannotReplaceSummaryAfterDeviceChanges() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        await fixture.store.seed(repository: fixture.repository, restorePoints: [fixture.point(time: 10)])
        await fixture.store.seed(repository: fixture.otherRepository, restorePoints: [fixture.point(time: 50)])
        await fixture.model.refreshDevices()
        await fixture.model.chooseBackupLocation(fixture.root)
        await fixture.store.pauseRestorePointReadsForTesting(in: fixture.repository.id)
        let oldRead = Task { await fixture.model.refreshDeviceBackupSummary() }
        await fixture.store.waitForPausedRestorePointRead(in: fixture.repository.id)
        await fixture.transport.setDevices([fixture.otherDevice])

        await fixture.model.refreshDevices()
        let expected = fixture.model.deviceBackupSummary
        await fixture.store.resumeRestorePointReadsForTesting(in: fixture.repository.id)
        await oldRead.value

        XCTAssertEqual(fixture.model.selectedDevice?.id, fixture.otherDevice.id)
        XCTAssertEqual(fixture.model.deviceBackupSummary, expected)
        guard case .loaded(let summary) = expected else { return XCTFail("Expected new device history") }
        XCTAssertEqual(summary.latestComplete?.createdAt, Date(timeIntervalSince1970: 50))
    }

    func testLateFailureCannotReplaceSummaryAfterDestinationChanges() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        await fixture.store.seed(repository: fixture.repository, restorePoints: [fixture.point(time: 10)])
        await fixture.model.refreshDevices()
        await fixture.model.chooseBackupLocation(fixture.root)
        await fixture.store.pauseRestorePointReadsForTesting(in: fixture.repository.id)
        let oldRead = Task { await fixture.model.refreshDeviceBackupSummary() }
        await fixture.store.waitForPausedRestorePointRead(in: fixture.repository.id)
        let newLocation = fixture.root.appendingPathComponent("another-location", isDirectory: true)
        try FileManager.default.createDirectory(at: newLocation, withIntermediateDirectories: true)
        await fixture.model.chooseBackupLocation(newLocation)
        await fixture.store.resumeRestorePointReadsForTesting(in: fixture.repository.id, failing: true)
        await oldRead.value

        XCTAssertEqual(fixture.model.deviceBackupSummary, .loaded(DeviceBackupSummary(points: [])))
        XCTAssertEqual(fixture.model.backupLocation, newLocation)
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testSuccessfulFakeBackupRefreshesDeviceHistory() async throws {
        let fixture = try SummaryFixture()
        defer { fixture.cleanup() }
        let folder = try RemotePath("/sdcard/Fixture")
        await fixture.transport.seed(RemoteEntry(path: try folder.appending("example.txt"), kind: .file, size: 3),
                                     on: fixture.device.id, data: Data([1, 2, 3]))
        await fixture.store.seed(repository: fixture.repository)
        await fixture.model.refreshDevices()
        await fixture.model.chooseBackupLocation(fixture.root)
        fixture.model.setBackupSelection(BackupSelection(scope: .selected([folder])))
        await fixture.model.reviewBackup()
        XCTAssertNotNil(fixture.model.backupPlan)
        await fixture.model.startBackup()
        let runningID = fixture.model.operationID
        fixture.model.clearStatus()
        XCTAssertNotNil(runningID)
        XCTAssertEqual(fixture.model.operationID, runningID)
        XCTAssertEqual(fixture.model.operationKind, .backup)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fixture.model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertEqual(fixture.model.operationKind, .backup)
        XCTAssertEqual(fixture.model.operationEvent?.phase, .completed)
        guard case .loaded(let summary) = fixture.model.deviceBackupSummary else { return XCTFail("Expected completed history") }
        XCTAssertEqual(summary.points.count, 1)
        XCTAssertNotNil(summary.latestComplete)
        XCTAssertEqual(summary.latestComplete?.entryCount, 2)
        fixture.model.clearStatus()
        XCTAssertNil(fixture.model.operationKind)
        XCTAssertNil(fixture.model.operationEvent)
        XCTAssertEqual(fixture.model.deviceBackupSummary, .loaded(summary))
    }

    func testReadinessChoosesTheNextPrerequisiteAndRespectsBusyState() throws {
        let device = fixtureDevice(id: try DeviceID(value: "readiness"), state: .device)
        let scope = BackupSelection(scope: .allSharedStorage)
        func state(adb: Bool = true, phone: AndroidDevice? = device, location: Bool = true,
                   recovery: Bool = false, selection: BackupSelection = scope, busy: Bool = false) -> BackupReadiness {
            BackupReadiness.resolve(hasADB: adb, device: phone, hasLocation: location,
                                    needsLocationRecovery: recovery, selection: selection, isBusy: busy)
        }
        XCTAssertEqual(state(adb: false), .connection)
        XCTAssertEqual(state(phone: nil), .connection)
        XCTAssertEqual(state(location: false), .location)
        XCTAssertEqual(state(recovery: true), .location)
        XCTAssertEqual(state(selection: BackupSelection()), .selection)
        XCTAssertEqual(state(), .ready)
        XCTAssertEqual(state(adb: false, busy: true), .busy)
    }
}

@MainActor
private struct SummaryFixture {
    let root: URL
    let device: AndroidDevice
    let otherDevice: AndroidDevice
    let repository: BackupRepositoryInfo
    let otherRepository: BackupRepositoryInfo
    let transport: FakeDeviceTransport
    let store: FakeBackupRepositoryStore
    let model: AppModel
    let preferences: AppPreferences
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        device = fixtureDevice(id: try DeviceID(value: "summary-device"), state: .device, model: "Fixture phone")
        otherDevice = fixtureDevice(id: try DeviceID(value: "other-device"), state: .device, model: "Other phone")
        repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/device-a"), deviceID: device.id, displayName: "A")
        otherRepository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/device-b"), deviceID: otherDevice.id, displayName: "B")
        transport = FakeDeviceTransport(devices: [device, otherDevice])
        store = FakeBackupRepositoryStore()
        suite = "AndrodoSummaryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults)
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: transport, remoteAccess: transport,
                                               backupEngine: DefaultBackupEngine(remote: transport, repositoryStore: store)),
                         preferences: preferences, loadOnStart: false)
    }

    func point(time: TimeInterval, state: RestorePointState = .completed, omissions: [OperationWarning] = []) -> RestorePoint {
        RestorePoint(createdAt: Date(timeIntervalSince1970: time), state: state, entryCount: 10, totalBytes: 20, omissions: omissions)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
