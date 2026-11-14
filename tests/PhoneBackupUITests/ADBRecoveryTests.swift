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
        var attemptedResolution = false
        let suite = "PhoneBackupUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let model = AppModel(services: AppServices(repositoryStore: FakeBackupRepositoryStore(),
                                                    deviceTransport: transport),
                             preferences: preferences,
                             loadOnStart: false, adbResolver: { _ in attemptedResolution = true; return nil })
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: executable) }

        let refresh = Task { await model.refreshDevices() }
        await transport.waitUntilStarted()
        XCTAssertTrue(model.isBusy)

        model.locateADB(at: executable)
        await model.recheckADB()

        XCTAssertFalse(attemptedResolution)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(preferences.adbExecutablePath)
        XCTAssertTrue(model.hasADB)
        await transport.finish()
        await refresh.value
        XCTAssertFalse(model.isBusy)
    }

    func testRecheckFindsNewInstallationWithoutOpeningPhoneFoldersAndKeepsRepository() async throws {
        let fixture = try RecheckFixture()
        defer { fixture.cleanup() }
        await fixture.model.recheckADB()
        XCTAssertFalse(fixture.model.hasADB)
        XCTAssertNotNil(fixture.model.errorMessage)

        try fixture.install()
        let id = fixtureIdentity.deviceID
        let selection = BackupSelection(scope: .selected([try RemotePath("/sdcard/Pictures")]))
        fixture.preferences.save(selection, for: id)
        let repository = BackupRepositoryInfo(location: fixture.root.appendingPathComponent("PhoneBackup/device-fixture"),
                                               deviceID: id, displayName: "Fixture")
        await fixture.store.seed(repository: repository)

        await fixture.model.recheckADB()

        XCTAssertTrue(fixture.model.hasADB)
        XCTAssertNil(fixture.model.errorMessage)
        XCTAssertEqual(fixture.model.selectedDevice?.id, id)
        XCTAssertEqual(fixture.preferences.adbExecutablePath, fixture.executable.path)
        XCTAssertEqual(fixture.model.backupSelection, selection)
        try fixture.assertDiscoveryOnly(commands: fixture.commands())
        let readableRepositories = try await fixture.store.openRepositories(in: fixture.root)
        XCTAssertEqual(readableRepositories, [repository])
    }

    func testRecheckReplacesStaleSavedPathWithResolvedInstallation() async throws {
        let fixture = try RecheckFixture()
        defer { fixture.cleanup() }
        fixture.preferences.adbExecutablePath = "/missing/platform-tools/adb"
        try fixture.install()

        await fixture.model.recheckADB()

        XCTAssertEqual(fixture.preferences.adbExecutablePath, fixture.executable.path)
        XCTAssertTrue(fixture.model.hasADB)
        XCTAssertNil(fixture.model.errorMessage)
        try fixture.assertDiscoveryOnly(commands: fixture.commands())
    }

    func testRecheckKeepsTheOpenListingWhenRebindingTheSameDevice() async throws {
        let id = fixtureIdentity.deviceID
        let transport = FakeDeviceTransport(devices: [fixtureDevice(id: id, state: .device)])
        let folder = try RemotePath("/sdcard/Pictures")
        let file = try folder.appending("fixture.jpg")
        await transport.seed(RemoteEntry(path: file, kind: .file, size: 3), on: id, data: Data([1, 2, 3]))
        let fixture = try RecheckFixture(initialTransport: transport)
        defer { fixture.cleanup() }
        await fixture.model.refreshDevices()
        await fixture.model.fileBrowser.navigate(to: folder)
        fixture.model.fileBrowser.selection = [file]
        try fixture.install()

        // First replace the original transport, then recheck the now-unchanged executable.
        await fixture.model.recheckADB()
        await fixture.model.recheckADB()

        XCTAssertEqual(fixture.model.fileBrowser.currentDirectory, folder)
        XCTAssertEqual(fixture.model.fileBrowser.entries.map(\.path), [file])
        XCTAssertEqual(fixture.model.fileBrowser.selection, [file])
        try fixture.assertDiscoveryOnly(commands: fixture.commands(), refreshCount: 2)
        let listed = await transport.recordedChildrenCalls(on: id)
        XCTAssertEqual(listed, [folder])
    }

    func testRecheckReportsDiscoveryFailureWithoutClaimingConnectionSuccess() async throws {
        let fixture = try RecheckFixture()
        defer { fixture.cleanup() }
        try fixture.install(fails: true)

        await fixture.model.recheckADB()

        XCTAssertNotNil(fixture.model.errorMessage)
        XCTAssertNil(fixture.model.selectedDevice)
        XCTAssertFalse(fixture.model.isBusy)
        XCTAssertEqual(try fixture.commands(), ["devices -l"])
    }

}

private let fixtureIdentity = try! DeviceIdentityEvidence(
    serialNumber: "setup-fixture", manufacturer: "Google", model: "Fixture"
)

private actor PausedDeviceTransport: DeviceTransport {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var response: CheckedContinuation<DeviceDiscoveryResult, any Error>?

    func connectedDevices() async throws -> DeviceDiscoveryResult {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        return try await withCheckedThrowingContinuation { response = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish() { response?.resume(returning: DeviceDiscoveryResult(devices: [])); response = nil }
}


/// The only executable this resolver can return is a test-owned shell fixture.
/// It never searches the host's installed ADB or touches a connected phone.
@MainActor
private struct RecheckFixture {
    let root: URL
    let executable: URL
    let preferences: AppPreferences
    let store: FakeBackupRepositoryStore
    let model: AppModel
    private let defaults: UserDefaults
    private let suite: String

    init(initialTransport: FakeDeviceTransport? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("adb")
        suite = "AndrodoSetupTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults)
        store = FakeBackupRepositoryStore()
        let candidate = executable
        model = AppModel(services: AppServices(repositoryStore: store, deviceTransport: initialTransport,
                                                     remoteAccess: initialTransport), preferences: preferences,
                         loadOnStart: false, adbResolver: { _ in
            ADBExecutableResolver.isExecutableFile(at: candidate) ? candidate : nil
        })
    }

    func install(fails: Bool = false) throws {
        let script = """
        #!/bin/sh
        printf '%s\n' "$*" >> "$(dirname "$0")/calls"
        if [ "$1" = devices ] && [ "$2" = -l ] && [ "$#" -eq 2 ]; then
          \(fails ? "exit 1" : "printf 'List of devices attached\nsetup-fixture device transport_id:41 model:Fixture\n'")
        elif [ "$1" = -t ] && [ "$2" = 41 ] && [ "$3" = shell ] && [ "$4" = -T ]; then
          printf 'ANDRODO_SHELL_V2_STDOUT'
          printf 'ANDRODO_SHELL_V2_STDERR' >&2
          exit 73
        elif [ "$1" = -t ] && [ "$2" = 41 ] && [ "$3" = shell ]; then
          printf 'setup-fixture\\000Google\\000Fixture\\000'
        elif [ "$1" = -t ] && [ "$2" = 41 ] && [ "$3" = get-devpath ]; then
          printf '/dev/bus/usb/001/001\\n'
        else
          exit 91
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func assertDiscoveryOnly(commands: [String], refreshCount: Int = 1,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let expectedCallCount = refreshCount * 4
        XCTAssertEqual(commands.count, expectedCallCount, file: file, line: line)
        for offset in stride(from: 0, to: commands.count, by: 4) {
            XCTAssertEqual(commands[offset], "devices -l", file: file, line: line)
            XCTAssertTrue(commands[offset + 1].hasPrefix("-t 41 shell "), file: file, line: line)
            XCTAssertEqual(commands[offset + 2], "-t 41 get-devpath", file: file, line: line)
            XCTAssertTrue(commands[offset + 3].hasPrefix("-t 41 shell -T "), file: file, line: line)
        }
        let forbiddenOperations = ["find ", "ls ", "cat ", "pull ", "push "]
        XCTAssertFalse(commands.contains { command in
            forbiddenOperations.contains { command.contains($0) }
        }, "Discovery must not list, read, pull, or write phone files.", file: file, line: line)
    }

    func commands() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
