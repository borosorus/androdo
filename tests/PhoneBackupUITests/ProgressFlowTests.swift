import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class ProgressFlowTests: XCTestCase {
    func testCopyBackgroundStartupCancellationAndReopenKeepOneSession() async throws {
        let fixture = try ProgressFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        let planning = Task { await fixture.model.planPhoneToMacCopy(roots: [fixture.path], destination: fixture.root) }
        await fixture.engine.waitFor(.planning)
        XCTAssertEqual(fixture.model.progressSession?.stage, .planning)
        XCTAssertTrue(fixture.model.progressSession?.isPresented == true)
        XCTAssertNil(fixture.model.progressFraction)
        fixture.model.backgroundProgress()
        await fixture.engine.releasePlanning()
        await planning.value
        XCTAssertTrue(fixture.model.isShowingCopyReview)
        XCTAssertNil(fixture.model.progressSession)
        let start = Task { await fixture.model.startCopy(replacing: []) }
        await fixture.engine.waitFor(.starting)
        let id = fixture.model.progressSession?.id
        XCTAssertEqual(fixture.model.progressSession?.stage, .starting)
        XCTAssertFalse(fixture.model.canCancelProgress)
        XCTAssertTrue(fixture.model.progressSession?.isPresented == true)
        fixture.model.backgroundProgress()
        await fixture.engine.releaseStartup()
        await start.value
        await fixture.engine.send(.transferring, completed: 50)
        await waitUntil { fixture.model.operationEvent?.progress.completedBytes == 50 }
        XCTAssertEqual(fixture.model.progressSession?.id, id)
        XCTAssertEqual(fixture.model.progressFraction, 0.5)
        XCTAssertFalse(fixture.model.progressSession?.isPresented == true)
        await fixture.model.cancelProgress()
        await fixture.model.cancelProgress()
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertEqual(fixture.model.progressPresentation.title, "Cancelling copy…")
        let cancellations = await fixture.engine.cancelCalls
        XCTAssertEqual(cancellations, 1)
        await fixture.engine.send(.cancelled, completed: 50)
        await waitUntil { !fixture.model.isBusy }
        XCTAssertTrue(fixture.model.progressSession?.isFinished == true)
        XCTAssertFalse(fixture.model.progressSession?.isPresented == true)
        fixture.model.showProgress()
        XCTAssertEqual(fixture.model.progressSession?.id, id)
        XCTAssertTrue(fixture.model.progressSession?.isPresented == true)
        fixture.model.dismissProgress()
        XCTAssertNil(fixture.model.progressSession)
    }

    func testCancelledCopyPreparationWaitsAndNeverOpensReview() async throws {
        let fixture = try ProgressFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        let planning = Task { await fixture.model.planPhoneToMacCopy(roots: [fixture.path], destination: fixture.root) }
        await fixture.engine.waitFor(.planning)
        await fixture.model.cancelProgress()
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertTrue(fixture.model.isPlanningCopy)
        fixture.model.clearStatus()
        XCTAssertNotNil(fixture.model.progressSession, "Dismissing an alert cannot clear an active task")
        await fixture.engine.releasePlanning()
        await planning.value
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.isShowingCopyReview)
        XCTAssertTrue(fixture.model.progressSession?.wasCancelled == true)
        XCTAssertNil(fixture.model.errorMessage)
        let starts = await fixture.engine.startCalls
        XCTAssertEqual(starts, 0)
    }

    func testStartupFailureLivesInProgressWithoutLeavingReviewAttached() async throws {
        let fixture = try ProgressFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        let planning = Task { await fixture.model.planPhoneToMacCopy(roots: [fixture.path], destination: fixture.root) }
        await fixture.engine.waitFor(.planning)
        await fixture.engine.releasePlanning()
        await planning.value
        let start = Task { await fixture.model.startCopy(replacing: []) }
        await fixture.engine.waitFor(.starting)
        XCTAssertFalse(fixture.model.isShowingCopyReview)
        await fixture.engine.releaseStartup(failing: true)
        await start.value
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertTrue(fixture.model.progressSession?.isFinished == true)
        XCTAssertNotNil(fixture.model.progressSession?.failure)
        XCTAssertNil(fixture.model.errorMessage, "Failure is shown in progress, not a competing alert")
        XCTAssertNotEqual(fixture.model.progressPresentation.phase, "Verified")
    }

    func testBackupPlanningCancellationIgnoresLateScanAndRetainsBusyUntilUnwind() async throws {
        let fixture = try ProgressFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        fixture.model.setBackupSelection(BackupSelection(scope: .selected([fixture.path])))
        await fixture.store.pauseRestorePointReadsForTesting(in: fixture.repository.id)
        let planning = Task { await fixture.model.reviewBackup() }
        await fixture.store.waitForPausedRestorePointRead(in: fixture.repository.id)
        XCTAssertEqual(fixture.model.progressSession?.kind, .backup)
        await fixture.model.cancelProgress()
        XCTAssertTrue(fixture.model.isPlanningBackup)
        await fixture.store.resumeRestorePointReadsForTesting(in: fixture.repository.id)
        await planning.value
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertFalse(fixture.model.isShowingBackupReview)
        XCTAssertTrue(fixture.model.progressSession?.wasCancelled == true)
    }

    func testFinderPromiseWaitsForVerifiedCompletionAndUsesProgress() async throws {
        let fixture = try ProgressFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        let entry = RemoteEntry(path: fixture.path, kind: .file, size: 100)
        let target = fixture.root.appendingPathComponent("example.jpg")
        let promise = Task { try await fixture.model.writeRemoteFilePromise(entry, from: fixture.device.id, to: target) }
        await fixture.engine.waitFor(.planning)
        await fixture.engine.releasePlanning()
        await fixture.engine.waitFor(.starting)
        await fixture.engine.releaseStartup()
        await waitUntil { fixture.model.isOperationRunning }
        XCTAssertFalse(fixture.model.isShowingCopyReview)
        let id = fixture.model.progressSession?.id
        fixture.model.backgroundProgress()
        await fixture.engine.send(.committing, completed: 100)
        await waitUntil { fixture.model.operationEvent?.phase == .committing }
        XCTAssertNil(fixture.model.progressFraction, "Finishing remains indeterminate")
        await fixture.engine.send(.completed, completed: 100)
        try await promise.value
        await waitUntil { !fixture.model.isBusy }
        XCTAssertEqual(fixture.model.progressSession?.id, id)
        XCTAssertTrue(fixture.model.progressSession?.isFinished == true)
        XCTAssertFalse(fixture.model.progressSession?.isPresented == true)
        XCTAssertEqual(fixture.model.progressPresentation.title, "Copy complete")
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Fixture state did not settle")
    }
}

@MainActor
private final class ProgressFixture {
    let root: URL
    let path = try! RemotePath("/sdcard/Trial/example.jpg")
    let device = fixtureDevice(id: try! DeviceID(value: "progress-fixture"), state: .device)
    let repository: BackupRepositoryInfo
    let engine = ProgressCopyEngine()
    let remote: FakeDeviceTransport
    let store = FakeBackupRepositoryStore()
    let model: AppModel
    private let defaults: UserDefaults
    private let suite = "AndrodoProgressTests.\(UUID().uuidString)"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = BackupRepositoryInfo(location: root.appendingPathComponent("PhoneBackup/fixture"), deviceID: device.id, displayName: "Fixture")
        remote = FakeDeviceTransport(devices: [device])
        defaults = UserDefaults(suiteName: suite)!
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: remote, remoteAccess: remote,
            remoteDestinationAccess: remote, backupEngine: DefaultBackupEngine(remote: remote, repositoryStore: store), copyEngine: engine),
            preferences: AppPreferences(defaults: defaults), loadOnStart: false, adbResolver: { _ in nil })
    }
    func prepare() async {
        await store.seed(repository: repository)
        await remote.seed(RemoteEntry(path: path, kind: .file, size: 100), on: device.id, data: Data(repeating: 1, count: 100))
        await model.refreshDevices()
        await model.chooseBackupLocation(root)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

/// Gated work deliberately returns after cancellation so model ownership is tested independently.
private actor ProgressCopyEngine: CopyEngine {
    enum Gate: Hashable { case planning, starting }
    private var reached: Set<Gate> = []
    private var waiters: [Gate: CheckedContinuation<Void, Never>] = [:]
    private var planningGate: CheckedContinuation<Void, Never>?
    private var startupGate: CheckedContinuation<Void, Never>?
    private var startupFails = false
    private let operation = OperationID()
    private var latest: OperationEvent?
    private var subscribers: [AsyncStream<OperationEvent>.Continuation] = []
    private(set) var cancelCalls = 0
    private(set) var startCalls = 0

    func planCopy(_ request: CopyRequest) async throws -> CopyPlan {
        await withCheckedContinuation { continuation in
            planningGate = continuation
            reached.insert(.planning)
            waiters.removeValue(forKey: .planning)?.resume()
        }
        guard case .phoneToMac(_, let roots, let destination) = request else { throw EngineError.emptySelection }
        let path = roots[0]
        return CopyPlan(request: request, mappings: [CopyMapping(source: .phone(RemoteEntry(path: path, kind: .file, size: 100)),
            destination: .local(destination.appendingPathComponent(path.name!)), kind: .file)], conflicts: [], totalBytes: 100, fileCount: 1, directoryCount: 0)
    }
    func waitFor(_ gate: Gate) async {
        if reached.contains(gate) { return }
        await withCheckedContinuation { waiters[gate] = $0 }
    }
    func releasePlanning() { planningGate?.resume(); planningGate = nil }
    func releaseStartup(failing: Bool = false) { startupFails = failing; startupGate?.resume(); startupGate = nil }
    func startCopy(_ plan: CopyPlanID, replacing conflicts: Set<UUID>) async throws -> OperationID {
        startCalls += 1
        await withCheckedContinuation { continuation in
            startupGate = continuation
            reached.insert(.starting)
            waiters.removeValue(forKey: .starting)?.resume()
        }
        if startupFails { throw EngineError.transport("Fixture startup failed") }
        return operation
    }
    func send(_ phase: OperationPhase, completed: Int64) {
        let event = OperationEvent(operationID: operation, phase: phase,
            progress: OperationProgress(completedItems: completed == 100 ? 1 : 0, totalItems: 1, completedBytes: completed, totalBytes: 100))
        latest = event
        for subscriber in subscribers {
            subscriber.yield(event)
            if phase.isTerminal { subscriber.finish() }
        }
    }
    func events(for operation: OperationID) async -> AsyncStream<OperationEvent> {
        let (stream, continuation) = AsyncStream<OperationEvent>.makeStream()
        if let latest { continuation.yield(latest) }
        if latest?.phase.isTerminal == true { continuation.finish() }
        else { subscribers.append(continuation) }
        return stream
    }
    func cancel(_ operation: OperationID) async { cancelCalls += 1 }
    func result(for operation: OperationID) async -> CopyBatchResult? {
        CopyBatchResult(operationID: operation, items: [CopyItemResult(source: "fixture", destination: "fixture",
            state: latest?.phase == .completed ? .publishedAndVerified : .cancelled)])
    }
}
