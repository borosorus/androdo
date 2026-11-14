import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

final class OperationPresentationTests: XCTestCase {
    func testSuccessfulResultsRemainSpecificEvenWithOlderUnfinishedBackups() {
        for (kind, expected) in [(OperationKind.backup, "Backup complete"), (.copy, "Copy complete"), (.restore, "Restore complete"), (.export, "Export complete")] {
            let value = OperationPresentation(kind: kind, event: OperationEvent(operationID: OperationID(), phase: .completed),
                                              isRunning: false, recovery: nil, pendingCount: 2)
            XCTAssertEqual(value.title, expected)
            XCTAssertEqual(value.phase, "Verified")
        }
    }

    func testWarningsFailuresCancellationAndIncompleteNeverClaimPlainSuccess() {
        let warning = OperationWarning(code: .inaccessiblePath, message: "Fixture warning")
        let warned = OperationPresentation(kind: .copy, event: OperationEvent(operationID: OperationID(), phase: .completed, warnings: [warning]),
                                           isRunning: false, recovery: nil, pendingCount: 0)
        XCTAssertEqual(warned.title, "Copy finished with skipped paths")
        XCTAssertNotEqual(warned.phase, "Verified")
        for (phase, title) in [(OperationPhase.failed, "Restore failed"), (.incomplete, "Restore incomplete"), (.cancelled, "Restore cancelled")] {
            let value = OperationPresentation(kind: .restore, event: OperationEvent(operationID: OperationID(), phase: phase),
                                              isRunning: false, recovery: nil, pendingCount: 0)
            XCTAssertEqual(value.title, title)
            XCTAssertFalse(value.phase.isEmpty)
        }
    }

    func testRecoveryWithoutCurrentOperationHasAnExplanation() throws {
        let attempt = BackupAttempt(id: BackupAttemptID(), repository: RepositoryID(), device: try DeviceID(value: "fixture"),
                                    selection: BackupSelection(), startedAt: .now, state: .interrupted, omissions: [], checkpointCount: 3)
        let value = OperationPresentation(kind: nil, event: nil, isRunning: false, recovery: attempt, pendingCount: 1)
        XCTAssertEqual(value.title, "Backup interrupted")
        XCTAssertFalse(value.phase.isEmpty)
    }
}
