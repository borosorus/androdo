import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class ActivityTests: XCTestCase {
    func testIncompleteActivityCountsWarningsWithoutRetainingPathOrErrorText() throws {
        let store = ActivityStore()
        let id = store.begin(.copy)
        let secret = try RemotePath("/sdcard/Private/secret.jpg")
        let warning = OperationWarning(code: .inaccessiblePath, path: secret, message: "private transport details")
        let event = OperationEvent(operationID: OperationID(), phase: .incomplete,
                                   progress: OperationProgress(completedItems: 2, totalItems: 3),
                                   warnings: [warning])

        store.update(id, event: event)

        let record = try XCTUnwrap(store.records.first)
        XCTAssertEqual(record.outcome, .incomplete)
        XCTAssertEqual(record.completedItems, 2)
        XCTAssertEqual(record.warningCount, 1)
        XCTAssertFalse(record.safeSummary.contains(secret.description))
        XCTAssertFalse(record.safeSummary.contains("private transport details"))
    }

    func testActivityHistoryIsBoundedAndCanClearFinishedRecords() {
        let store = ActivityStore(recordLimit: 2)
        _ = store.begin(.backup)
        let second = store.begin(.restore)
        _ = store.begin(.copy)

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records.first?.kind, .copy)
        store.clearFinished()
        XCTAssertEqual(store.records.count, 2) // Running items are preserved.

        store.update(second, event: OperationEvent(operationID: OperationID(), phase: .completed))
        store.clearFinished()
        XCTAssertEqual(store.records.count, 1)
    }
}
