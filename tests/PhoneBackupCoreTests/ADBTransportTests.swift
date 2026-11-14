import Foundation
import Darwin
import CryptoKit
import XCTest
@testable import PhoneBackupCore

final class ADBTransportTests: XCTestCase {
    func testIdentityFingerprintIsVersionedAndLengthFramed() throws {
        let first = try DeviceIdentityEvidence(serialNumber: "ab", manufacturer: "c", model: "Pixel")
        let second = try DeviceIdentityEvidence(serialNumber: "a", manufacturer: "bc", model: "Pixel")

        XCTAssertTrue(first.deviceID.value.hasPrefix("android-device:v1:"))
        XCTAssertNotEqual(first.deviceID, second.deviceID)
        XCTAssertFalse(first.deviceID.description.contains("ab"))
    }

    func testIdentityEvidenceRejectsMalformedPlaceholderAndOversizedProperties() throws {
        XCTAssertThrowsError(try DeviceIdentityEvidence.parse(Data("serial\0Google\0".utf8)))
        XCTAssertThrowsError(try DeviceIdentityEvidence.parse(Data("serial\0Google\0Pixel\0extra\0".utf8)))
        XCTAssertThrowsError(try DeviceIdentityEvidence(serialNumber: "unknown", manufacturer: "Google", model: "Pixel"))
        XCTAssertThrowsError(try DeviceIdentityEvidence(serialNumber: "serial", manufacturer: "Google",
                                                        model: String(repeating: "p", count: 257)))
    }

    func testDiscoversConnectedUnauthorizedAndOfflineDevices() async throws {
        let runner = StubCommandRunner(outputs: [], deviceList: Data(
            "List of devices attached\nphone-1\tdevice transport_id:41 product:pixel model:Pixel_9\nphone-2\tunauthorized\nphone-3\toffline\n\n".utf8
        ))
        let transport = try makeTransport(runner: runner)

        let discovery = try await transport.connectedDevices()

        XCTAssertEqual(discovery.devices.count, 1)
        XCTAssertEqual(discovery.devices[0].id, try DeviceIdentityEvidence(
            serialNumber: "stable-serial", manufacturer: "Google", model: "Pixel 9").deviceID)
        XCTAssertEqual(discovery.devices[0].state, .device)
        XCTAssertEqual(discovery.devices[0].model, "Pixel 9")
        XCTAssertEqual(discovery.issues.map(\.kind), [.unauthorized, .offline])
        let calls = await runner.arguments()
        XCTAssertEqual(calls.map { Array($0.prefix(1)) }, [["devices"], ["-t"], ["-t"], ["-t"]])
    }

    func testUSBAndWirelessRoutesResolveToOneStableDeviceAndNeverPersistSelectors() async throws {
        let listing = Data("List of devices attached\nusb-route device transport_id:41 product:pixel model:Pixel_9\n192.168.1.42:5555 device transport_id:42 product:pixel model:Pixel_9\n".utf8)
        let runner = StubCommandRunner(outputs: [], deviceList: listing, wirelessTransportIDs: [42])
        let transport = try makeTransport(runner: runner)

        let firstDiscovery = try await transport.connectedDevices()
        let device = try XCTUnwrap(firstDiscovery.devices.first)
        XCTAssertEqual(firstDiscovery.devices.count, 1)
        XCTAssertEqual(device.sessions.map(\.connection.kind), [.usb, .wireless])
        XCTAssertEqual(device.preferredSession?.connection.kind, .usb)
        let wirelessSession = try XCTUnwrap(device.sessions.first { $0.connection.kind == .wireless })
        let wirelessGeneration = wirelessSession.connection.generation

        let refreshed = try await transport.connectedDevices()
        XCTAssertEqual(refreshed.devices.first?.id, device.id)
        XCTAssertEqual(refreshed.devices.first?.sessions.first { $0.connection.kind == .wireless }?.connection.generation,
                       wirelessGeneration)

        await runner.setDeviceList(Data("List of devices attached\n192.168.1.42:5555 device transport_id:42\n".utf8))
        let wirelessOnly = try await transport.connectedDevices()
        let reconnected = try XCTUnwrap(wirelessOnly.devices.first)
        XCTAssertEqual(reconnected.id, device.id)
        XCTAssertEqual(reconnected.preferredSession?.connection.kind, .wireless)
        XCTAssertEqual(reconnected.preferredSession?.connection.generation, wirelessGeneration)

        let encoded = String(decoding: try JSONEncoder().encode(device), as: UTF8.self)
        XCTAssertFalse(encoded.contains("stable-serial"))
        XCTAssertFalse(encoded.contains("192.168.1.42"))
        XCTAssertFalse(encoded.contains("usb-route"))
        XCTAssertFalse(encoded.contains("Pixel 9"))
        XCTAssertFalse(encoded.contains("pixel"))
        XCTAssertEqual(device.id.description, "Android device")
        XCTAssertFalse(String(describing: wirelessSession).contains("192.168.1.42"))
        XCTAssertFalse(String(reflecting: wirelessSession).contains("stable-serial"))

        do {
            _ = try await transport.children(of: RemotePath.root, on: try XCTUnwrap(device.sessions.first))
            XCTFail("A vanished USB session must not silently switch to Wi-Fi")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(device.id))
        }

        await runner.setIdentity(42, serialNumber: "different-phone-serial", manufacturer: "Google", model: "Pixel 9")
        let reusedEndpoint = try await transport.connectedDevices()
        XCTAssertNotEqual(reusedEndpoint.devices.first?.id, device.id)
        do {
            _ = try await transport.children(of: RemotePath.root, on: wirelessSession)
            XCTFail("An endpoint reused by another phone must not be treated as the original session")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(device.id))
        }
    }

    func testDifferentPhonesWithTheSameModelRemainSeparate() async throws {
        let listing = Data("List of devices attached\nusb-one device transport_id:41\nwifi-two device transport_id:42\n".utf8)
        let runner = StubCommandRunner(outputs: [], deviceList: listing,
                                       wirelessTransportIDs: [42],
                                       identitiesByTransportID: [
                                           41: ("serial-one", "Google", "Pixel 9"),
                                           42: ("serial-two", "Google", "Pixel 9")
                                       ])
        let transport = try makeTransport(runner: runner)

        let discovery = try await transport.connectedDevices()

        XCTAssertEqual(discovery.devices.count, 2)
        XCTAssertEqual(Set(discovery.devices.compactMap(\.model)), ["Pixel 9"])
        XCTAssertEqual(Set(discovery.devices.map(\.id)).count, 2)
    }

    func testMissingOrPlaceholderIdentityBlocksDeviceOperations() async throws {
        let runner = StubCommandRunner(outputs: [], identitiesByTransportID: [41: ("unknown", "Google", "Pixel 9")])
        let transport = try makeTransport(runner: runner)

        let discovery = try await transport.connectedDevices()

        XCTAssertTrue(discovery.devices.isEmpty)
        XCTAssertEqual(discovery.issues.map(\.kind), [.identityUnavailable])
    }

    func testMissingShellV2SupportBlocksGuardedFileTransfers() async throws {
        let runner = StubCommandRunner(outputs: [], supportsShellV2Protocol: false)
        let transport = try makeTransport(runner: runner)

        let discovery = try await transport.connectedDevices()

        XCTAssertTrue(discovery.devices.isEmpty)
        XCTAssertEqual(discovery.issues.map(\.kind), [.transferProtocolUnavailable])
    }

    func testChangedIdentityOnCapturedSessionBlocksTransferBeforePull() async throws {
        let runner = StubCommandRunner(outputs: [])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        await runner.setIdentity(41, serialNumber: "replacement-phone", manufacturer: "Google", model: "Pixel 9")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("must not reach another phone".utf8).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: source)
        }

        do {
            try await transport.pull(from: RemotePath("/sdcard/photo.jpg"), on: session, to: local)
            XCTFail("A mismatched phone must be rejected before reading a file")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(session.deviceID))
        }
        do {
            try await transport.push(from: source, to: RemotePath("/sdcard/should-not-be-written"), on: session)
            XCTFail("A mismatched phone must be rejected before upload bytes are sent")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(session.deviceID))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        let transferredInputs = await runner.streamedInputs()
        XCTAssertTrue(transferredInputs.isEmpty)
        let calls = await runner.arguments()
        XCTAssertFalse(calls.contains { $0.count > 2 && $0[2] == "pull" })
    }

    func testPullDoesNotDeleteFileCreatedAfterDestinationPreflight() async throws {
        let runner = StubCommandRunner(outputs: [])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let competingFile = Data("created by another writer".utf8)
        defer { try? FileManager.default.removeItem(at: local) }
        await runner.setOutputRaceContents(competingFile)

        do {
            try await transport.pull(from: RemotePath("/sdcard/photo.jpg"), on: session, to: local)
            XCTFail("The transfer should fail after another file wins the destination race")
        } catch let error as EngineError {
            XCTAssertEqual(error, .transport("simulated transfer failure"))
        }
        XCTAssertEqual(try Data(contentsOf: local), competingFile)
    }

    func testInlineIdentityMismatchIsReportedAsDisconnectedDevice() async throws {
        let marker = Data("ANDRODO_DEVICE_IDENTITY_MISMATCH".utf8)
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data(), standardError: marker, exitCode: 125)])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)

        do {
            _ = try await transport.children(of: RemotePath("/sdcard"), on: session)
            XCTFail("A phone that fails the inline identity check must be rejected")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(session.deviceID))
        }
    }

    func testDiscoveryCancellationDoesNotReplaceActiveSessionsOrBecomeAnIdentityIssue() async throws {
        let folder = try RemotePath("/sdcard")
        let runner = StubCommandRunner(outputs: [CommandOutput(
            data: record("drwxrwx---", 4096, "1000", folder), exitCode: 0
        )])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)

        await runner.cancelNextIdentityProbe()
        do {
            _ = try await transport.connectedDevices()
            XCTFail("Discovery cancellation must propagate")
        } catch is CancellationError {
            // expected
        }

        await runner.cancelNextConnectionKindProbe()
        do {
            _ = try await transport.connectedDevices()
            XCTFail("Route classification cancellation must propagate")
        } catch is CancellationError {
            // expected
        }

        let entries = try await transport.children(of: folder, on: session)
        XCTAssertTrue(entries.isEmpty)
        let calls = await runner.arguments()
        XCTAssertFalse(calls.contains { $0.count > 2 && $0[2] == "pull" })
    }

    func testListsOnlyImmediateChildrenAndQuotesSelectedPath() async throws {
        let root = try RemotePath("/sdcard/Dad's Pictures")
        let file = try root.appending("photo.jpg")
        let output = record("drwxrwx---", 4096, "1000.25", root)
            + record("-rw-rw----", 42, "1001.5", file)
        let runner = StubCommandRunner(outputs: [CommandOutput(data: output, exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)

        let entries = try await transport.children(of: root, on: session)

        XCTAssertEqual(entries, [RemoteEntry(path: file, kind: .file, size: 42, modifiedAt: Date(timeIntervalSince1970: 1001.5))])
        let calls = await runner.arguments()
        let listingCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(Array(listingCall.prefix(3)), ["-t", "41", "shell"])
        XCTAssertTrue(listingCall.last?.contains("-maxdepth 1") == true)
        XCTAssertTrue(listingCall.last?.contains("'\\''") == true)
        XCTAssertFalse(listingCall.last?.contains("-maxdepth 0") == true)
    }

    func testListingPreservesPipesAndNewlinesInFilenames() async throws {
        let root = try RemotePath("/sdcard/Photos")
        let first = try root.appending("line\nbreak.jpg")
        let second = try root.appending("part|name.jpg")
        let output = record("-rw-r--r--", 10, "1000", first) + record("-rw-r--r--", 11, "1001", second)
        let transport = try makeTransport(runner: StubCommandRunner(outputs: [CommandOutput(data: output, exitCode: 0)]))
        let session = try await connectedSession(transport)

        let entries = try await transport.children(of: root, on: session)

        XCTAssertEqual(Set(entries.map(\.path)), Set([first, second]))
    }

    func testMetadataReadsSingleSelectedEntry() async throws {
        let path = try RemotePath("/sdcard/Dad's Pictures/image.jpg")
        let runner = StubCommandRunner(outputs: [CommandOutput(
            data: record("-rw-rw----", 42, "1001.5", path), exitCode: 0
        )])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)

        let entry = try await transport.metadata(of: path, on: session)

        XCTAssertEqual(entry, RemoteEntry(path: path, kind: .file, size: 42,
                                          modifiedAt: Date(timeIntervalSince1970: 1001.5)))
        let calls = await runner.arguments()
        let metadataCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(Array(metadataCall.prefix(3)), ["-t", "41", "shell"])
        XCTAssertTrue(metadataCall.last?.contains("-maxdepth 0") == true)
        XCTAssertTrue(metadataCall.last?.contains("'\\''") == true)
    }

    func testDestinationInspectionDoesNotFollowFinalSymlinkAndQuotesPath() async throws {
        let path = try RemotePath("/sdcard/Dad's Pictures/link")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("L|253:17:0:100".utf8), exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)

        let state = try await transport.inspectDestination(path, on: session)

        XCTAssertEqual(state, .symbolicLink(identity: "253:17:0:100"))
        let calls = await runner.arguments()
        XCTAssertTrue(calls.last?.last?.contains("[ -L '") == true)
        XCTAssertTrue(calls.last?.last?.contains("'\\''") == true)
    }

    func testDestinationBatchQuotesPathsAndPreservesIdentityWhitespace() async throws {
        let paths = try ["/sdcard/Dad's Pictures/line\nbreak|$(noop).jpg", "/sdcard/Other"].map(RemotePath.init)
        let identity = "253:17:42:2026-01-01 00:00:00.000000000 +0000"
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("F|\(identity)\0M\0".utf8), exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        let states = try await transport.inspectDestinations(paths, on: session)
        XCTAssertEqual(states[paths[0]], .regularFile(identity: identity, size: 42))
        XCTAssertEqual(states[paths[1]], .missing)
        let calls = await runner.arguments()
        let commands = remoteCommands(in: calls)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].last?.contains("'\\''") == true)
        XCTAssertTrue(commands[0].last?.contains("\"$(stat") == true, "Stat command substitution must stay quoted")
    }

    func testDestinationBatchesBoundPathCountAndCommandBytes() async throws {
        let runner = StubCommandRunner(outputs: [64, 64, 2].map {
            CommandOutput(data: Data(String(repeating: "M\0", count: $0).utf8), exitCode: 0)
        })
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        let paths = try (0..<130).map { try RemotePath("/sdcard/file-\($0)") }
        let states = try await transport.inspectDestinations(paths, on: session)
        XCTAssertEqual(states.count, 130)
        let calls = await runner.arguments()
        XCTAssertEqual(remoteCommands(in: calls).count, 3)

        // Twelve 2KB paths fit the byte budget; a thirteenth starts a new command.
        let longRunner = StubCommandRunner(outputs: [12, 8].map {
            CommandOutput(data: Data(String(repeating: "M\0", count: $0).utf8), exitCode: 0)
        })
        let longTransport = try makeTransport(runner: longRunner)
        let longSession = try await connectedSession(longTransport)
        let longPaths = try (0..<20).map { try RemotePath("/sdcard/\(String(repeating: "x", count: 1950))/\($0)") }
        let longStates = try await longTransport.inspectDestinations(longPaths, on: longSession)
        XCTAssertEqual(longStates.count, 20)
        let longCalls = await longRunner.arguments()
        XCTAssertEqual(remoteCommands(in: longCalls).count, 2)
        XCTAssertTrue(remoteCommands(in: longCalls).allSatisfy { ($0.last?.utf8.count ?? 0) < 25_000 })
    }

    func testDestinationBatchRejectsTruncatedExtraAndUnknownRecords() async throws {
        for output in ["M", "M\0M\0", "Q|1:2:3:date\0", "F|bad\0", "F|1:2:-1:date\0"] {
            let transport = try makeTransport(runner: StubCommandRunner(outputs: [CommandOutput(data: Data(output.utf8), exitCode: 0)]))
            let session = try await connectedSession(transport)
            do {
                _ = try await transport.inspectDestinations([RemotePath("/sdcard/file")], on: session)
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
            CommandOutput(data: Data("D|253:17:0:2026-01-01 00:00:00.000000000 +0000".utf8), exitCode: 0),
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
        ]
        let runner = StubCommandRunner(outputs: outputs, pullResponse: bytes)
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        try await transport.publishStagedFile(from: source, to: path, on: session, expected: expected, replacing: nil)

        let calls = await runner.arguments()
        let operations = adbOperationCommands(in: calls)
        XCTAssertEqual(operations.count, 9)
        XCTAssertEqual(Array(operations[2].prefix(4)), ["-t", "41", "shell", "-T"])
        XCTAssertEqual(Array(operations[3].prefix(4)), ["-t", "41", "shell", "-T"])
        XCTAssertTrue(operations[6].last?.contains("ln -T") == true)
        XCTAssertFalse(operations[6].last?.contains("mv -f") == true)
        XCTAssertEqual(Array(operations[7].prefix(4)), ["-t", "41", "shell", "-T"])
    }

    func testRemotePublicationCleansStageAfterPushFailure() async throws {
        let path = try RemotePath("/sdcard/RestoreTrial/photo.jpg")
        let runner = StubCommandRunner(outputs: [
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data("M".utf8), exitCode: 0),
            CommandOutput(data: Data(), exitCode: 0),
        ])
        await runner.failNextStream(standardError: Data("push failed".utf8), exitCode: 1)
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("data".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try await transport.publishStagedFile(from: source, to: path, on: session,
                                                  expected: ContentObjectReference(sha256: String(repeating: "a", count: 64), size: 4),
                                                  replacing: nil)
            XCTFail("Expected the injected push failure")
        } catch let error as EngineError {
            guard case .transport = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let calls = adbOperationCommands(in: await runner.arguments())
        XCTAssertTrue(calls.last?.last?.contains("rm -f") == true)
    }

    func testPermissionDeniedListingIsStructuredForThatPath() async throws {
        let path = try RemotePath("/sdcard/Android/data")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: Data("find: /sdcard/Android/data: Permission denied".utf8), exitCode: 1)])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        do {
            _ = try await transport.children(of: path, on: session)
            XCTFail("Expected a permission error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .inaccessiblePath(path))
        }
    }

    func testListingAFileAsADirectoryReturnsStructuredError() async throws {
        let path = try RemotePath("/sdcard/photo.jpg")
        let runner = StubCommandRunner(outputs: [CommandOutput(data: record("-rw-r--r--", 10, "1000", path), exitCode: 0)])
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        do {
            _ = try await transport.children(of: path, on: session)
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
        let session = try await connectedSession(transport)
        let device = session.deviceID

        do {
            _ = try await transport.children(of: RemotePath.root, on: session)
            XCTFail("Expected a device unavailable error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .deviceUnavailable(device))
        }
    }

    func testTransferCommandsBindToCapturedTransportID() async throws {
        let bytes = Data([0, 1, 2, 255, 0, 42])
        let runner = StubCommandRunner(outputs: [], pullResponse: bytes)
        let transport = try makeTransport(runner: runner)
        let session = try await connectedSession(transport)
        let remote = try RemotePath("/sdcard/photo.jpg")
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: local)
            try? FileManager.default.removeItem(at: source)
        }

        try await transport.pull(from: remote, on: session, to: local)
        try await transport.push(from: source, to: remote, on: session)
        XCTAssertEqual(try Data(contentsOf: local), bytes)

        let calls = await runner.arguments()
        let transfers = calls.filter {
            $0.count >= 5 && $0[0] == "-t" && $0[2] == "shell" && $0[3] == "-T"
                && !$0[4].contains("ANDRODO_SHELL_V2_STDOUT")
        }
        XCTAssertEqual(transfers.count, 2)
        XCTAssertTrue(transfers[0][4].contains("cat -- '/sdcard/photo.jpg'"))
        XCTAssertTrue(transfers[1][4].contains("ANDRODO_READY_TO_RECEIVE"))
        XCTAssertTrue(transfers.allSatisfy { $0[4].contains("getprop ro.serialno") })
        let transferredInputs = await runner.streamedInputs()
        XCTAssertEqual(transferredInputs, [bytes])
        let gates = await runner.streamGates()
        XCTAssertEqual(gates, [CommandInputGate(
            readyFrame: Data("ANDRODO_READY_TO_RECEIVE\n".utf8),
            approvalFrame: Data("ANDRODO_TRANSFER_APPROVED\n".utf8)
        )])
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
        let session = try await connectedSession(transport)
        let device = session.deviceID

        for _ in 0..<2 {
            do {
                _ = try await transport.children(of: path, on: session)
                XCTFail("Expected unsupported directory listing")
            } catch let error as EngineError {
                XCTAssertEqual(error, .unsupportedDirectoryListing(device))
            }
        }
        let calls = await runner.arguments()
        XCTAssertEqual(remoteCommands(in: calls).count, 1)
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

    func testProcessRunnerKeepsShellV2OutputChannelsAndExitStatusSeparate() async throws {
        let output = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'shell-v2-out'; printf 'shell-v2-err' >&2; exit 73"],
            timeout: 2
        )
        XCTAssertEqual(output.data, Data("shell-v2-out".utf8))
        XCTAssertEqual(output.standardError, Data("shell-v2-err".utf8))
        XCTAssertEqual(output.exitCode, 73)
    }

    func testProcessRunnerWritesBoundedMemoryInputToStandardInput() async throws {
        let code = "123456"
        let arguments = ["-c", "IFS= read -r value || exit 9; test ${#value} -eq 6 && printf accepted"]
        let output = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: arguments, timeout: 2,
            fileIO: CommandFileIO(inputData: Data((code + "\n").utf8))
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.data, Data("accepted".utf8))
        XCTAssertFalse(arguments.contains(code))

        let boundedOutput = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat >/dev/null; /usr/bin/head -c 8192 /dev/zero"], timeout: 2,
            fileIO: CommandFileIO(inputData: Data("end-of-input\n".utf8))
        )
        XCTAssertEqual(boundedOutput.exitCode, 0)
        XCTAssertEqual(boundedOutput.data.count, 4096)
        do {
            _ = try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 2,
                fileIO: CommandFileIO(inputData: Data(repeating: 1, count: 4097))
            )
            XCTFail("In-memory command input must be bounded")
        } catch let error as EngineError {
            XCTAssertEqual(error, .transport("Invalid ADB file transfer configuration"))
        }
    }

    func testProcessRunnerStripsADBTraceAndRemoteServerOverrides() async throws {
        let output = try await ProcessCommandRunner(environment: [
            "ADB_TRACE": "all", "ANDROID_LOG_TAGS": "*:D",
            "ADB_SERVER_SOCKET": "tcp:192.0.2.10:5037",
            "ANDROID_ADB_SERVER_ADDRESS": "192.0.2.10", "ANDROID_ADB_SERVER_PORT": "5038",
        ]).run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test -z \"${ADB_TRACE-}\" && test -z \"${ANDROID_LOG_TAGS-}\" && test -z \"${ADB_SERVER_SOCKET-}\" && test -z \"${ANDROID_ADB_SERVER_ADDRESS-}\" && test -z \"${ANDROID_ADB_SERVER_PORT-}\" && printf clean"], timeout: 2,
            fileIO: CommandFileIO(inputData: Data())
        )
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.data, Data("clean".utf8))
    }

    func testProcessRunnerRejectsFIFOAsUploadSource() async throws {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(fifo.path.withCString { Darwin.mkfifo($0, S_IRUSR | S_IWUSR) }, 0)
        defer { try? FileManager.default.removeItem(at: fifo) }
        let completed = DispatchSemaphore(value: 0)
        let transfer = Task {
            defer { completed.signal() }
            return try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 1,
                fileIO: CommandFileIO(inputFile: fifo)
            )
        }
        let completedWithoutWriter = await Task.detached {
            waitForSemaphore(completed, timeout: .now() + 1)
        }.value
        if !completedWithoutWriter {
            // Release a regressed blocking FIFO open so the test itself stays bounded.
            await Task.detached { openRescueWriter(for: fifo) }.value
            _ = await Task.detached { waitForSemaphore(completed, timeout: .now() + 1) }.value
        }
        XCTAssertTrue(completedWithoutWriter, "FIFO validation must finish without waiting for a writer")

        do {
            _ = try await transfer.value
            XCTFail("Named pipes must not be accepted as upload sources")
        } catch let error as EngineError {
            XCTAssertTrue(String(describing: error).contains("regular file"))
        }
    }

    func testProcessRunnerStreamsBinaryFilesAndWaitsForReadyHandshake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 * 31) })
        let source = root.appendingPathComponent("source.bin")
        let received = root.appendingPathComponent("received.bin")
        let copied = root.appendingPathComponent("copied.bin")
        try bytes.write(to: source)
        let ready = Data("READY\n".utf8)
        let approval = Data("GO\n".utf8)
        let gate = CommandInputGate(readyFrame: ready, approvalFrame: approval)
        let script = "printf 'REA'; sleep 0.02; printf 'DY\\n'; IFS= read -r answer || exit 9; test \"$answer\" = GO || exit 10; cat > '\(received.path)'"
        let runner = ProcessCommandRunner()

        let upload = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                          timeout: 5, fileIO: CommandFileIO(inputFile: source, inputGate: gate))
        XCTAssertEqual(upload.exitCode, 0)
        XCTAssertTrue(upload.data.starts(with: ready))
        XCTAssertEqual(try Data(contentsOf: received), bytes)

        let download = try await runner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [source.path],
                                            timeout: 5, fileIO: CommandFileIO(outputFile: copied))
        XCTAssertEqual(download.exitCode, 0)
        XCTAssertTrue(download.data.isEmpty)
        XCTAssertEqual(try Data(contentsOf: copied), bytes)
    }

    func testProcessRunnerCleansOnlyItsOwnFailedOutputFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preexisting = root.appendingPathComponent("preexisting.bin")
        let original = Data("belongs to another operation".utf8)
        try original.write(to: preexisting)

        do {
            _ = try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 2,
                fileIO: CommandFileIO(outputFile: preexisting)
            )
            XCTFail("Exclusive output creation must reject an existing destination")
        } catch let error as EngineError {
            XCTAssertTrue(String(describing: error).contains("create"))
        }
        XCTAssertEqual(try Data(contentsOf: preexisting), original)

        let partial = root.appendingPathComponent("partial.bin")
        let failed = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf partial; exit 1"], timeout: 2,
            fileIO: CommandFileIO(outputFile: partial)
        )
        XCTAssertEqual(failed.exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testProcessRunnerSendsNoInputWhenReadinessFrameIsWrong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let sink = root.appendingPathComponent("sink.bin")
        try Data("private upload".utf8).write(to: source)
        let script = "printf 'NOT_READY\\n'; cat > '\(sink.path)'"
        do {
            _ = try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 0.25,
                fileIO: CommandFileIO(inputFile: source,
                                      inputGate: CommandInputGate(readyFrame: Data("READY\n".utf8),
                                                                 approvalFrame: Data("GO\n".utf8)))
            )
            XCTFail("The runner must time out without a matching readiness frame")
        } catch let error as EngineError {
            XCTAssertEqual(error, .operationTimedOut)
        }
        XCTAssertEqual(try Data(contentsOf: sink), Data())
    }

    func testProcessRunnerCancellationUnblocksReadinessWaitAndTransferPump() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        try Data(repeating: 0xA5, count: 500_000).write(to: source)
        let gate = CommandInputGate(readyFrame: Data("READY\n".utf8), approvalFrame: Data("GO\n".utf8))
        let waiting = Task {
            try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                arguments: ["-c", "sleep 5; printf 'READY\\n'; cat >/dev/null"],
                                                timeout: 10, fileIO: CommandFileIO(inputFile: source, inputGate: gate))
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancellation should stop a transfer waiting for identity readiness")
        } catch is CancellationError {
            // expected
        }

        let streaming = Task {
            try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"),
                                                arguments: ["-c", "printf 'READY\\n'; IFS= read -r answer; cat >/dev/null; sleep 5"],
                                                timeout: 10, fileIO: CommandFileIO(inputFile: source, inputGate: gate))
        }
        try await Task.sleep(for: .milliseconds(100))
        streaming.cancel()
        do {
            _ = try await streaming.value
            XCTFail("Cancellation should stop an active transfer")
        } catch is CancellationError {
            // expected
        }
    }

    private func makeTransport(runner: any CommandRunning) throws -> ADBTransport {
        ADBTransport(configuration: try ADBConfiguration(executable: URL(fileURLWithPath: "/test/adb")), runner: runner)
    }

    private func connectedSession(_ transport: ADBTransport) async throws -> DeviceSession {
        let discovery = try await transport.connectedDevices()
        guard let session = discovery.devices.first?.preferredSession else {
            throw EngineError.transport("Test ADB fixture did not provide a device session")
        }
        return session
    }

    private func remoteCommands(in calls: [[String]]) -> [[String]] {
        calls.filter {
            $0.count >= 4 && $0[0] == "-t" && $0[2] == "shell"
                && !isIdentityProbe($0[3]) && !isShellV2Probe($0)
        }
    }

    private func adbOperationCommands(in calls: [[String]]) -> [[String]] {
        calls.filter { $0.count >= 3 && $0[0] == "-t" && $0[2] != "get-devpath" &&
            !($0.count >= 4 && $0[2] == "shell" && isIdentityProbe($0[3])) && !isShellV2Probe($0) }
    }

    private func isIdentityProbe(_ command: String) -> Bool {
        command.hasPrefix("printf '%s\\000%s\\000%s\\000'")
    }

    private func isShellV2Probe(_ arguments: [String]) -> Bool {
        arguments.count >= 5 && arguments[3] == "-T" && arguments[4].contains("ANDRODO_SHELL_V2_STDOUT")
    }

    private func record(_ mode: String, _ size: Int64, _ mtime: String, _ path: RemotePath) -> Data {
        Data("\(mode)|\(size)|\(mtime)|\(path.description)\0".utf8)
    }
}

private actor StubCommandRunner: CommandRunning {
    private var outputs: [CommandOutput]
    private var calls: [[String]] = []
    private let pullResponse: Data?
    private var deviceList: Data
    private let wirelessTransportIDs: Set<Int>
    private var identitiesByTransportID: [Int: (String, String, String)]
    private var cancelNextIdentity = false
    private var cancelNextConnectionKind = false
    private let supportsShellV2Protocol: Bool
    private var nextStreamResult: CommandOutput?
    private var outputRaceContents: Data?
    private var sentInputs: [Data] = []
    private var sentInputGates: [CommandInputGate] = []

    init(outputs: [CommandOutput], pullResponse: Data? = nil,
         deviceList: Data = Data("List of devices attached\nphone-1 device transport_id:41 product:pixel model:Pixel_9\n".utf8),
         wirelessTransportIDs: Set<Int> = [],
         identitiesByTransportID: [Int: (String, String, String)] = [:],
         supportsShellV2Protocol: Bool = true) {
        self.outputs = outputs
        self.pullResponse = pullResponse
        self.deviceList = deviceList
        self.wirelessTransportIDs = wirelessTransportIDs
        self.identitiesByTransportID = identitiesByTransportID
        self.supportsShellV2Protocol = supportsShellV2Protocol
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        calls.append(arguments)
        if arguments == ["devices", "-l"] { return CommandOutput(data: deviceList, exitCode: 0) }
        if arguments.count == 3, arguments[0] == "-t", arguments[2] == "get-devpath",
           let transportID = Int(arguments[1]) {
            if cancelNextConnectionKind {
                cancelNextConnectionKind = false
                throw CancellationError()
            }
            let path = wirelessTransportIDs.contains(transportID) ? "unknown\n" : "/dev/bus/usb/001/002\n"
            return CommandOutput(data: Data(path.utf8), exitCode: 0)
        }
        if arguments.count == 4, arguments[0] == "-t", arguments[2] == "shell",
           arguments[3].hasPrefix("printf '%s\\000%s\\000%s\\000'"),
           let transportID = Int(arguments[1]) {
            if cancelNextIdentity {
                cancelNextIdentity = false
                throw CancellationError()
            }
            let identity = identitiesByTransportID[transportID] ?? ("stable-serial", "Google", "Pixel 9")
            var data = Data()
            for field in [identity.0, identity.1, identity.2] {
                data.append(contentsOf: field.utf8)
                data.append(0)
            }
            return CommandOutput(data: data, exitCode: 0)
        }
        if arguments.count == 5, arguments[0] == "-t", arguments[2] == "shell", arguments[3] == "-T",
           arguments[4].contains("ANDRODO_SHELL_V2_STDOUT") {
            guard supportsShellV2Protocol else {
                return CommandOutput(data: Data("ANDRODO_SHELL_V2_STDOUTANDRODO_SHELL_V2_STDERR".utf8), exitCode: 0)
            }
            return CommandOutput(data: Data("ANDRODO_SHELL_V2_STDOUT".utf8),
                                 standardError: Data("ANDRODO_SHELL_V2_STDERR".utf8), exitCode: 73)
        }
        guard !outputs.isEmpty else { throw EngineError.transport("Unexpected command") }
        return outputs.removeFirst()
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval,
             fileIO: CommandFileIO) async throws -> CommandOutput {
        guard fileIO != .none else { return try await run(executable: executable, arguments: arguments, timeout: timeout) }
        calls.append(arguments)
        if let nextStreamResult {
            self.nextStreamResult = nil
            return nextStreamResult
        }
        guard arguments.count >= 5, arguments[0] == "-t", arguments[2] == "shell", arguments[3] == "-T",
              let transportID = Int(arguments[1]) else {
            throw EngineError.transport("Unexpected file stream command")
        }
        let script = arguments[4]
        let identity = identitiesByTransportID[transportID] ?? ("stable-serial", "Google", "Pixel 9")
        let matchesIdentity = script.contains("= '\(identity.0)'")
            && script.contains("= '\(identity.1)'")
            && script.contains("= '\(identity.2)'")
        guard matchesIdentity else {
            return CommandOutput(data: Data(), standardError: Data("ANDRODO_DEVICE_IDENTITY_MISMATCH".utf8), exitCode: 125)
        }
        if let outputFile = fileIO.outputFile {
            if let outputRaceContents {
                self.outputRaceContents = nil
                try outputRaceContents.write(to: outputFile)
                return CommandOutput(data: Data(), standardError: Data("simulated transfer failure".utf8), exitCode: 1)
            }
            try (pullResponse ?? Data()).write(to: outputFile)
            return CommandOutput(data: Data(), exitCode: 0)
        }
        if let inputFile = fileIO.inputFile {
            guard let gate = fileIO.inputGate else { throw EngineError.transport("Upload fixture requires a readiness gate") }
            sentInputs.append(try Data(contentsOf: inputFile))
            sentInputGates.append(gate)
            return CommandOutput(data: gate.readyFrame, exitCode: 0)
        }
        throw EngineError.transport("File stream fixture has no input or output file")
    }

    func arguments() -> [[String]] { calls }
    func setDeviceList(_ value: Data) { deviceList = value }
    func setIdentity(_ transportID: Int, serialNumber: String, manufacturer: String, model: String) {
        identitiesByTransportID[transportID] = (serialNumber, manufacturer, model)
    }
    func cancelNextIdentityProbe() { cancelNextIdentity = true }
    func cancelNextConnectionKindProbe() { cancelNextConnectionKind = true }
    func setOutputRaceContents(_ contents: Data) { outputRaceContents = contents }
    func streamedInputs() -> [Data] { sentInputs }
    func streamGates() -> [CommandInputGate] { sentInputGates }
    func failNextStream(standardError: Data, exitCode: Int32) {
        nextStreamResult = CommandOutput(data: Data(), standardError: standardError, exitCode: exitCode)
    }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: DispatchTime) -> Bool {
    semaphore.wait(timeout: timeout) == .success
}

private func openRescueWriter(for fifo: URL) {
    for _ in 0..<100 {
        let descriptor = fifo.path.withCString { Darwin.open($0, O_WRONLY | O_NONBLOCK) }
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}
