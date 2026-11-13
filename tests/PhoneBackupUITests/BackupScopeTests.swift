import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class BackupScopeTests: XCTestCase {
    func testModeSwitchesKeepCustomRootsAndExclusions() throws {
        let root = try RemotePath("/sdcard/Pictures")
        let excluded = try root.appending("Private")
        var draft = BackupScopeDraft(BackupSelection(scope: .selected([root]), excludedRoots: [excluded]))
        draft.setAllSharedFiles(true)
        XCTAssertTrue(draft.allSharedFiles)
        XCTAssertEqual(draft.selection.excludedRoots, [excluded])
        draft.setAllSharedFiles(false)
        XCTAssertEqual(draft.includedRoots, [root])
        XCTAssertFalse(draft.selection.includes(excluded))
    }

    func testIncludeCannotSilentlyRemoveAnExcludedParentAndIncludeSiblings() throws {
        let parent = try RemotePath("/sdcard/Pictures")
        let child = try parent.appending("Camera")
        let sibling = try parent.appending("Private")
        var draft = BackupScopeDraft(BackupSelection(scope: .allSharedStorage, excludedRoots: [parent]))
        let original = draft.selection
        XCTAssertFalse(draft.canInclude([child]))
        draft.include([child])
        XCTAssertEqual(draft.selection, original)
        XCTAssertFalse(draft.selection.includes(sibling))
        draft.removeExclusion(parent) // Explicit tray action removes the whole exclusion.
        XCTAssertTrue(draft.selection.includes(sibling))
    }

    func testIncludeExcludeAndTrayRemovalHaveExplicitScope() throws {
        let root = try RemotePath("/sdcard/Pictures")
        let excluded = try root.appending("Private")
        let included = try root.appending("Camera")
        var draft = BackupScopeDraft(BackupSelection())
        draft.include([root])
        draft.exclude([excluded])
        XCTAssertTrue(draft.selection.includes(included))
        XCTAssertFalse(draft.selection.includes(excluded))
        XCTAssertEqual(draft.status(for: root), "Partly included")
        XCTAssertEqual(draft.status(for: excluded), "Excluded")
        draft.removeIncluded(root)
        XCTAssertFalse(draft.selection.includes(included))
    }

    func testDraftAndCancelDoNotPersistWhileDoneIsBoundToCapturedPhone() async throws {
        let suite = "AndrodoScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let a = AndroidDevice(id: try DeviceID(serial: "scope-a"), state: .device)
        let b = AndroidDevice(id: try DeviceID(serial: "scope-b"), state: .device)
        let transport = FakeDeviceTransport(devices: [a, b])
        let model = AppModel(services: AppServices(repositoryStore: FakeBackupRepositoryStore(), deviceTransport: transport, remoteAccess: transport),
                             preferences: preferences, loadOnStart: false)
        await model.refreshDevices()
        let original = BackupSelection(scope: .selected([try RemotePath("/sdcard/Documents")]))
        XCTAssertTrue(model.applyBackupSelection(original, for: a.id))
        let session = BackupSelectionSession(device: a, selection: original)
        var draft = BackupScopeDraft(session.selection)
        draft.include([try RemotePath("/sdcard/Pictures")])
        XCTAssertEqual(model.backupSelection, original)
        XCTAssertEqual(preferences.selection(for: a.id), original) // Discarding the value is Cancel.
        XCTAssertTrue(model.applyBackupSelection(draft.selection, for: a.id))
        XCTAssertEqual(preferences.selection(for: a.id), draft.selection)
        model.selectDevice(b)
        XCTAssertFalse(model.applyBackupSelection(draft.selection, for: session.device.id))
        XCTAssertEqual(preferences.selection(for: b.id), BackupSelection())
        await transport.setDevices([])
        await model.refreshDevices()
        XCTAssertFalse(model.applyBackupSelection(draft.selection, for: b.id))
    }

    func testEditingAndModeChangesDoNotReadAnyMorePhoneFolders() async throws {
        let id = try DeviceID(serial: "scope-browsing")
        let device = AndroidDevice(id: id, state: .device)
        let remote = FakeDeviceTransport(devices: [device])
        let root = RemoteBrowserModel.sharedStorage
        let pictures = try root.appending("Pictures")
        await remote.seed(RemoteEntry(path: pictures, kind: .directory), on: id)
        let browser = RemoteBrowserModel(remote: remote)
        browser.setDevice(device)
        await browser.openRoot()
        var draft = BackupScopeDraft(BackupSelection())
        browser.selection = [pictures]
        draft.include(browser.visibleSelection)
        draft.setAllSharedFiles(true)
        draft.setAllSharedFiles(false)
        draft.removeIncluded(pictures)
        let calls = await remote.recordedChildrenCalls(on: id)
        XCTAssertEqual(calls, [root])
        await browser.navigate(to: pictures)
        let opened = await remote.recordedChildrenCalls(on: id)
        XCTAssertEqual(opened, [root, pictures])
    }
}
