import Foundation
import CryptoKit
import XCTest
@testable import PhoneBackupCore

final class ADBTransportTests: XCTestCase {
    func testDiscoversConnectedUnauthorizedAndOfflineDevices() async throws {
        let runner = StubCommandRunner(outputs: [CommandOutput(
            data: Data("List of devices attached\nphone-1\tdevice product:pixel model:Pixel_9\nphone-2\tunauthorized\nphone-3\toffline\n\n".utf8),
            standardError: Data("* daemon not running; starting now at tcp:5037\n* daemon started successfully\n".utf8),
            exitCode: 0
        )])
        let transport = try makeTransport(runner: runner)

        let devices = try await transport.connectedDevices()

        XCTAssertEqual(devices.map(\.id.serial), ["phone-1", "phone-2", "phone-3"])
        XCTAssertEqual(devices.map(\.state), [.device, .unauthorized, .offline])
        XCTAssertEqual(devices[0].model, "Pixel_9")
        let calls = await runner.arguments()
        XCTAssertEqual(calls, [["devices", "-l"]])
    }

    func testListsOnlyImmediateChildrenAndQuotesSelectedPath() async throws {
        let root = try RemotePath("/sdcard/Dad's Pictures")
        let file = try root.appending("photo.jpg")
        let output = record("drwxrwx---", 4096, "1000.25", root)
            + record("-rw-rw----", 42, "1001.5", file)
        let runner = StubCommandRunner(outputs: [CommandOutput(data: output, exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        let entries = try await transport.children(of: root, on: device)

        XCTAssertEqual(entries, [RemoteEntry(path: file, kind: .file, size: 42, modifiedAt: Date(timeIntervalSince1970: 1001.5))])
        let calls = await runner.arguments()
        XCTAssertEqual(Array(calls[0].prefix(3)), ["-s", "phone-1", "shell"])
        XCTAssertTrue(calls[0].last?.contains("-maxdepth 1") == true)
        XCTAssertTrue(calls[0].last?.contains("'\\''") == true)
        XCTAssertFalse(calls[0].last?.contains("-maxdepth 0") == true)
    }

    func testListingPreservesPipesAndNewlinesInFilenames() async throws {
        let root = try RemotePath("/sdcard/Photos")
        let first = try root.appending("line\nbreak.jpg")
        let second = try root.appending("part|name.jpg")
        let output = record("-rw-r--r--", 10, "1000", first) + record("-rw-r--r--", 11, "1001", second)
        let transport = try makeTransport(runner: StubCommandRunner(outputs: [CommandOutput(data: output, exitCode: 0)]))
        let device = try DeviceID(serial: "phone-1")

        let entries = try await transport.children(of: root, on: device)

        XCTAssertEqual(Set(entries.map(\.path)), Set([first, second]))
    }

    func testMetadataReadsSingleSelectedEntry() async throws {
        let path = try RemotePath("/sdcard/Dad's Pictures/image.jpg")
        let runner = StubCommandRunner(outputs: [CommandOutput(
            data: record("-rw-rw----", 42, "1001.5", path), exitCode: 0
        )])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        let entry = try await transport.metadata(of: path, on: device)

        XCTAssertEqual(entry, RemoteEntry(path: path, kind: .file, size: 42,
                                          modifiedAt: Date(timeIntervalSince1970: 1001.5)))
        let calls = await runner.arguments()
        XCTAssertEqual(Array(calls[0].prefix(3)), ["-s", "phone-1", "shell"])
        XCTAssertTrue(calls[0].last?.contains("-maxdepth 0") == true)
        XCTAssertTrue(calls[0].last?.contains("'\\''") == true)
    }

    func testDestinationInspectionDoesNotFollowFinalSymlinkAndQuotesPath() async throws {
        let path = try RemotePath("/sdcard/Dad's Pictures/link")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("L|253:17:0:100".utf8), exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        let state = try await transport.inspectDestination(path, on: device)

        XCTAssertEqual(state, .symbolicLink(identity: "253:17:0:100"))
        let calls = await runner.arguments()
        XCTAssertTrue(calls[0].last?.contains("[ -L '") == true)
        XCTAssertTrue(calls[0].last?.contains("'\\''") == true)
    }

    func testDestinationBatchQuotesPathsAndPreservesIdentityWhitespace() async throws {
        let paths = try ["/sdcard/Dad's Pictures/line\nbreak|$(noop).jpg", "/sdcard/Other"].map(RemotePath.init)
        let identity = "253:17:42:2026-01-01 00:00:00.000000000 +0000"
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("F|\(identity)\0M\0".utf8), exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let states = try await transport.inspectDestinations(paths, on: DeviceID(serial: "phone-1"))
        XCTAssertEqual(states[paths[0]], .regularFile(identity: identity, size: 42))
        XCTAssertEqual(states[paths[1]], .missing)
        let calls = await runner.arguments()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].last?.contains("'\\''") == true)
        XCTAssertTrue(calls[0].last?.contains("\"$(stat") == true, "Stat command substitution must stay quoted")
    }

    func testDestinationBatchesBoundPathCountAndCommandBytes() async throws {
        let device = try DeviceID(serial: "phone-1")
        let runner = StubCommandRunner(outputs: [64, 64, 2].map {
            CommandOutput(data: Data(String(repeating: "M\0", count: $0).utf8), exitCode: 0)
        })
        let transport = try makeTransport(runner: runner)
        let paths = try (0..<130).map { try RemotePath("/sdcard/file-\($0)") }
        let states = try await transport.inspectDestinations(paths, on: device)
        XCTAssertEqual(states.count, 130)
        let calls = await runner.arguments()
        XCTAssertEqual(calls.count, 3)

        // Twelve 2KB paths fit the byte budget; a thirteenth starts a new command.
        let longRunner = StubCommandRunner(outputs: [12, 8].map {
            CommandOutput(data: Data(String(repeating: "M\0", count: $0).utf8), exitCode: 0)
        })
        let longTransport = try makeTransport(runner: longRunner)
        let longPaths = try (0..<20).map { try RemotePath("/sdcard/\(String(repeating: "x", count: 1950))/\($0)") }
        let longStates = try await longTransport.inspectDestinations(longPaths, on: device)
        XCTAssertEqual(longStates.count, 20)
        let longCalls = await longRunner.arguments()
        XCTAssertEqual(longCalls.count, 2)
        XCTAssertTrue(longCalls.allSatisfy { ($0.last?.utf8.count ?? 0) < 25_000 })
    }

    func testDestinationBatchRejectsTruncatedExtraAndUnknownRecords() async throws {
        for output in ["M", "M\0M\0", "Q|1:2:3:date\0", "F|bad\0", "F|1:2:-1:date\0"] {
            let transport = try makeTransport(runner: StubCommandRunner(outputs: [CommandOutput(data: Data(output.utf8), exitCode: 0)]))
            do {
                _ = try await transport.inspectDestinations([RemotePath("/sdcard/file")], on: DeviceID(serial: "phone-1"))
                XCTFail("Malformed batch should fail: \(output.debugDescription)")
            } catch let error as EngineError {
                guard case .transport = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testRemotePublicationVerifiesStagingAndUsesExclusiveLink() async throws {
        let path = try RemotePath("/sdcard/RestoreTrial/photo.jpg")
        let bytes = Data("verified remote data".utf8)
        let expected = ContentObjectReference(sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                                              size: Int64(bytes.count))
        let outputs = [
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
            CommandOutput(data: Data("D|253:17:0:2026-01-01 00:00:00.000000000 +0000".utf8), exitCode: 0),
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
        ]
        let runner = StubCommandRunner(outputs: outputs, pullResponse: bytes)
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await transport.publishStagedFile(from: source, to: path, on: device, expected: expected, replacing: nil)

        let calls = await runner.arguments()
        XCTAssertEqual(calls.count, 9)
        XCTAssertTrue(calls[2].contains("push"))
        XCTAssertTrue(calls[3].contains("pull"))
        XCTAssertTrue(calls[6].last?.contains("ln -T") == true)
        XCTAssertFalse(calls[6].last?.contains("mv -f") == true)
        XCTAssertTrue(calls[7].contains("pull"))
    }

    func testRemotePublicationCleansStageAfterPushFailure() async throws {
        let path = try RemotePath("/sdcard/RestoreTrial/photo.jpg")
        let runner = StubCommandRunner(outputs: [
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data(), standardError: Data("push failed".utf8), exitCode: 1),
            CommandOutput(data: Data(), exitCode: 0),
        ])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("data".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try await transport.publishStagedFile(from: source, to: path, on: device,
                                                  expected: ContentObjectReference(sha256: String(repeating: "a", count: 64), size: 4),
                                                  replacing: nil)
            XCTFail("Expected the injected push failure")
        } catch let error as EngineError {
            guard case .transport = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let calls = await runner.arguments()
        XCTAssertTrue(calls.last?.last?.contains("rm -f") == true)
    }

    func testPermissionDeniedListingIsStructuredForThatPath() async throws {
        let path = try RemotePath("/sdcard/Android/data")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("find: /sdcard/Android/data: Permission denied".utf8), exitCode: 1)])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        do {
            _ = try await transport.children(of: path, on: device)
            XCTFail("Expected a permission error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .inaccessiblePath(path))
        }
    }

    func testListingAFileAsADirectoryReturnsStructuredError() async throws {
        let path = try RemotePath("/sdcard/photo.jpg")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: record("-rw-r--r--", 10, "1000", path), exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        do {
            _ = try await transport.children(of: path, on: device)
            XCTFail("Expected a not-directory error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .notDirectory(path))
        }
    }

    func testDisconnectedSelectedDeviceReturnsReconnectError() async throws {
        let runner = StubCommandRunner(outputs: [CommandOutput(
            data: Data(), standardError: Data("adb: device 'phone-1' not found".utf8), exitCode: 1
        )])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        do {
            _ = try await transport.children(of: RemotePath.root, on: device)
            XCTFail("Expected a device unavailable error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(device))
        }
    }

    func testTransferCommandsBindToSelectedDeviceSerial() async throws {
        let runner = StubCommandRunner(outputs: [
            CommandOutput(data: Data(), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0)
        ])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-2")
        let remote = try RemotePath("/sdcard/photo.jpg")
        let local = URL(fileURLWithPath: "/tmp/photo.jpg")

        try await transport.pull(from: remote, on: device, to: local)
        try await transport.push(from: local, to: remote, on: device)

        let calls = await runner.arguments()
        XCTAssertEqual(calls, [
            ["-s", "phone-2", "pull", "/sdcard/photo.jpg", "/tmp/photo.jpg"],
            ["-s", "phone-2", "push", "/tmp/photo.jpg", "/sdcard/photo.jpg"]
        ])
    }

    func testResolverFindsADBInConfiguredAndroidSDK() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ADBExecutableResolver.resolve(
            environment: ["ANDROID_HOME": root.path, "PATH": ""], fileManager: .default
        )

        XCTAssertEqual(resolved, executable.standardizedFileURL)
    }

    func testResolverRecoversManagedInstallUsingInjectedHomeDirectory() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let managed = home.appendingPathComponent("Library/Application Support/Androdo/Platform Tools/current/platform-tools/adb")
        let sdk = home.appendingPathComponent("Library/Android/sdk/platform-tools/adb")
        try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sdk.deletingLastPathComponent(), withIntermediateDirectories: true)
        for executable in [managed, sdk] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = ADBExecutableResolver.resolve(
            environment: ["ANDROID_HOME": sdk.deletingLastPathComponent().deletingLastPathComponent().path, "PATH": "relative/bin"],
            homeDirectory: home
        )

        XCTAssertEqual(resolved, managed.standardizedFileURL)
    }

    func testResolverFallsBackWhenSavedADBNoLongerExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = root.appendingPathComponent("platform-tools/adb")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ADBExecutableResolver.resolve(
            preferredExecutable: root.appendingPathComponent("removed-adb"),
            environment: ["ANDROID_HOME": root.path, "ANDROID_SDK_ROOT": root.path, "PATH": ""]
        )

        XCTAssertEqual(resolved, executable.standardizedFileURL)
    }

    func testResolverDoesNotAcceptADirectoryAsADBExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(ADBExecutableResolver.isExecutableFile(at: root))
    }

    func testUnsupportedFindFormatIsRememberedPerDevice() async throws {
        let path = try RemotePath("/sdcard")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("find: unknown option -printf".utf8), exitCode: 1)])
        let transport = try makeTransport(runner: runner)
        let device = try DeviceID(serial: "phone-1")

        for _ in 0..<2 {
            do {
                _ = try await transport.children(of: path, on: device)
                XCTFail("Expected unsupported directory listing")
            } catch let error as EngineError {
                XCTAssertEqual(error, .unsupportedDirectoryListing(device))
            }
        }
        let calls = await runner.arguments()
        XCTAssertEqual(calls.count, 1)
    }

    func testSystemRunnerTimesOutAndRespondsToCancellation() async throws {
        let runner = ProcessCommandRunner()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05)
            XCTFail("Expected process timeout")
        } catch let error as EngineError {
            XCTAssertEqual(error, .operationTimedOut)
        }

        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testSystemRunnerDrainsExactAndLargeCommandOutput() async throws {
        let runner = ProcessCommandRunner()
        for _ in 0..<10 {
            let output = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "quick output"], timeout: 2
            )
            XCTAssertEqual(output.data, Data("quick output".utf8))
        }

        let largeOutput = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "131072", "/dev/zero"], timeout: 2
        )
        XCTAssertEqual(largeOutput.data.count, 131_072)
        XCTAssertTrue(largeOutput.data.allSatisfy { $0 == 0 })
    }

    private func makeTransport(runner: any CommandRunning) throws -> ADBTransport {
        ADBTransport(configuration: try ADBConfiguration(executable: URL(fileURLWithPath: "/test/adb")), runner: runner)
    }

    private func record(_ mode: String, _ size: Int64, _ mtime: String, _ path: RemotePath) -> Data {
        Data("\(mode)|\(size)|\(mtime)|\(path.description)\0".utf8)
    }
}

private actor StubCommandRunner: CommandRunning {
    private var outputs: [CommandOutput]
    private var calls: [[String]] = []
    private let pullResponse: Data?

    init(outputs: [CommandOutput], pullResponse: Data? = nil) {
        self.outputs = outputs
        self.pullResponse = pullResponse
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        calls.append(arguments)
        if arguments.count >= 5, arguments[2] == "pull", let pullResponse {
            try pullResponse.write(to: URL(fileURLWithPath: arguments[4]))
        }
        guard !outputs.isEmpty else { throw EngineError.transport("Unexpected command") }
        return outputs.removeFirst()
    }

    func arguments() -> [[String]] { calls }
}
