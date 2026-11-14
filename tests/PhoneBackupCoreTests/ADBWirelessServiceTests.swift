import Foundation
import XCTest
@testable import PhoneBackupCore

final class ADBWirelessServiceTests: XCTestCase {
    func testEndpointAndPairingCodeValidationAndRedaction() throws {
        let ipv4 = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        XCTAssertEqual(ipv4.adbArgument, "192.168.1.42:37123")
        let ipv6 = try ADBWirelessEndpoint(host: "[2001:db8::42]", port: "37123")
        XCTAssertEqual(ipv6.adbArgument, "[2001:db8::42]:37123")

        for (host, port) in [("localhost", "37123"), ("127.0.0.1", "37123"), ("0.0.0.0", "37123"),
                             ("0.0.0.1", "37123"), ("::ffff:0.0.0.0", "37123"),
                             ("::ffff:127.0.0.1", "37123"), ("::ffff:224.0.0.1", "37123"),
                             ("::ffff:255.255.255.255", "37123"),
                             ("224.0.0.1", "37123"), ("192.168.1.42", "0"),
                             ("192.168.1.42", "65536"), ("192.168.1.42;reboot", "37123"),
                             ("[2001:db8::42", "37123")] {
            XCTAssertThrowsError(try ADBWirelessEndpoint(host: host, port: port), "\(host):\(port)")
        }

        let code = try ADBPairingCode("481205")
        XCTAssertEqual(String(describing: code), "Android pairing code")
        XCTAssertEqual(String(reflecting: code), "Android pairing code")
        XCTAssertThrowsError(try ADBPairingCode("48120"))
        XCTAssertThrowsError(try ADBPairingCode("48120x"))
    }

    func testPairingSendsCodeOnlyOverStdinAndReturnsNoADBOutput() async throws {
        let runner = WirelessCommandRunner()
        let service = try makeService(runner: runner)
        let endpoint = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        let code = try ADBPairingCode("481205")

        try await service.pair(endpoint: endpoint, code: code)

        let calls = await runner.calls()
        XCTAssertEqual(calls.map { $0.arguments }, [["help"], ["pair", endpoint.adbArgument]])
        XCTAssertFalse(calls.flatMap { $0.arguments }.contains("481205"))
        XCTAssertEqual(calls[0].inputData, Data())
        XCTAssertEqual(calls[1].inputData, Data("481205\n".utf8))
    }

    func testPairingRejectsUnsupportedADBAndContradictoryResponses() async throws {
        let endpoint = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        let code = try ADBPairingCode("481205")

        let unsupportedRunner = WirelessCommandRunner(supportsPairing: false)
        do {
            try await makeService(runner: unsupportedRunner).pair(endpoint: endpoint, code: code)
            XCTFail("Expected unsupported Platform Tools error")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .unsupportedPlatformTools)
        }
        let unsupportedCalls = await unsupportedRunner.calls()
        XCTAssertEqual(unsupportedCalls.count, 1)

        let oldServer = WirelessCommandRunner(pairResult: CommandOutput(
            data: Data(), standardError: Data("unknown host service: host:pair".utf8), exitCode: 1
        ))
        do {
            try await makeService(runner: oldServer).pair(endpoint: endpoint, code: code)
            XCTFail("An older shared ADB server must be reported as unsupported")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .unsupportedPlatformTools)
        }

        let contradictory = WirelessCommandRunner(pairResult: CommandOutput(
            data: Data("Successfully paired to private-device-guid".utf8), exitCode: 1
        ))
        do {
            try await makeService(runner: contradictory).pair(endpoint: endpoint, code: code)
            XCTFail("A success phrase with a nonzero exit must fail")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .pairingFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-device-guid"))
            XCTAssertFalse(error.localizedDescription.contains("481205"))
            XCTAssertFalse(error.localizedDescription.contains(endpoint.adbArgument))
        }

        let failedWithZero = WirelessCommandRunner(pairResult: CommandOutput(
            data: Data("Failed: incorrect pairing code".utf8), exitCode: 0
        ))
        do {
            try await makeService(runner: failedWithZero).pair(endpoint: endpoint, code: code)
            XCTFail("A failure phrase with a zero exit must fail")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .pairingRejectedOrExpired)
        }

        let malformedSuccess = WirelessCommandRunner(pairResult: CommandOutput(
            data: Data("Failed: Successfully paired but server returned unknown response=private-guid".utf8), exitCode: 0
        ))
        do {
            try await makeService(runner: malformedSuccess).pair(endpoint: endpoint, code: code)
            XCTFail("An error containing the success phrase must not count as a successful pair")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .pairingFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-guid"))
        }
    }

    func testPairingCancellationAndTimeoutAreStructured() async throws {
        let endpoint = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        let code = try ADBPairingCode("481205")
        let cancelled = WirelessCommandRunner(pairError: CancellationError())
        do {
            try await makeService(runner: cancelled).pair(endpoint: endpoint, code: code)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // expected
        }

        let timedOut = WirelessCommandRunner(pairError: EngineError.operationTimedOut)
        do {
            try await makeService(runner: timedOut).pair(endpoint: endpoint, code: code)
            XCTFail("Expected timeout")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .operationTimedOut)
        }
    }

    func testConnectRequiresExactResponseAndVerifiedWirelessIdentity() async throws {
        let endpoint = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        let otherEndpoint = try ADBWirelessEndpoint(host: "192.168.1.43", port: "37123")
        let runner = WirelessCommandRunner(
            connectResult: CommandOutput(data: Data("connected to \(endpoint.adbArgument)".utf8), exitCode: 0),
            deviceList: Data("List of devices attached\n192.168.1.43:37123 device transport_id:80 model:Pixel_9\n192.168.1.42:37123 device transport_id:81 model:Pixel_9\n".utf8),
            identities: [
                80: ("serial-one", "Google", "Pixel 9"),
                81: ("serial-two", "Google", "Pixel 9"),
            ]
        )
        let service = try makeService(runner: runner)

        let device = try await service.connect(endpoint: endpoint)

        XCTAssertEqual(device.id, try DeviceIdentityEvidence(serialNumber: "serial-two", manufacturer: "Google", model: "Pixel 9").deviceID)
        XCTAssertTrue(device.sessions.contains { $0.connection.kind == .wireless })
        let calls = await runner.calls()
        XCTAssertEqual(calls.first?.arguments, ["connect", endpoint.adbArgument])
        XCTAssertFalse(calls.flatMap { $0.arguments }.contains(otherEndpoint.adbArgument))
        XCTAssertFalse(calls.flatMap { $0.arguments }.contains { $0.contains("find ") || $0 == "pull" || $0 == "push" })
        let queriedTransportIDs = calls.compactMap { call -> String? in
            guard call.arguments.count >= 3, call.arguments[0] == "-t" else { return nil }
            return call.arguments[1]
        }
        XCTAssertEqual(Set(queriedTransportIDs), ["81"])
    }

    func testWirelessConnectDropsUnpluggedUSBSessionFromReturnedDevice() async throws {
        let endpoint = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        let usbList = Data("List of devices attached\nUSB-serial device transport_id:80 model:Pixel_9\n".utf8)
        let wirelessList = Data("List of devices attached\n192.168.1.42:37123 device transport_id:81 model:Pixel_9\n".utf8)
        let runner = WirelessCommandRunner(
            connectResult: CommandOutput(data: Data("connected to \(endpoint.adbArgument)".utf8), exitCode: 0),
            deviceLists: [usbList, wirelessList],
            identities: [80: ("serial-two", "Google", "Pixel 9"), 81: ("serial-two", "Google", "Pixel 9")],
            devPaths: [80: "/dev/bus/usb/001/002\n", 81: "unknown\n"]
        )
        let configuration = try ADBConfiguration(executable: URL(fileURLWithPath: "/test/adb"), commandTimeout: 1)
        let transport = ADBTransport(configuration: configuration, runner: runner)
        let initialDevices = try await transport.connectedDevices()
        XCTAssertEqual(initialDevices.devices.first?.preferredSession?.connection.kind, .usb)

        let device = try await ADBWirelessService(configuration: configuration, runner: runner,
                                                  transport: transport).connect(endpoint: endpoint)

        XCTAssertEqual(device.sessions.map(\.connection.kind), [.wireless])
        XCTAssertEqual(device.preferredSession?.connection.selector, endpoint.adbArgument)
    }

    func testConnectRejectsExitStatusAndResponseDisagreementOrWrongEndpoint() async throws {
        let endpoint = try ADBWirelessEndpoint(host: "192.168.1.42", port: "37123")
        let successWithFailureStatus = WirelessCommandRunner(
            connectResult: CommandOutput(data: Data("connected to \(endpoint.adbArgument)".utf8), exitCode: 1)
        )
        do {
            _ = try await makeService(runner: successWithFailureStatus).connect(endpoint: endpoint)
            XCTFail("A success phrase with a nonzero exit must fail")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .connectionNotVerified)
        }

        let failureWithSuccessStatus = WirelessCommandRunner(
            connectResult: CommandOutput(data: Data("failed to connect to \(endpoint.adbArgument)".utf8), exitCode: 0)
        )
        do {
            _ = try await makeService(runner: failureWithSuccessStatus).connect(endpoint: endpoint)
            XCTFail("A failure phrase with a zero exit must fail")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .endpointUnavailable)
            XCTAssertFalse(error.localizedDescription.contains(endpoint.adbArgument))
        }

        let wrongEndpoint = WirelessCommandRunner(
            connectResult: CommandOutput(data: Data("connected to 192.168.1.55:37123".utf8), exitCode: 0)
        )
        do {
            _ = try await makeService(runner: wrongEndpoint).connect(endpoint: endpoint)
            XCTFail("A response for another endpoint must fail")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .connectionNotVerified)
        }

        let missingEndpoint = WirelessCommandRunner(
            connectResult: CommandOutput(data: Data("connected to \(endpoint.adbArgument)".utf8), exitCode: 0),
            deviceList: Data("List of devices attached\n192.168.1.99:37123 device transport_id:91 model:Pixel_9\n".utf8),
            identities: [91: ("some-other-phone", "Google", "Pixel 9")]
        )
        do {
            _ = try await makeService(runner: missingEndpoint).connect(endpoint: endpoint)
            XCTFail("A successful command without the requested wireless route must fail verification")
        } catch let error as WirelessADBError {
            XCTAssertEqual(error, .connectionNotVerified)
        }
    }

    private func makeService(runner: any CommandRunning) throws -> ADBWirelessService {
        let configuration = try ADBConfiguration(executable: URL(fileURLWithPath: "/test/adb"), commandTimeout: 1)
        let transport = ADBTransport(configuration: configuration, runner: runner)
        return ADBWirelessService(configuration: configuration, runner: runner, transport: transport)
    }
}

private actor WirelessCommandRunner: CommandRunning {
    private let supportsPairing: Bool
    private let pairResult: CommandOutput
    private let connectResult: CommandOutput
    private var deviceLists: [Data]
    private var deviceListIndex = 0
    private let identities: [Int: (String, String, String)]
    private let devPaths: [Int: String]
    private let pairError: (any Error)?
    private var recorded: [(arguments: [String], inputData: Data?)] = []

    init(supportsPairing: Bool = true,
         pairResult: CommandOutput = CommandOutput(
            data: Data("Successfully paired to 192.168.1.42:37123 [guid=device-guid]".utf8), exitCode: 0),
         connectResult: CommandOutput = CommandOutput(data: Data("connected to 192.168.1.42:37123".utf8), exitCode: 0),
         deviceList: Data = Data("List of devices attached\n192.168.1.42:37123 device transport_id:81 model:Pixel_9\n".utf8),
         deviceLists: [Data]? = nil,
         identities: [Int: (String, String, String)] = [81: ("serial-two", "Google", "Pixel 9")],
         devPaths: [Int: String] = [:],
         pairError: (any Error)? = nil) {
        self.supportsPairing = supportsPairing
        self.pairResult = pairResult
        self.connectResult = connectResult
        if let deviceLists, !deviceLists.isEmpty {
            self.deviceLists = deviceLists
        } else {
            self.deviceLists = [deviceList]
        }
        self.identities = identities
        self.devPaths = devPaths
        self.pairError = pairError
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        recorded.append((arguments, nil))
        if arguments == ["help"] {
            let help = supportsPairing ? "pair HOST[:PORT] [PAIRING CODE]" : "devices [-l] connect HOST[:PORT]"
            return CommandOutput(data: Data(help.utf8), exitCode: 0)
        }
        if arguments == ["devices", "-l"] {
            let list = deviceLists[min(deviceListIndex, deviceLists.count - 1)]
            deviceListIndex += 1
            return CommandOutput(data: list, exitCode: 0)
        }
        if arguments.count == 3, arguments[0] == "-t", arguments[2] == "get-devpath" {
            let transportID = arguments[1]
            return Int(transportID).map { identities[$0] == nil ? CommandOutput(data: Data(), exitCode: 1)
                : CommandOutput(data: Data((devPaths[$0] ?? "unknown\n").utf8), exitCode: 0) }
                ?? CommandOutput(data: Data(), exitCode: 1)
        }
        if arguments.count == 4, arguments[0] == "-t", arguments[2] == "shell",
           arguments[3].hasPrefix("printf '%s\\000%s\\000%s\\000'") {
            let transportID = arguments[1]
            guard let identity = Int(transportID).flatMap({ identities[$0] }) else {
                return CommandOutput(data: Data(), exitCode: 1)
            }
            var output = Data()
            for field in [identity.0, identity.1, identity.2] {
                output.append(contentsOf: field.utf8)
                output.append(0)
            }
            return CommandOutput(data: output, exitCode: 0)
        }
        if arguments.count == 5, arguments[0] == "-t", arguments[2] == "shell", arguments[3] == "-T",
           arguments[4].contains("ANDRODO_SHELL_V2_STDOUT") {
            return CommandOutput(data: Data("ANDRODO_SHELL_V2_STDOUT".utf8),
                                 standardError: Data("ANDRODO_SHELL_V2_STDERR".utf8), exitCode: 73)
        }
        if arguments.count == 2, arguments[0] == "pair" {
            if let pairError { throw pairError }
            return pairResult
        }
        if arguments.count == 2, arguments[0] == "connect" {
            return connectResult
        }
        throw EngineError.transport("Unexpected synthetic ADB command")
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval,
             fileIO: CommandFileIO) async throws -> CommandOutput {
        recorded.append((arguments, fileIO.inputData))
        guard fileIO.outputFile == nil, fileIO.inputFile == nil else {
            throw EngineError.transport("Unexpected synthetic file transfer")
        }
        if arguments == ["help"] {
            let help = supportsPairing ? "pair HOST[:PORT] [PAIRING CODE]" : "devices [-l] connect HOST[:PORT]"
            return CommandOutput(data: Data(help.utf8), exitCode: 0)
        }
        if arguments.count == 2, arguments[0] == "pair" {
            if let pairError { throw pairError }
            return pairResult
        }
        if arguments.count == 2, arguments[0] == "connect" {
            return connectResult
        }
        return try await run(executable: executable, arguments: arguments, timeout: timeout)
    }

    func calls() -> [(arguments: [String], inputData: Data?)] { recorded }
}
