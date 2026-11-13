import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class PreferencesAndMappingTests: XCTestCase {
    func testSelectionPreferencesRoundTripPerDevice() throws {
        let suite = "PhoneBackupUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let device = try DeviceID(serial: "pixel-test")
        let chosen = try RemotePath("/sdcard/Pictures/Camera")
        let selection = BackupSelection(scope: .selected([chosen]))

        preferences.save(selection, for: device)

        XCTAssertEqual(preferences.selection(for: device), selection)
        XCTAssertEqual(preferences.selection(for: try DeviceID(serial: "another-device")), BackupSelection())
    }

    func testExportBaseUsesSharedPathComponentsOnly() throws {
        let one = try RemotePath("/sdcard/Pictures/Camera")
        let two = try RemotePath("/sdcard/Pictures/Screenshots")
        let base = try XCTUnwrap(ExportMapping.commonSourceBase(for: [one, two]))
        XCTAssertEqual(base, try RemotePath("/sdcard/Pictures"))

        let unrelated = try RemotePath("/storage/emulated/0/Download")
        XCTAssertEqual(ExportMapping.commonSourceBase(for: [one, unrelated]), .root)
        XCTAssertNil(ExportMapping.commonSourceBase(for: [RemotePath]()))
    }

    func testSingleFileExportUsesItsParentAndRetainsItsFilename() throws {
        let file = try RemotePath("/sdcard/Pictures/one-photo.jpg")
        let entry = BackupEntry(path: file, kind: .file, size: 10, modifiedAt: nil, contentHash: "hash")

        XCTAssertEqual(ExportMapping.commonSourceBase(for: [entry]), try RemotePath("/sdcard/Pictures"))

        let folder = BackupEntry(path: try RemotePath("/sdcard/Pictures/Camera"), kind: .directory,
                                 size: 0, modifiedAt: nil, contentHash: nil)
        XCTAssertEqual(ExportMapping.commonSourceBase(for: [folder]), folder.path)
    }

    func testDeviceDiscoveryDoesNotEnumeratePhoneFolders() async throws {
        let id = try DeviceID(serial: "ui-test-device")
        let device = AndroidDevice(id: id, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let store = FakeBackupRepositoryStore()
        let services = AppServices(repositoryStore: store, deviceTransport: transport, remoteAccess: transport)
        let model = AppModel(services: services,
                            preferences: AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                            loadOnStart: false)

        await model.refreshDevices()
        XCTAssertEqual(model.selectedDevice?.id, id)
        let discoveryCalls = await transport.recordedChildrenCalls(on: id)
        XCTAssertTrue(discoveryCalls.isEmpty)

        _ = await model.listRemoteChildren(of: try RemotePath("/sdcard"))
        let openedFolders = await transport.recordedChildrenCalls(on: id)
        XCTAssertEqual(openedFolders, [try RemotePath("/sdcard")])
    }
}
