import Foundation
import Darwin
import CryptoKit

public struct CommandOutput: Equatable, Sendable {
    public let data: Data
    public let standardError: Data
    public let exitCode: Int32

    public init(data: Data, standardError: Data = Data(), exitCode: Int32) {
        self.data = data
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
}

public struct ADBConfiguration: Sendable {
    public let executable: URL
    public let commandTimeout: TimeInterval

    public init(executable: URL, commandTimeout: TimeInterval = 30) throws {
        guard commandTimeout > 0 else { throw EngineError.transport("ADB command timeout must be positive") }
        self.executable = executable.standardizedFileURL
        self.commandTimeout = commandTimeout
    }
}

public enum ADBExecutableResolver {
    public static func isExecutableFile(at url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }

    public static func resolve(preferredExecutable: URL?,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileManager: FileManager = .default) -> URL? {
        if let preferredExecutable, isExecutableFile(at: preferredExecutable, fileManager: fileManager) {
            return preferredExecutable.standardizedFileURL
        }
        return resolve(environment: environment, fileManager: fileManager)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let sdkRoots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]]
            .compactMap { $0 }
            + [NSHomeDirectory() + "/Library/Android/sdk"]
        let commonPaths = sdkRoots.map { URL(fileURLWithPath: $0).appendingPathComponent("platform-tools/adb").path }
            + ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"]
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in commonPaths + pathEntries.map({ URL(fileURLWithPath: $0).appendingPathComponent("adb").path }) {
            if isExecutableFile(at: URL(fileURLWithPath: path), fileManager: fileManager) {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
        }
        return nil
    }
}

/// Runs one local process at a time without blocking the caller's actor or main thread.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        let execution = ProcessExecution()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try execution.run(executable: executable, arguments: arguments, timeout: timeout)
            }.value
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true { runningProcess?.terminate() }
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandOutput {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let subprocess = Process()
        subprocess.executableURL = executable
        subprocess.arguments = arguments
        subprocess.standardInput = FileHandle.nullDevice
        subprocess.standardOutput = outputPipe
        subprocess.standardError = errorPipe
        lock.lock()
        let alreadyCancelled = cancelled
        process = subprocess
        lock.unlock()
        if alreadyCancelled { throw CancellationError() }

        let outputReader = ProcessOutputReader(handle: outputPipe.fileHandleForReading)
        let errorReader = ProcessOutputReader(handle: errorPipe.fileHandleForReading)
        do {
            try subprocess.run()
        } catch {
            _ = outputReader.finish()
            _ = errorReader.finish()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            throw EngineError.adbUnavailable(error.localizedDescription)
        }

        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var terminationSentAt: Date?
        while subprocess.isRunning {
            lock.lock()
            let wasCancelled = cancelled
            let didTimeOut = timedOut
            lock.unlock()
            if wasCancelled || didTimeOut || Date() >= deadline {
                if terminationSentAt == nil {
                    terminationSentAt = Date()
                    subprocess.terminate()
                } else if Date().timeIntervalSince(terminationSentAt!) >= 0.25 {
                    _ = Darwin.kill(subprocess.processIdentifier, SIGKILL)
                }
            }
            if !wasCancelled && !didTimeOut && Date() >= deadline {
                lock.lock()
                timedOut = true
                lock.unlock()
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        subprocess.waitUntilExit()
        let standardOutput = outputReader.finish()
        let standardError = errorReader.finish()

        lock.lock()
        let wasCancelled = cancelled
        let didTimeOut = timedOut
        process = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if didTimeOut { throw EngineError.operationTimedOut }
        return CommandOutput(data: standardOutput, standardError: standardError, exitCode: subprocess.terminationStatus)
    }
}

private final class ProcessOutputReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PhoneBackupCore.ProcessOutputReader")
    private var data = Data()
    private let handle: FileHandle
    private let source: DispatchSourceRead

    init(handle: FileHandle) {
        self.handle = handle
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainAvailableData()
        }
        source.setCancelHandler { [handle] in
            try? handle.close()
        }
        source.resume()
    }

    func finish() -> Data {
        queue.sync {
            drainAvailableData()
            source.cancel()
            return data
        }
    }

    private func drainAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 || errno != EAGAIN && errno != EWOULDBLOCK {
                return
            } else {
                return
            }
        }
    }
}

public actor ADBTransport: DeviceTransport, RemoteDestinationAccess {
    private static let findFormat = "%M|%s|%T@|%p\\0"

    private let configuration: ADBConfiguration
    private let runner: any CommandRunning
    private var findPrintfSupport: [DeviceID: Bool] = [:]

    public init(configuration: ADBConfiguration, runner: any CommandRunning = ProcessCommandRunner()) {
        self.configuration = configuration
        self.runner = runner
    }

    public func connectedDevices() async throws -> [AndroidDevice] {
        let output = try await command(["devices", "-l"])
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        return try lines.compactMap { line in
            guard !line.starts(with: "List of devices attached") else { return nil }
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, columns[0] != "*",
                  let state = Self.deviceState(String(columns[1])) else { return nil }
            let id = try DeviceID(serial: String(columns[0]))
            let attributes = columns.dropFirst(2).reduce(into: [String: String]()) { result, column in
                let field = column.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if field.count == 2 { result[String(field[0])] = String(field[1]) }
            }
            return AndroidDevice(id: id, state: state, model: attributes["model"], product: attributes["product"])
        }
    }

    public func children(of path: RemotePath, on device: DeviceID) async throws -> [RemoteEntry] {
        if findPrintfSupport[device] == false {
            throw EngineError.unsupportedDirectoryListing(device)
        }

        let remoteCommand = "find -H \(Self.shellQuote(path.description)) -mindepth 0 -maxdepth 1 -printf \(Self.shellQuote(Self.findFormat))"
        let output: Data
        do {
            // `adb shell` joins its trailing arguments into one remote command string.
            // Pass the complete, safely quoted command as one argument; wrapping it in
            // `sh -c` would require a second quoting layer and can drop find's arguments.
            output = try await command(["-s", device.serial, "shell", remoteCommand], path: path, device: device)
        } catch let EngineError.transport(message) where Self.unsupportedPrintf(message) {
            findPrintfSupport[device] = false
            throw EngineError.unsupportedDirectoryListing(device)
        }
        findPrintfSupport[device] = true
        return try Self.parseImmediateChildren(output, parent: path)
    }

    public func metadata(of path: RemotePath, on device: DeviceID) async throws -> RemoteEntry {
        let remoteCommand = "find -H \(Self.shellQuote(path.description)) -mindepth 0 -maxdepth 0 -printf \(Self.shellQuote(Self.findFormat))"
        let output = try await command(["-s", device.serial, "shell", remoteCommand], path: path, device: device)
        guard output.last == 0,
              let record = output.split(separator: 0, omittingEmptySubsequences: true).first,
              let line = String(data: Data(record), encoding: .utf8) else {
            throw EngineError.missingPath(path)
        }
        let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count == 4,
              let mode = fields[0].first,
              let size = Int64(fields[1]),
              let modifiedSeconds = Double(fields[2]) else {
            throw EngineError.transport("ADB returned invalid path metadata")
        }
        let listedPath: RemotePath
        do { listedPath = try RemotePath(String(fields[3])) }
        catch { throw EngineError.transport("ADB returned an invalid device path") }
        guard listedPath == path else { throw EngineError.missingPath(path) }
        let kind: RemoteEntryKind
        switch mode {
        case "d": kind = .directory
        case "-": kind = .file
        case "l": kind = .symbolicLink
        default: kind = .other
        }
        return RemoteEntry(path: path, kind: kind, size: kind == .file ? size : nil,
                           modifiedAt: Date(timeIntervalSince1970: modifiedSeconds))
    }

    public func pull(from path: RemotePath, on device: DeviceID, to localURL: URL) async throws {
        _ = try await command(["-s", device.serial, "pull", path.description, localURL.path], path: path, device: device)
    }

    public func push(from localURL: URL, to path: RemotePath, on device: DeviceID) async throws {
        _ = try await command(["-s", device.serial, "push", localURL.path, path.description], path: path, device: device)
    }

    public func inspectDestination(_ path: RemotePath, on device: DeviceID) async throws -> RemoteDestinationState {
        let quoted = Self.shellQuote(path.description)
        let identity = "$(stat -c '%d:%i:%s:%y' \(quoted) 2>/dev/null)"
        let remote = "if [ -L \(quoted) ]; then printf 'L|%s' \(identity); elif [ -f \(quoted) ]; then printf 'F|%s' \(identity); elif [ -d \(quoted) ]; then printf 'D|%s' \(identity); elif [ -e \(quoted) ]; then printf 'O|%s' \(identity); else printf 'M'; fi"
        let output = try await command(["-s", device.serial, "shell", remote], path: path, device: device)
        let record = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if record == "M" { return .missing }
        let fields = record.split(separator: "|", maxSplits: 1).map(String.init)
        guard fields.count == 2 else { throw EngineError.transport("ADB returned invalid destination metadata") }
        let stats = fields[1].split(separator: ":", maxSplits: 3)
        guard stats.count == 4, let size = Int64(stats[2]) else {
            throw EngineError.transport("ADB returned invalid destination identity")
        }
        switch fields[0] {
        case "F": return .regularFile(identity: fields[1], size: size)
        case "D": return .directory(identity: fields[1])
        case "L": return .symbolicLink(identity: fields[1])
        default: return .other(identity: fields[1])
        }
    }

    public func createDestinationDirectory(_ path: RemotePath, on device: DeviceID) async throws {
        switch try await inspectDestination(path, on: device) {
        case .directory: return
        case .missing:
            let remote = "mkdir \(Self.shellQuote(path.description))"
            _ = try await command(["-s", device.serial, "shell", remote], path: path, device: device)
            guard case .directory = try await inspectDestination(path, on: device) else {
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
            }
        case .regularFile, .symbolicLink, .other:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
        }
    }

    public func publishStagedFile(from localURL: URL, to path: RemotePath, on device: DeviceID,
                                  expected: ContentObjectReference, replacing approvedIdentity: String?) async throws {
        let parent = path.parent ?? .root
        let stage = try parent.appending(".phonebackup-restore-\(UUID().uuidString.lowercased())")
        let initial = try await inspectDestination(path, on: device)
        try Self.requireDestinationApproval(initial, path: path, approvedIdentity: approvedIdentity)
        guard case .missing = try await inspectDestination(stage, on: device) else {
            throw EngineError.destinationConflict(TransferConflict(destination: stage.description, kind: .unsafePath))
        }
        let verification = FileManager.default.temporaryDirectory.appendingPathComponent("phonebackup-remote-verify-\(UUID().uuidString.lowercased())")
        var published = false
        var publicationAttempted = false
        do {
            try await push(from: localURL, to: stage, on: device)
            try await pull(from: stage, on: device, to: verification)
            try await Self.verifyLocalFile(verification, expected: expected)
            try await verifyDestinationAncestors(parent, on: device)
            let current = try await inspectDestination(path, on: device)
            try Self.requireDestinationApproval(current, path: path, approvedIdentity: approvedIdentity)
            if approvedIdentity == nil {
                let remote = "ln -T \(Self.shellQuote(stage.description)) \(Self.shellQuote(path.description))"
                publicationAttempted = true
                do {
                    _ = try await command(["-s", device.serial, "shell", remote], path: path, device: device)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as EngineError {
                    switch error {
                    case .deviceUnavailable, .operationTimedOut, .adbUnavailable:
                        throw error
                    case .transport(let message) where message.lowercased().contains("file exists"):
                        throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .fileExists))
                    case .transport:
                        throw EngineError.safeNoOverwriteUnavailable(path)
                    case .inaccessiblePath:
                        throw EngineError.safeNoOverwriteUnavailable(path)
                    default:
                        throw error
                    }
                } catch {
                    throw EngineError.transport(error.localizedDescription)
                }
                published = true
            } else {
                let remote = "mv -f -T \(Self.shellQuote(stage.description)) \(Self.shellQuote(path.description))"
                publicationAttempted = true
                _ = try await command(["-s", device.serial, "shell", remote], path: path, device: device)
                published = true
            }
            let finalVerification = FileManager.default.temporaryDirectory.appendingPathComponent("phonebackup-remote-final-\(UUID().uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: finalVerification) }
            try await pull(from: path, on: device, to: finalVerification)
            try await Self.verifyLocalFile(finalVerification, expected: expected)
            let cleanup = "rm -f \(Self.shellQuote(stage.description))"
            _ = try? await command(["-s", device.serial, "shell", cleanup], path: path, device: device)
        } catch {
            await Task.detached { await self.removeRemoteStage(stage, on: device) }.value
            try? FileManager.default.removeItem(at: verification)
            let publicationMayHaveCompleted: Bool
            if let engineError = error as? EngineError {
                switch engineError {
                case .deviceUnavailable, .operationTimedOut, .adbUnavailable, .transport:
                    publicationMayHaveCompleted = true
                default:
                    publicationMayHaveCompleted = false
                }
            } else {
                publicationMayHaveCompleted = error is CancellationError
            }
            if published || publicationAttempted && publicationMayHaveCompleted {
                throw EngineError.destinationPublishedUnverified(path.description, error.localizedDescription)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: verification)
    }

    private static func requireDestinationApproval(_ state: RemoteDestinationState, path: RemotePath,
                                                   approvedIdentity: String?) throws {
        switch state {
        case .missing:
            guard approvedIdentity == nil || approvedIdentity == RestoreConflict.approvedMissingTargetIdentity else {
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .fileExists))
            }
        case .regularFile(let identity, _):
            guard approvedIdentity == identity else {
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .fileExists))
            }
        case .directory:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .directoryExists))
        case .symbolicLink, .other:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
        }
    }

    private func removeRemoteStage(_ stage: RemotePath, on device: DeviceID) async {
        let cleanup = "rm -f \(Self.shellQuote(stage.description))"
        _ = try? await command(["-s", device.serial, "shell", cleanup], path: stage, device: device)
    }

    private func verifyDestinationAncestors(_ parent: RemotePath, on device: DeviceID) async throws {
        var current = RemotePath.root
        for (index, component) in parent.components.enumerated() {
            current = try current.appending(component)
            if index == 0 && component == "sdcard" { continue }
            guard case .directory = try await inspectDestination(current, on: device) else {
                throw EngineError.destinationConflict(TransferConflict(destination: current.description, kind: .unsafePath))
            }
        }
    }

    private static func verifyLocalFile(_ url: URL, expected: ContentObjectReference) async throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize,
              Int64(fileSize) == expected.size else {
            throw EngineError.corruptedRepository("Transferred restore stage has the wrong size")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.sha256 else { throw EngineError.corruptedRepository("Transferred restore stage failed SHA-256 verification") }
    }

    private func command(_ arguments: [String], path: RemotePath? = nil, device: DeviceID? = nil) async throws -> Data {
        let output: CommandOutput
        do {
            output = try await runner.run(
                executable: configuration.executable,
                arguments: arguments,
                timeout: configuration.commandTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.transport(error.localizedDescription)
        }
        guard output.exitCode == 0 else {
            let diagnostic = String(decoding: output.standardError + output.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = diagnostic.lowercased()
            if let path, lowercased.contains("no such file or directory") { throw EngineError.missingPath(path) }
            if let path, lowercased.contains("permission denied") || lowercased.contains("operation not permitted") {
                throw EngineError.inaccessiblePath(path)
            }
            if let device, Self.isUnavailableDeviceDiagnostic(lowercased, serial: device.serial) {
                throw EngineError.deviceUnavailable(device)
            }
            throw EngineError.transport(diagnostic.isEmpty ? "ADB exited with status \(output.exitCode)" : diagnostic)
        }
        return output.data
    }

    private static func parseImmediateChildren(_ output: Data, parent: RemotePath) throws -> [RemoteEntry] {
        guard output.isEmpty || output.last == 0 else {
            throw EngineError.transport("ADB returned an incomplete directory listing")
        }
        var entries: [RemoteEntry] = []
        for record in output.split(separator: 0, omittingEmptySubsequences: true) {
            guard let line = String(data: Data(record), encoding: .utf8) else {
                throw EngineError.unsupportedFilename(parent)
            }
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let firstModeCharacter = fields[0].first,
                  let size = Int64(fields[1]),
                  let modifiedSeconds = Double(fields[2]) else {
                throw EngineError.transport("ADB returned an invalid directory record")
            }
            let path: RemotePath
            do {
                path = try RemotePath(String(fields[3]))
            } catch {
                throw EngineError.transport("ADB returned an invalid device path")
            }
            let kind: RemoteEntryKind
            switch firstModeCharacter {
            case "d": kind = .directory
            case "-": kind = .file
            case "l": kind = .symbolicLink
            default: kind = .other
            }
            if path == parent {
                guard kind == .directory else { throw EngineError.notDirectory(parent) }
                continue
            }
            guard path.parent == parent else { continue }
            entries.append(RemoteEntry(path: path, kind: kind, size: kind == .file ? size : nil,
                                       modifiedAt: Date(timeIntervalSince1970: modifiedSeconds)))
        }
        return entries.sorted { RemotePath.bytewiseLess($0.path, $1.path) }
    }

    private static func deviceState(_ value: String) -> DeviceState? {
        switch value {
        case "device": .device
        case "unauthorized": .unauthorized
        case "offline": .offline
        case "bootloader": .bootloader
        case "recovery": .recovery
        case "sideload": .sideload
        default: value.isEmpty ? nil : .unknown(value)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func unsupportedPrintf(_ diagnostic: String) -> Bool {
        let value = diagnostic.lowercased()
        return value.contains("unknown option") && value.contains("-printf")
            || value.contains("unrecognized option") && value.contains("-printf")
            || value.contains("bad option") && value.contains("-printf")
    }

    private static func isUnavailableDeviceDiagnostic(_ diagnostic: String, serial: String) -> Bool {
        diagnostic.contains("no devices/emulators found")
            || diagnostic.contains("device offline")
            || diagnostic.contains("device unauthorized")
            || diagnostic.contains("device not found")
            || diagnostic.contains("device '\(serial.lowercased())' not found")
    }
}
