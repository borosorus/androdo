import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class BackupSelectionDraftTests: XCTestCase {
    func testEditingDraftDoesNotPersistUntilDoneAppliesIt() throws {
        let suite = "PhoneBackupUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let model = AppModel(services: AppServices(repositoryStore: FakeBackupRepositoryStore()),
                             preferences: preferences, loadOnStart: false)
        let device = AndroidDevice(id: try DeviceID(serial: "pixel-test"), state: .device, model: "Pixel")
        model.selectDevice(device)
        let parent = try RemotePath("/sdcard/Pictures")
        let child = try RemotePath("/sdcard/Pictures/Camera")
        let original = BackupSelection(scope: .selected([parent]))
        model.setBackupSelection(original)

        let draft = BackupSelectionEditing.set(false, path: child, in: original)

        XCTAssertFalse(draft.includes(child))
        XCTAssertTrue(draft.includes(try RemotePath("/sdcard/Pictures/Screenshots")))
        XCTAssertEqual(model.backupSelection, original)
        XCTAssertEqual(preferences.selection(for: device.id), original)

        model.setBackupSelection(draft)

        XCTAssertEqual(model.backupSelection, draft)
        XCTAssertEqual(preferences.selection(for: device.id), draft)
    }

    func testSelectingAChildWithinAnExcludedFolderRestoresTheScope() throws {
        let excluded = try RemotePath("/sdcard/Pictures/Camera")
        let child = try RemotePath("/sdcard/Pictures/Camera/2026")
        let initial = BackupSelection(scope: .allSharedStorage, excludedRoots: [excluded])

        let updated = BackupSelectionEditing.set(true, path: child, in: initial)

        XCTAssertTrue(updated.includes(excluded))
        XCTAssertTrue(updated.excludedRoots.isEmpty)
    }
}
