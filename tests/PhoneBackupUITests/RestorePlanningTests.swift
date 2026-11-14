import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class RestorePlanningTests: XCTestCase {
    func testCancelledPlanningCannotClearNewProgressOrPublishAnOldReview() async throws {
        let engine = GatedRestoreEngine()
        let fixture = try RestoreFixture(engine: engine)
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let old = Task { await fixture.model.planPhoneRestore(to: nil, policy: .stopIfFileExists) }
        await engine.waitForPlan(0)
        XCTAssertTrue(fixture.model.isPlanningExport)
        XCTAssertNotNil(fixture.model.restorePlanningProgress)
        fixture.model.cancelRestorePlanning()
        XCTAssertTrue(fixture.model.isBusy, "Cancellation retains ownership until the worker unwinds")
        XCTAssertTrue(fixture.model.progressSession?.cancellationRequested == true)
        XCTAssertFalse(fixture.model.canCancelProgress)
        await engine.finish(0)
        await old.value
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.isShowingExportReview)
        let current = Task { await fixture.model.planPhoneRestore(to: nil, policy: .replaceFiles) }
        await engine.waitForPlan(1)
        await engine.sendProgress(1, completed: 2)
        XCTAssertTrue(fixture.model.isPlanningExport)
        XCTAssertEqual(fixture.model.restorePlanningProgress?.completedItems, 2)
        XCTAssertFalse(fixture.model.isShowingExportReview)
        await engine.sendProgress(0, completed: 9)
        XCTAssertEqual(fixture.model.restorePlanningProgress?.completedItems, 2)
        await engine.finish(1)
        await current.value
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertTrue(fixture.model.isShowingExportReview)
        XCTAssertEqual(fixture.model.restorePlan?.request.phoneConflictPolicy, .replaceFiles)
        XCTAssertNil(fixture.model.restorePlanningProgress)
    }

    func testBackgroundPlanningDetachesPhoneSetupThenHandsOffToReviewWithoutStarting() async throws {
        let engine = GatedRestoreEngine()
        let fixture = try RestoreFixture(engine: engine)
        defer { fixture.cleanup() }
        try await fixture.prepare()
        fixture.model.isShowingPhoneRestoreSetup = true
        let planning = Task { await fixture.model.planPhoneRestore(to: nil, policy: .replaceFiles) }
        await engine.waitForPlan(0)
        XCTAssertFalse(fixture.model.isShowingPhoneRestoreSetup)
        XCTAssertTrue(fixture.model.progressSession?.isPresented == true)
        fixture.model.backgroundProgress()
        await engine.sendProgress(0, completed: 4)
        XCTAssertFalse(fixture.model.progressSession?.isPresented == true)
        XCTAssertEqual(fixture.model.progressFraction, 0.4)
        await engine.finish(0)
        await planning.value
        XCTAssertTrue(fixture.model.isShowingExportReview)
        XCTAssertNil(fixture.model.progressSession, "Progress closes for explicit review")
        XCTAssertNil(fixture.model.operationID, "Review never starts a transfer")
    }

    func testLocalExportSharesPreparationAndExplicitReview() async throws {
        let engine = GatedRestoreEngine()
        let fixture = try RestoreFixture(engine: engine)
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let planning = Task { await fixture.model.planLocalExport(to: fixture.root) }
        await engine.waitForPlan(0)
        XCTAssertEqual(fixture.model.progressSession?.kind, .export)
        XCTAssertEqual(fixture.model.progressSession?.stage, .planning)
        fixture.model.backgroundProgress()
        await engine.finish(0)
        await planning.value
        XCTAssertTrue(fixture.model.isShowingExportReview)
        XCTAssertFalse(fixture.model.restoreTargetIsPhone)
        XCTAssertNil(fixture.model.progressSession)
        XCTAssertNil(fixture.model.operationID)
    }

    func testUnsupportedStrictPublicationKeepsBatchResultAndNeverAutomaticallyReplans() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        await fixture.remote.setSupportsNoOverwritePublication(false)
        await fixture.model.planPhoneRestore(to: nil, policy: .stopIfFileExists)
        XCTAssertTrue(fixture.model.isShowingExportReview)
        XCTAssertTrue(fixture.model.restorePlan?.conflicts.isEmpty == true)
        await fixture.model.startRestore(replacing: [])
        // Wait for the fake engine's finite event stream to drain through the model.
        for _ in 0..<10_000 {
            if !fixture.model.isOperationRunning { break }
            await Task.yield()
        }
        XCTAssertFalse(fixture.model.isOperationRunning)
        XCTAssertEqual(fixture.model.operationEvent?.phase, .failed)
        XCTAssertEqual(fixture.model.restoreResult?.items.first?.state, .failed)
        XCTAssertFalse(fixture.model.isShowingExportReview)
        XCTAssertNil(fixture.model.restorePlan)
        let publications = await fixture.remote.recordedPublications()
        XCTAssertEqual(publications.count, 1)
        XCTAssertNil(publications.first?.replacing)
    }

    func testCancelledRealPlanningDoesNotShowReviewOrAlert() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare()
        let point = try XCTUnwrap(fixture.model.selectedRestorePoint)
        await fixture.store.pauseEntryReadsForTesting(point: point.id)
        let planning = Task { await fixture.model.planPhoneRestore(to: nil, policy: .replaceFiles) }
        await fixture.store.waitForPausedEntryRead(point: point.id)
        XCTAssertTrue(fixture.model.isPlanningExport)
        fixture.model.cancelRestorePlanning()
        await fixture.store.resumeEntryReadsForTesting(point: point.id)
        await planning.value
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.isShowingExportReview)
        XCTAssertNil(fixture.model.errorMessage)
        let publications = await fixture.remote.recordedPublications()
        XCTAssertTrue(publications.isEmpty)
    }
}

@MainActor
private final class RestoreFixture {
    let root: URL
    let device = fixtureDevice(id: try! DeviceID(value: "restore-ui-fixture"), state: .device)
    let remote: FakeDeviceTransport
    let store = FakeBackupRepositoryStore()
    let model: AppModel
    private let defaults: UserDefaults
    private let suite = "AndrodoRestoreTests.\(UUID().uuidString)"

    init(engine: (any RestoreEngine)? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        remote = FakeDeviceTransport(devices: [device])
        defaults = UserDefaults(suiteName: suite)!
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: remote, remoteAccess: remote,
                                              remoteDestinationAccess: remote, restoreEngine: engine),
                         preferences: AppPreferences(defaults: defaults), loadOnStart: false, adbResolver: { _ in nil })
    }

    func prepare() async throws {
        let repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/fixture"), deviceID: device.id, displayName: "Fixture")
        await store.seed(repository: repository)
        let source = root.appendingPathComponent("fixture-data")
        try Data("fixture".utf8).write(to: source)
        let reference = try await store.importFile(from: source, expectedSize: 7, into: repository.id)
        let path = try RemotePath("/sdcard/Trial/file.jpg")
        let point = try await store.publish(RestorePointManifest(selection: BackupSelection(scope: .selected([path])), entries: [
            BackupEntry(path: path, kind: .file, size: reference.size, modifiedAt: nil, contentHash: reference.sha256)
        ]), in: repository.id)
        await model.refreshDevices()
        await model.chooseBackupLocation(root)
        await model.selectRestorePoint(point)
        model.toggleRestoreRoot(path)
    }

    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

/// Deliberately ignores cancellation so the model must guard late callbacks and results itself.
private actor GatedRestoreEngine: RestoreEngine {
    private struct Pending {
        let request: RestoreRequest
        let progress: @Sendable (RestorePlanningProgress) async -> Void
        let continuation: CheckedContinuation<RestorePlan, Never>
    }
    private var pending: [Pending] = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func planRestore(_ request: RestoreRequest) async throws -> RestorePlan {
        try await planRestore(request, progress: { _ in })
    }
    func planRestore(_ request: RestoreRequest, progress: @Sendable @escaping (RestorePlanningProgress) async -> Void) async throws -> RestorePlan {
        await withCheckedContinuation { continuation in
            let index = pending.count
            pending.append(Pending(request: request, progress: progress, continuation: continuation))
            waiters.removeValue(forKey: index)?.resume()
        }
    }
    func waitForPlan(_ index: Int) async {
        if pending.count > index { return }
        await withCheckedContinuation { waiters[index] = $0 }
    }
    func sendProgress(_ index: Int, completed: Int) async {
        await pending[index].progress(RestorePlanningProgress(stage: .checkingDestinations, completedItems: completed, totalItems: 10))
    }
    func finish(_ index: Int) {
        let item = pending[index]
        item.continuation.resume(returning: RestorePlan(request: item.request, mappings: [], conflicts: [], totalBytes: 0, fileCount: 0, directoryCount: 0))
    }
    func startRestore(_ plan: RestorePlanID, replacing conflicts: Set<UUID>) async throws -> OperationID { OperationID() }
    func result(for operation: OperationID) async -> RestoreBatchResult? { nil }
    func events(for operation: OperationID) async -> AsyncStream<OperationEvent> { AsyncStream { $0.finish() } }
    func cancel(_ operation: OperationID) async {}
}
