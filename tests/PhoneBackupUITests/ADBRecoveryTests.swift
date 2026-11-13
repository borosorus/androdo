import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class ADBRecoveryTests: XCTestCase {
    func testInvalidManualADBSelectionKeepsPreviousPreferenceAndAllowsRecovery() throws {
        let suite = "PhoneBackupUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = "/previous/platform-tools/adb"
        let preferences = AppPreferences(defaults: defaults)
        preferences.adbExecutablePath = previous
        let model = AppModel(services: AppServices(repositoryStore: FakeBackupRepositoryStore()),
                             preferences: preferences, loadOnStart: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        model.locateADB(at: directory)

        XCTAssertFalse(model.hasADB)
        XCTAssertEqual(preferences.adbExecutablePath, previous)
        XCTAssertEqual(model.errorMessage, "Choose an executable ADB file, then try again.")
    }

    func testADBConfigurationCannotChangeDuringDeviceRefresh() async throws {
        let transport = PausedDeviceTransport()
        let suite = "PhoneBackupUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let model = AppModel(services: AppServices(repositoryStore: FakeBackupRepositoryStore(),
                                                    deviceTransport: transport),
                             preferences: preferences,
                             loadOnStart: false)
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        let refresh = Task { await model.refreshDevices() }
        await transport.waitUntilStarted()
        XCTAssertTrue(model.isBusy)

        model.locateADB(at: executable)

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(preferences.adbExecutablePath)
        XCTAssertTrue(model.hasADB)
        await transport.finish()
        await refresh.value
        XCTAssertFalse(model.isBusy)
    }
}

private actor PausedDeviceTransport: DeviceTransport {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<[AndroidDevice], any Error>?

    func connectedDevices() async throws -> [AndroidDevice] {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() { response?.resume(returning: []); response = nil }
}
