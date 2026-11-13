import XCTest
@testable import PhoneBackupCore

final class PhoneBackupCoreTests: XCTestCase {
    func testExposesApplicationName() {
        XCTAssertEqual(PhoneBackupCore.applicationName, "PhoneBackup")
    }
}
