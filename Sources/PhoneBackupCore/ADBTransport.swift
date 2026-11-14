import Foundation
import Darwin
import CryptoKit

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
                               homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                               fileManager: FileManager = .default) -> URL? {
        if let preferredExecutable, isExecutableFile(at: preferredExecutable, fileManager: fileManager) {
            return preferredExecutable.standardizedFileURL
        }
        return resolve(environment: environment, homeDirectory: homeDirectory, fileManager: fileManager)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let sdkRoots = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]]
            .compactMap { value -> String? in
                guard let value, value.hasPrefix("/"), !value.isEmpty else { return nil }
                return value
            }
            + [homeDirectory.appendingPathComponent("Library/Android/sdk", isDirectory: true).path]
        var candidates = [homeDirectory.appendingPathComponent(
            "Library/Application Support/Androdo/Platform Tools/current/platform-tools/adb").path]
        for root in sdkRoots {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("platform-tools/adb").path)
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb"])
        for entry in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where entry.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: entry).appendingPathComponent("adb").path)
        }

        var checkedPaths = Set<String>()
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            guard checkedPaths.insert(url.path).inserted else { continue }
            if isExecutableFile(at: url, fileManager: fileManager) {
                return url
            }
        }
        return nil
    }
}

public actor ADBTransport: DeviceTransport, RemoteDestinationAccess {
    private static let findFormat = "%M|%s|%T@|%p\\0"

    private let configuration: ADBConfiguration
    private let runner: any CommandRunning
    private var findPrintfSupport: [UUID: Bool] = [:]
    private var activeSessions: [UUID: DeviceSession] = [:]

    public init(configuration: ADBConfiguration, runner: any CommandRunning = ProcessCommandRunner()) {
        self.configuration = configuration
        self.runner = runner
    }

    public func connectedDevices() async throws -> DeviceDiscoveryResult {
        try Task.checkCancellation()
        let output = try await rawCommand(["devices", "-l"])
        guard output.exitCode == 0 else {
            throw EngineError.transport("ADB could not list connected devices")
        }
        let previousSessions = Array(activeSessions.values)
        let lines = String(decoding: output.data, as: UTF8.self).split(whereSeparator: \.isNewline)
        var issues: [DeviceDiscoveryIssue] = []
        var grouped: [DeviceID: (DeviceIdentityEvidence, String?, [DeviceSession])] = [:]
        var conflictingIDs = Set<DeviceID>()

        for line in lines {
            try Task.checkCancellation()
            guard !line.starts(with: "List of devices attached") else { continue }
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2, columns[0] != "*",
                  let state = Self.deviceState(String(columns[1])) else { continue }
            let attributes = columns.dropFirst(2).reduce(into: [String: String]()) { result, column in
                let field = column.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if field.count == 2 { result[String(field[0])] = String(field[1]) }
            }
            let model = attributes["model"]

            guard state == .device else {
                let kind: DeviceDiscoveryIssueKind = state == .unauthorized ? .unauthorized : .offline
                issues.append(DeviceDiscoveryIssue(kind: kind, state: state, model: model))
                continue
            }

            guard let transportID = attributes["transport_id"].flatMap(Int.init), transportID > 0 else {
                issues.append(DeviceDiscoveryIssue(kind: .unsupportedConnection, state: state, model: model))
                continue
            }
            let selector = String(columns[0])
            let identityOutput: CommandOutput
            do {
                identityOutput = try await rawCommand(["-t", String(transportID), "shell", Self.identityProbe])
                guard identityOutput.exitCode == 0 else { throw EngineError.invalidIdentifier }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(DeviceDiscoveryIssue(kind: .identityUnavailable, state: state, model: model))
                continue
            }

            let evidence: DeviceIdentityEvidence
            do { evidence = try DeviceIdentityEvidence.parse(identityOutput.data) }
            catch {
                issues.append(DeviceDiscoveryIssue(kind: .identityUnavailable, state: state, model: model))
                continue
            }
            let id = evidence.deviceID
            let connectionKind = try await connectionKind(transportID: transportID)
            guard try await supportsGuardedTransfers(transportID: transportID, evidence: evidence) else {
                issues.append(DeviceDiscoveryIssue(kind: .transferProtocolUnavailable, state: state, model: model))
                continue
            }
            let priorSession = previousSessions.first {
                $0.deviceID == id && $0.identityEvidence == evidence &&
                $0.connection.kind == connectionKind &&
                $0.connection.transportID == transportID && $0.connection.selector == selector
            }
            let session = priorSession ?? DeviceSession(
                deviceID: id,
                connection: ADBConnectionSession(kind: connectionKind, transportID: transportID, selector: selector),
                identityEvidence: evidence
            )

            if let existing = grouped[id] {
                guard existing.0 == evidence else {
                    conflictingIDs.insert(id)
                    continue
                }
                let sessions = existing.2.contains(where: { $0.connection.generation == session.connection.generation })
                    ? existing.2 : existing.2 + [session]
                grouped[id] = (existing.0, existing.1 ?? attributes["product"], sessions)
            } else {
                grouped[id] = (evidence, attributes["product"], [session])
            }
        }

        try Task.checkCancellation()
        for id in conflictingIDs { grouped.removeValue(forKey: id) }
        activeSessions = Dictionary(uniqueKeysWithValues: grouped.values.flatMap(\.2).map { ($0.connection.generation, $0) })
        findPrintfSupport = findPrintfSupport.filter { activeSessions[$0.key] != nil }
        let devices = grouped.map { id, value in
            let ordered = value.2.sorted { lhs, rhs in
                if lhs.connection.kind == .usb { return true }
                if rhs.connection.kind == .usb { return false }
                return lhs.connection.transportID < rhs.connection.transportID
            }
            return AndroidDevice(id: id, state: .device, model: value.0.model,
                                 product: value.1, sessions: ordered)
        }.sorted { $0.id.value < $1.id.value }
        return DeviceDiscoveryResult(devices: devices, issues: issues)
    }

    private static let identityMismatchMarker = "ANDRODO_DEVICE_IDENTITY_MISMATCH"
    private static let identityProbe = "printf '%s\\000%s\\000%s\\000' \"$(getprop ro.serialno)\" \"$(getprop ro.product.manufacturer)\" \"$(getprop ro.product.model)\""
    private static let shellV2ProbeExitCode: Int32 = 73
    private static let shellV2ProbeOutput = Data("ANDRODO_SHELL_V2_STDOUT".utf8)
    private static let shellV2ProbeError = Data("ANDRODO_SHELL_V2_STDERR".utf8)
    private static let shellV2ProbeCommand = "printf 'ANDRODO_SHELL_V2_STDOUT'; printf 'ANDRODO_SHELL_V2_STDERR' >&2; exit 73"

    private func connectionKind(transportID: Int) async throws -> ADBConnectionKind {
        let output: CommandOutput
        do {
            output = try await rawCommand(["-t", String(transportID), "get-devpath"])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .other
        }
        guard output.exitCode == 0 else { return .other }
        let path = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || path == "unknown" { return .wireless }
        return .usb
    }

    private func supportsGuardedTransfers(transportID: Int, evidence: DeviceIdentityEvidence) async throws -> Bool {
        let command = Self.identityGuard(Self.shellV2ProbeCommand, evidence: evidence)
        let output: CommandOutput
        do {
            output = try await rawCommand(["-t", String(transportID), "shell", "-T", command])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
        return output.exitCode == Self.shellV2ProbeExitCode
            && output.data == Self.shellV2ProbeOutput
            && output.standardError == Self.shellV2ProbeError
    }

    public func children(of path: RemotePath, on session: DeviceSession) async throws -> [RemoteEntry] {
        if findPrintfSupport[session.connection.generation] == false {
            throw EngineError.unsupportedDirectoryListing(session.deviceID)
        }

        let remoteCommand = "find -H \(Self.shellQuote(path.description)) -mindepth 0 -maxdepth 1 -printf \(Self.shellQuote(Self.findFormat))"
        let output: Data
        do {
            // `adb shell` joins its trailing arguments into one remote command string.
            // Pass the complete, safely quoted command as one argument; wrapping it in
            // `sh -c` would require a second quoting layer and can drop find's arguments.
            output = try await command(["-t", String(session.connection.transportID), "shell", remoteCommand], path: path, session: session)
        } catch let EngineError.transport(message) where Self.unsupportedPrintf(message) {
            findPrintfSupport[session.connection.generation] = false
            throw EngineError.unsupportedDirectoryListing(session.deviceID)
        }
        findPrintfSupport[session.connection.generation] = true
        return try Self.parseImmediateChildren(output, parent: path)
    }

    public func metadata(of path: RemotePath, on session: DeviceSession) async throws -> RemoteEntry {
        let remoteCommand = "find -H \(Self.shellQuote(path.description)) -mindepth 0 -maxdepth 0 -printf \(Self.shellQuote(Self.findFormat))"
        let output = try await command(["-t", String(session.connection.transportID), "shell", remoteCommand], path: path, session: session)
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

    public func pull(from path: RemotePath, on session: DeviceSession, to localURL: URL) async throws {
        guard !Self.pathEntryExists(localURL) else {
            throw EngineError.transport("The local ADB transfer destination already exists")
        }
        let remoteCommand = "cat -- \(Self.shellQuote(path.description))"
        _ = try await command(["-t", String(session.connection.transportID), "shell", "-T", remoteCommand],
                              path: path, session: session, fileIO: CommandFileIO(outputFile: localURL))
    }

    public func push(from localURL: URL, to path: RemotePath, on session: DeviceSession) async throws {
        let readyFrame = Data("ANDRODO_READY_TO_RECEIVE\n".utf8)
        let approvalFrame = Data("ANDRODO_TRANSFER_APPROVED\n".utf8)
        let receiver = "printf 'ANDRODO_READY_TO_RECEIVE\\n'; IFS= read -r answer || exit 125; test \"$answer\" = ANDRODO_TRANSFER_APPROVED || exit 125; cat > \(Self.shellQuote(path.description))"
        _ = try await command(["-t", String(session.connection.transportID), "shell", "-T", receiver],
                              path: path, session: session,
                              fileIO: CommandFileIO(inputFile: localURL,
                                                   inputGate: CommandInputGate(readyFrame: readyFrame,
                                                                              approvalFrame: approvalFrame)))
    }

    public func inspectDestination(_ path: RemotePath, on session: DeviceSession) async throws -> RemoteDestinationState {
        let remote = Self.destinationInspectionScript(for: Self.shellQuote(path.description))
        let output = try await command(["-t", String(session.connection.transportID), "shell", remote], path: path, session: session)
        let record = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try Self.destinationState(record)
    }

    /// Reads only the requested metadata, in bounded commands. Records never contain filenames.
    public func inspectDestinations(_ paths: [RemotePath], on session: DeviceSession) async throws -> [RemotePath: RemoteDestinationState] {
        let paths = Array(Set(paths)).sorted(by: RemotePath.bytewiseLess)
        var states: [RemotePath: RemoteDestinationState] = [:]
        var offset = 0
        while offset < paths.count {
            try Task.checkCancellation()
            var batch: [RemotePath] = []
            var arguments: [String] = []
            var byteCount = 0
            while offset < paths.count, batch.count < 64 {
                let quoted = Self.shellQuote(paths[offset].description)
                guard quoted.utf8.count < 24_000 else { throw EngineError.invalidRemotePath("Destination path is too long") }
                if !batch.isEmpty, byteCount + quoted.utf8.count + 1 > 24_000 { break }
                batch.append(paths[offset])
                arguments.append(quoted)
                byteCount += quoted.utf8.count + 1
                offset += 1
            }
            let script = "for p in \(arguments.joined(separator: " ")); do \(Self.destinationInspectionScript(for: "\"$p\"")); printf '\\000'; done"
            let output = try await command(["-t", String(session.connection.transportID), "shell", script], path: batch[0], session: session)
            var records = output.split(separator: 0, omittingEmptySubsequences: false)
            guard records.last?.isEmpty == true, records.count == batch.count + 1 else {
                throw EngineError.transport("ADB returned an incomplete destination batch")
            }
            records.removeLast()
            for (path, bytes) in zip(batch, records) {
                guard let record = String(bytes: bytes, encoding: .utf8) else {
                    throw EngineError.transport("ADB returned invalid destination metadata")
                }
                states[path] = try Self.destinationState(record)
            }
        }
        return states
    }

    private static func destinationInspectionScript(for quoted: String) -> String {
        let identity = "\"$(stat -c '%d:%i:%s:%y' \(quoted) 2>/dev/null)\""
        return "if [ -L \(quoted) ]; then printf 'L|%s' \(identity); elif [ -f \(quoted) ]; then printf 'F|%s' \(identity); elif [ -d \(quoted) ]; then printf 'D|%s' \(identity); elif [ -e \(quoted) ]; then printf 'O|%s' \(identity); else printf 'M'; fi"
    }

    private static func destinationState(_ record: String) throws -> RemoteDestinationState {
        if record == "M" { return .missing }
        let fields = record.split(separator: "|", maxSplits: 1).map(String.init)
        guard fields.count == 2 else { throw EngineError.transport("ADB returned invalid destination metadata") }
        let stats = fields[1].split(separator: ":", maxSplits: 3)
        guard stats.count == 4, let size = Int64(stats[2]), size >= 0 else {
            throw EngineError.transport("ADB returned invalid destination identity")
        }
        switch fields[0] {
        case "F": return .regularFile(identity: fields[1], size: size)
        case "D": return .directory(identity: fields[1])
        case "L": return .symbolicLink(identity: fields[1])
        case "O": return .other(identity: fields[1])
        default: throw EngineError.transport("ADB returned an unknown destination type")
        }
    }

    public func createDestinationDirectory(_ path: RemotePath, on session: DeviceSession) async throws {
        switch try await inspectDestination(path, on: session) {
        case .directory: return
        case .missing:
            let remote = "mkdir \(Self.shellQuote(path.description))"
            _ = try await command(["-t", String(session.connection.transportID), "shell", remote], path: path, session: session)
            guard case .directory = try await inspectDestination(path, on: session) else {
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
            }
        case .regularFile, .symbolicLink, .other:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
        }
    }

    public func publishStagedFile(from localURL: URL, to path: RemotePath, on session: DeviceSession,
                                  expected: ContentObjectReference, replacing approvedIdentity: String?) async throws {
        let parent = path.parent ?? .root
        let stage = try parent.appending(".phonebackup-restore-\(UUID().uuidString.lowercased())")
        let initial = try await inspectDestination(path, on: session)
        try Self.requireDestinationApproval(initial, path: path, approvedIdentity: approvedIdentity)
        guard case .missing = try await inspectDestination(stage, on: session) else {
            throw EngineError.destinationConflict(TransferConflict(destination: stage.description, kind: .unsafePath))
        }
        let verification = FileManager.default.temporaryDirectory.appendingPathComponent("phonebackup-remote-verify-\(UUID().uuidString.lowercased())")
        var published = false
        var publicationAttempted = false
        do {
            try await push(from: localURL, to: stage, on: session)
            try await pull(from: stage, on: session, to: verification)
            try await Self.verifyLocalFile(verification, expected: expected)
            try await verifyDestinationAncestors(parent, on: session)
            let current = try await inspectDestination(path, on: session)
            try Self.requireDestinationApproval(current, path: path, approvedIdentity: approvedIdentity)
            if approvedIdentity == nil {
                let remote = "ln -T \(Self.shellQuote(stage.description)) \(Self.shellQuote(path.description))"
                publicationAttempted = true
                do {
                    _ = try await command(["-t", String(session.connection.transportID), "shell", remote], path: path, session: session)
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
                _ = try await command(["-t", String(session.connection.transportID), "shell", remote], path: path, session: session)
                published = true
            }
            let finalVerification = FileManager.default.temporaryDirectory.appendingPathComponent("phonebackup-remote-final-\(UUID().uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: finalVerification) }
            try await pull(from: path, on: session, to: finalVerification)
            try await Self.verifyLocalFile(finalVerification, expected: expected)
            let cleanup = "rm -f \(Self.shellQuote(stage.description))"
            _ = try? await command(["-t", String(session.connection.transportID), "shell", cleanup], path: path, session: session)
        } catch {
            await Task.detached { await self.removeRemoteStage(stage, on: session) }.value
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

    private func removeRemoteStage(_ stage: RemotePath, on session: DeviceSession) async {
        let cleanup = "rm -f \(Self.shellQuote(stage.description))"
        _ = try? await command(["-t", String(session.connection.transportID), "shell", cleanup], path: stage, session: session)
    }

    private func verifyDestinationAncestors(_ parent: RemotePath, on session: DeviceSession) async throws {
        var current = RemotePath.root
        for (index, component) in parent.components.enumerated() {
            current = try current.appending(component)
            if index == 0 && component == "sdcard" { continue }
            guard case .directory = try await inspectDestination(current, on: session) else {
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

    private func command(_ arguments: [String], path: RemotePath? = nil, session: DeviceSession? = nil,
                         fileIO: CommandFileIO = .none) async throws -> Data {
        var commandArguments = arguments
        if let session {
            guard activeSessions[session.connection.generation] == session,
                  commandArguments.starts(with: ["-t", String(session.connection.transportID)]) else {
                throw EngineError.deviceUnavailable(session.deviceID)
            }
            if commandArguments.count >= 4, commandArguments[2] == "shell" {
                guard let evidence = session.identityEvidence else { throw EngineError.deviceUnavailable(session.deviceID) }
                let remoteCommandIndex = commandArguments[3] == "-T" ? 4 : 3
                guard commandArguments.indices.contains(remoteCommandIndex) else {
                    throw EngineError.transport("ADB shell command is incomplete")
                }
                commandArguments[remoteCommandIndex] = Self.identityGuard(commandArguments[remoteCommandIndex], evidence: evidence)
            }
        }

        let output = try await rawCommand(commandArguments, fileIO: fileIO)
        guard output.exitCode == 0 else {
            var diagnostic = String(decoding: output.standardError + output.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = diagnostic.lowercased()
            if let session, lowercased.contains(Self.identityMismatchMarker.lowercased()) {
                throw EngineError.deviceUnavailable(session.deviceID)
            }
            if let path, lowercased.contains("no such file or directory") { throw EngineError.missingPath(path) }
            if let path, lowercased.contains("permission denied") || lowercased.contains("operation not permitted") {
                throw EngineError.inaccessiblePath(path)
            }
            if let session, Self.isUnavailableDeviceDiagnostic(lowercased, serial: session.connection.selector) {
                throw EngineError.deviceUnavailable(session.deviceID)
            }
            if let session, !session.connection.selector.isEmpty {
                diagnostic = diagnostic.replacingOccurrences(of: session.connection.selector, with: "selected connection")
            }
            throw EngineError.transport(diagnostic.isEmpty ? "ADB exited with status \(output.exitCode)" : diagnostic)
        }
        if let gate = fileIO.inputGate, !output.data.starts(with: gate.readyFrame) {
            throw EngineError.transport("ADB did not confirm the verified transfer route")
        }
        return output.data
    }

    private static func identityGuard(_ remoteCommand: String, evidence: DeviceIdentityEvidence) -> String {
        let checks = [
            "test \"$(getprop ro.serialno)\" = \(shellQuote(evidence.serialNumber))",
            "test \"$(getprop ro.product.manufacturer)\" = \(shellQuote(evidence.manufacturer))",
            "test \"$(getprop ro.product.model)\" = \(shellQuote(evidence.model))"
        ].joined(separator: " && ")
        return "if \(checks); then \(remoteCommand); else printf '\(identityMismatchMarker)' >&2; exit 125; fi"
    }

    private func rawCommand(_ arguments: [String], fileIO: CommandFileIO = .none) async throws -> CommandOutput {
        do {
            return try await runner.run(executable: configuration.executable,
                                        arguments: arguments,
                                        timeout: configuration.commandTimeout,
                                        fileIO: fileIO)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.transport(error.localizedDescription)
        }
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

    private static func pathEntryExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { Darwin.lstat($0, &info) == 0 || errno != ENOENT }
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
