import Foundation
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

    init(outputs: [CommandOutput]) {
        self.outputs = outputs
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        calls.append(arguments)
        guard !outputs.isEmpty else { throw EngineError.transport("Unexpected command") }
        return outputs.removeFirst()
    }

    func arguments() -> [[String]] { calls }
}
