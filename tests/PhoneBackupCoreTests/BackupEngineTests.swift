import Foundation
import XCTest
@testable import PhoneBackupCore

final class BackupEngineTests: XCTestCase {
    func testScopedBackupPublishesSnapshotAndReusesUnchangedFiles() async throws {
        let deviceID = try DeviceID(serial: "engine-test")
        let device = AndroidDevice(id: deviceID, state: .device)
        let root = try RemotePath("/sdcard/Twitter")
        let file = try root.appending("image.jpg")
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = FakeDeviceTransport(devices: [device])
        await transport.seed(RemoteEntry(path: file, kind: .file, size: 5, modifiedAt: modified), on: deviceID,
                             data: Data("image".utf8))

        let store = FakeBackupRepositoryStore()
        let repository = BackupRepositoryInfo(location: URL(fileURLWithPath: "/tmp/engine-test"),
                                              deviceID: deviceID, displayName: "Test device")
        await store.seed(repository: repository)
        let engine = DefaultBackupEngine(remote: transport, repositoryStore: store)
        let selection = BackupSelection(scope: .selected([root]))

        let plan = try await engine.plan(repository: repository.id, device: deviceID, selection: selection)
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(plan.transferCount, 1)
        XCTAssertEqual(plan.bytesToTransfer, 5)

        let firstOperation = try await engine.startBackup(using: plan.id)
        let firstEvents = await collectEvents(from: engine, operation: firstOperation)
        XCTAssertEqual(firstEvents.last?.phase, .completed)
        let firstPulls = await transport.recordedPulls(on: deviceID)
        XCTAssertEqual(firstPulls, [file])

        let secondPlan = try await engine.plan(repository: repository.id, device: deviceID, selection: selection)
        XCTAssertEqual(secondPlan.transferCount, 0)
        XCTAssertEqual(secondPlan.reusedCount, 1)
        let secondOperation = try await engine.startBackup(using: secondPlan.id)
        let secondEvents = await collectEvents(from: engine, operation: secondOperation)
        XCTAssertEqual(secondEvents.last?.phase, .completed)
        let secondPulls = await transport.recordedPulls(on: deviceID)
        XCTAssertEqual(secondPulls, [file])

        let points = try await store.restorePoints(in: repository.id)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points.first?.entryCount, 2) // Selected root and its file.

        await transport.remove(file, on: deviceID)
        let deletionPlan = try await engine.plan(repository: repository.id, device: deviceID, selection: selection)
        XCTAssertEqual(deletionPlan.deletedCount, 1)
        XCTAssertEqual(deletionPlan.transferCount, 0)
        let deletionOperation = try await engine.startBackup(using: deletionPlan.id)
        let deletionEvents = await collectEvents(from: engine, operation: deletionOperation)
        XCTAssertEqual(deletionEvents.last?.phase, .completed)
        let latestPoints = try await store.restorePoints(in: repository.id)
        let latestPoint = try XCTUnwrap(latestPoints.first)
        let latestEntries = try await store.entries(in: repository.id, point: latestPoint.id, below: nil)
        XCTAssertEqual(latestEntries.map(\.path), [root])
    }

    func testSelectionUsesPathComponentsAndPrunesNestedRoots() throws {
        let parent = try RemotePath("/sdcard/Pictures")
        let child = try RemotePath("/sdcard/Pictures/Camera")
        let sibling = try RemotePath("/sdcard/Pictures-old")
        let selection = BackupSelection(scope: .selected([parent, child]))

        XCTAssertEqual(selection.normalizedRoots, [parent])
        XCTAssertTrue(selection.includes(child))
        XCTAssertFalse(selection.includes(sibling))
        XCTAssertFalse(BackupSelection(scope: .allSharedStorage,
                                       excludedRoots: [parent]).includes(try RemotePath("/sdcard/Pictures/a.jpg")))
    }

    func testInaccessibleSelectionStaysIncompleteUntilExplicitOmissionChoice() async throws {
        let deviceID = try DeviceID(serial: "omission-test")
        let device = AndroidDevice(id: deviceID, state: .device)
        let root = try RemotePath("/sdcard/Twitter")
        let transport = FakeDeviceTransport(devices: [device])
        await transport.seed(RemoteEntry(path: root, kind: .directory), on: deviceID)
        for _ in 0..<3 {
            await transport.failNext(.inaccessiblePath(root), operation: .children, at: root, on: deviceID)
        }

        let store = FakeBackupRepositoryStore()
        let repository = BackupRepositoryInfo(location: URL(fileURLWithPath: "/tmp/omission-test"),
                                              deviceID: deviceID, displayName: "Test device")
        await store.seed(repository: repository)
        let engine = DefaultBackupEngine(remote: transport, repositoryStore: store)
        let selection = BackupSelection(scope: .selected([root]))

        let plan = try await engine.plan(repository: repository.id, device: deviceID, selection: selection)
        XCTAssertEqual(plan.omissions.count, 1)
        let operation = try await engine.startBackup(using: plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .incomplete)
        let incompletePoints = try await store.restorePoints(in: repository.id)
        XCTAssertTrue(incompletePoints.isEmpty)

        let attempts = try await engine.attempts(in: repository.id)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt.state, .needsOmissionDecision)
        let acceptedOperation = try await engine.finishWithOmissions(attempt.id)
        let acceptedEvents = await collectEvents(from: engine, operation: acceptedOperation)
        XCTAssertEqual(acceptedEvents.last?.phase, .completed)
        let points = try await store.restorePoints(in: repository.id)
        XCTAssertEqual(points.count, 1)
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point.omissions.count, 1)
    }

    func testOmissionApprovalDoesNotCarryOverToANewlyBlockedPath() async throws {
        let deviceID = try DeviceID(serial: "stale-omission-test")
        let device = AndroidDevice(id: deviceID, state: .device)
        let root = try RemotePath("/sdcard/Twitter")
        let nested = try root.appending("Private")
        let transport = FakeDeviceTransport(devices: [device])
        await transport.seed(RemoteEntry(path: nested, kind: .directory), on: deviceID)
        await transport.failNext(.inaccessiblePath(root), operation: .children, at: root, on: deviceID)
        await transport.failNext(.inaccessiblePath(root), operation: .children, at: root, on: deviceID)
        await transport.failNext(.inaccessiblePath(nested), operation: .children, at: nested, on: deviceID)

        let store = FakeBackupRepositoryStore()
        let repository = BackupRepositoryInfo(location: URL(fileURLWithPath: "/tmp/stale-omission-test"),
                                              deviceID: deviceID, displayName: "Test device")
        await store.seed(repository: repository)
        let engine = DefaultBackupEngine(remote: transport, repositoryStore: store)
        let selection = BackupSelection(scope: .selected([root]))

        let plan = try await engine.plan(repository: repository.id, device: deviceID, selection: selection)
        let operation = try await engine.startBackup(using: plan.id)
        let initialEvents = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(initialEvents.last?.phase, .incomplete)

        let initialAttempts = try await engine.attempts(in: repository.id)
        let attempt = try XCTUnwrap(initialAttempts.first)
        let retry = try await engine.finishWithOmissions(attempt.id)
        let retryEvents = await collectEvents(from: engine, operation: retry)
        XCTAssertEqual(retryEvents.last?.phase, .incomplete)
        let pointsAfterNewOmission = try await store.restorePoints(in: repository.id)
        XCTAssertTrue(pointsAfterNewOmission.isEmpty)

        let updatedAttempts = try await engine.attempts(in: repository.id)
        let updatedAttempt = try XCTUnwrap(updatedAttempts.first)
        let acceptedRetry = try await engine.finishWithOmissions(updatedAttempt.id)
        let acceptedEvents = await collectEvents(from: engine, operation: acceptedRetry)
        XCTAssertEqual(acceptedEvents.last?.phase, .completed)
    }

    func testFileMutationDuringPullIsRetriedBeforePublishing() async throws {
        let deviceID = try DeviceID(serial: "mutation-test")
        let device = AndroidDevice(id: deviceID, state: .device)
        let root = try RemotePath("/sdcard/Twitter")
        let file = try root.appending("image.jpg")
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_700_000_100)
        let transport = FakeDeviceTransport(devices: [device])
        await transport.seed(RemoteEntry(path: file, kind: .file, size: 3, modifiedAt: oldDate), on: deviceID,
                             data: Data("old".utf8))
        await transport.mutateAfterNextPull(
            RemoteEntry(path: file, kind: .file, size: 7, modifiedAt: newDate), data: Data("updated".utf8), on: deviceID
        )
        let store = FakeBackupRepositoryStore()
        let repository = BackupRepositoryInfo(location: URL(fileURLWithPath: "/tmp/mutation-test"),
                                              deviceID: deviceID, displayName: "Test device")
        await store.seed(repository: repository)
        let engine = DefaultBackupEngine(remote: transport, repositoryStore: store)
        let selection = BackupSelection(scope: .selected([root]))

        let plan = try await engine.plan(repository: repository.id, device: deviceID, selection: selection)
        let operation = try await engine.startBackup(using: plan.id)
        let events = await collectEvents(from: engine, operation: operation)
        XCTAssertEqual(events.last?.phase, .completed)
        let pulls = await transport.recordedPulls(on: deviceID)
        XCTAssertEqual(pulls, [file, file])
        let points = try await store.restorePoints(in: repository.id)
        let point = try XCTUnwrap(points.first)
        let entries = try await store.entries(in: repository.id, point: point.id, below: nil)
        XCTAssertEqual(entries.first(where: { $0.path == file })?.size, 7)
    }

    private func collectEvents(from engine: DefaultBackupEngine, operation: OperationID) async -> [OperationEvent] {
        let stream = await engine.events(for: operation)
        var result: [OperationEvent] = []
        for await event in stream { result.append(event) }
        return result
    }
}
