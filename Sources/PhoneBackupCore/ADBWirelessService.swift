import Darwin
import Foundation

/// A validated numeric address shown in Android's Wireless debugging settings.
/// The address is transient and deliberately redacted from descriptions and persistence.
public struct ADBWirelessEndpoint: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let adbArgument: String

    public init(host: String, port: String) throws {
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawHost.isEmpty, rawHost.utf8.count <= Int(INET6_ADDRSTRLEN),
              rawHost == host, !rawHost.contains(where: { $0.isWhitespace || $0.isNewline }),
              !rawHost.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }),
              !rawPort.isEmpty, rawPort.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let portNumber = UInt16(rawPort), portNumber > 0 else {
            throw WirelessADBError.invalidEndpoint
        }

        let address = Self.unbracket(rawHost)
        if Self.isIPv4(address) {
            var value = in_addr()
            guard address.withCString({ inet_pton(AF_INET, $0, &value) }) == 1 else {
                throw WirelessADBError.invalidEndpoint
            }
            let bytes = withUnsafeBytes(of: value.s_addr) { Array($0) }
            guard Self.isUsableIPv4(bytes) else {
                throw WirelessADBError.invalidEndpoint
            }
            adbArgument = "\(address):\(portNumber)"
        } else {
            var value = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &value) }) == 1 else {
                throw WirelessADBError.invalidEndpoint
            }
            let bytes = withUnsafeBytes(of: value) { Array($0) }
            let unspecified = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let multicast = bytes.first == 0xff
            let mappedIPv4 = bytes.count == 16 && bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff
            let mappedAddressIsUsable = !mappedIPv4 || Self.isUsableIPv4(Array(bytes[12..<16]))
            guard !unspecified, !loopback, !multicast, mappedAddressIsUsable else {
                throw WirelessADBError.invalidEndpoint
            }
            adbArgument = "[\(address.lowercased())]:\(portNumber)"
        }
    }

    public var description: String { "Android Wi-Fi endpoint" }
    public var debugDescription: String { description }

    private static func unbracket(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func isIPv4(_ host: String) -> Bool {
        !host.contains(":")
    }

    private static func isUsableIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return bytes.contains(where: { $0 != 0 })
            && bytes[0] != 0
            && bytes[0] != 127
            && bytes[0] < 224
            && bytes != [255, 255, 255, 255]
    }
}

/// Short-lived pairing secret. It is never Codable and redacts incidental logging.
public struct ADBPairingCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    public init(_ value: String) throws {
        guard value.utf8.count == 6, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw WirelessADBError.invalidPairingCode
        }
        self.value = value
    }

    public var description: String { "Android pairing code" }
    public var debugDescription: String { description }
}

public enum WirelessADBError: Error, Equatable, Sendable, LocalizedError {
    case invalidEndpoint
    case invalidPairingCode
    case unsupportedPlatformTools
    case pairingRejectedOrExpired
    case pairingFailed
    case endpointUnavailable
    case connectionNotVerified
    case operationTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid IP address and port from Android Wireless debugging."
        case .invalidPairingCode: "Enter the six-digit pairing code shown on Android."
        case .unsupportedPlatformTools: "This ADB version does not support Android Wi-Fi pairing. Update Platform Tools and try again."
        case .pairingRejectedOrExpired: "Android rejected the pairing code or it expired. Show a new code and try again."
        case .pairingFailed: "Androdo could not pair with the phone. Check the pairing screen and try again."
        case .endpointUnavailable: "Androdo could not reach that phone address. Check the address and make sure both devices are on the same network."
        case .connectionNotVerified: "ADB responded, but Androdo could not verify that Wi-Fi connection as an Android phone. Refresh devices and try again."
        case .operationTimedOut: "The Wi-Fi connection timed out. Check the phone’s Wireless debugging screen and try again."
        }
    }
}

public protocol WirelessADBConnecting: Sendable {
    func pair(endpoint: ADBWirelessEndpoint, code: ADBPairingCode) async throws
    func connect(endpoint: ADBWirelessEndpoint) async throws -> AndroidDevice
}

/// Explicit ADB Wi-Fi pairing and connection. It never scans, browses phone folders,
/// restarts the shared ADB server, or returns raw ADB diagnostics to the caller.
public struct ADBWirelessService: WirelessADBConnecting {
    private let configuration: ADBConfiguration
    private let runner: any CommandRunning
    private let transport: ADBTransport

    public init(configuration: ADBConfiguration, runner: any CommandRunning,
                transport: ADBTransport) {
        self.configuration = configuration
        self.runner = runner
        self.transport = transport
    }

    public func pair(endpoint: ADBWirelessEndpoint, code: ADBPairingCode) async throws {
        guard try await supportsPairing() else { throw WirelessADBError.unsupportedPlatformTools }
        let stdin = Data((code.value + "\n").utf8)
        let output: CommandOutput
        do {
            output = try await runner.run(executable: configuration.executable,
                                          arguments: ["pair", endpoint.adbArgument],
                                          timeout: configuration.commandTimeout,
                                          fileIO: CommandFileIO(inputData: stdin))
        } catch is CancellationError {
            throw CancellationError()
        } catch EngineError.operationTimedOut {
            throw WirelessADBError.operationTimedOut
        } catch {
            throw WirelessADBError.pairingFailed
        }

        let standardOutput = String(decoding: output.data, as: UTF8.self)
        let pairingResponseLines = standardOutput
            .replacingOccurrences(of: "Enter pairing code:", with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let expectedSuccessPrefix = "Successfully paired to \(endpoint.adbArgument)"
        let hasMatchingSuccess = pairingResponseLines.contains { line in
            guard line.lowercased().hasPrefix(expectedSuccessPrefix.lowercased()) else { return false }
            let suffix = line.dropFirst(expectedSuccessPrefix.count)
            return suffix.isEmpty || suffix.first == " " || suffix.first == "["
        }
        let response = String(decoding: output.data + output.standardError, as: UTF8.self).lowercased()
        guard output.exitCode == 0, hasMatchingSuccess else {
            if response.contains("unknown command") || response.contains("unknown host service")
                || response.contains("pairing is not supported") {
                throw WirelessADBError.unsupportedPlatformTools
            }
            if response.contains("unable to connect") || response.contains("failed to connect") {
                throw WirelessADBError.endpointUnavailable
            }
            if response.contains("pairing code") || response.contains("failed to pair")
                || response.contains("incorrect") || response.contains("wrong password") {
                throw WirelessADBError.pairingRejectedOrExpired
            }
            throw WirelessADBError.pairingFailed
        }
    }

    public func connect(endpoint: ADBWirelessEndpoint) async throws -> AndroidDevice {
        let output: CommandOutput
        do {
            output = try await runner.run(executable: configuration.executable,
                                          arguments: ["connect", endpoint.adbArgument],
                                          timeout: configuration.commandTimeout,
                                          fileIO: CommandFileIO(inputData: Data()))
        } catch is CancellationError {
            throw CancellationError()
        } catch EngineError.operationTimedOut {
            throw WirelessADBError.operationTimedOut
        } catch {
            throw WirelessADBError.endpointUnavailable
        }

        let stdoutLines = String(decoding: output.data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let expectedEndpoint = endpoint.adbArgument.lowercased()
        let hasMatchingSuccess = stdoutLines.contains {
            $0 == "connected to \(expectedEndpoint)" || $0 == "already connected to \(expectedEndpoint)"
        }
        let response = String(decoding: output.data + output.standardError, as: UTF8.self)
        let lowercased = response.lowercased()
        guard output.exitCode == 0, hasMatchingSuccess else {
            if lowercased.contains("unable to connect") || lowercased.contains("failed to connect") {
                throw WirelessADBError.endpointUnavailable
            }
            throw WirelessADBError.connectionNotVerified
        }

        do {
            guard let device = try await transport.verifiedWirelessDevice(at: endpoint) else {
                throw WirelessADBError.connectionNotVerified
            }
            return device
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WirelessADBError {
            throw error
        } catch EngineError.operationTimedOut {
            throw WirelessADBError.operationTimedOut
        } catch {
            throw WirelessADBError.connectionNotVerified
        }
    }

    private func supportsPairing() async throws -> Bool {
        let output: CommandOutput
        do {
            output = try await runner.run(executable: configuration.executable, arguments: ["help"],
                                          timeout: configuration.commandTimeout,
                                          fileIO: CommandFileIO(inputData: Data()))
        } catch is CancellationError {
            throw CancellationError()
        } catch EngineError.operationTimedOut {
            throw WirelessADBError.operationTimedOut
        } catch {
            throw WirelessADBError.unsupportedPlatformTools
        }
        guard output.exitCode == 0 else { return false }
        let help = String(decoding: output.data, as: UTF8.self).lowercased()
        return help.contains("pair host[:port]")
    }
}
