import Foundation
import Darwin

/// Coordinates read-only previews and cancellable, resumable shared-file backups.
public actor DefaultBackupEngine: BackupEngine {
    private struct Request: Sendable {
        let repository: RepositoryID
        let device: DeviceID
        let selection: BackupSelection
    }

    private struct OmissionKey: Hashable {
        let code: WarningCode
        let path: RemotePath?
        let message: String
    }

    private struct ScanResult: Sendable {
        var entries: [RemoteEntry] = []
        var omissions: [OperationWarning] = []
        var visitedCount = 0

        mutating func merge(_ other: ScanResult) {
            entries.append(contentsOf: other.entries)
            omissions.append(contentsOf: other.omissions)
            visitedCount += other.visitedCount
        }
    }

    private final class VisitedPaths {
        var paths = Set<RemotePath>()
    }

    private struct OperationRecord {
        var latestEvent: OperationEvent
        var subscribers: [UUID: AsyncStream<OperationEvent>.Continuation] = [:]
        var isFinished = false
    }

    private let remote: any RemoteFileAccess
    private let repositoryStore: any BackupRepositoryWriting
    private let stagingRoot: URL
    private let maximumTransferAttempts: Int

    private var plannedRequests: [BackupPlanID: Request] = [:]
    private var operationRecords: [OperationID: OperationRecord] = [:]
    private var operationTasks: [OperationID: Task<Void, Never>] = [:]
    private var activeRepositories: Set<RepositoryID> = []

    public init(
        remote: any RemoteFileAccess,
        repositoryStore: any BackupRepositoryWriting,
        stagingRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneBackup-Staging", isDirectory: true),
        maximumTransferAttempts: Int = 3
    ) {
        self.remote = remote
        self.repositoryStore = repositoryStore
        self.stagingRoot = stagingRoot
        self.maximumTransferAttempts = max(1, maximumTransferAttempts)
    }

    public func plan(repository: RepositoryID, device: DeviceID, selection: BackupSelection) async throws -> BackupPlan {
        guard !selection.normalizedRoots.isEmpty else { throw EngineError.emptySelection }
        let repositoryInfo = try await requireRepository(repository, for: device)
        let previous = try await latestPoint(in: repository)
        let priorEntries: [BackupEntry]
        if let previous {
            priorEntries = try await repositoryStore.entries(in: repository, point: previous.id, below: nil)
        } else {
            priorEntries = []
        }
        let scan = try await scan(selection: selection, device: device, operation: nil)
        let plan = try await makePlan(repository: repository, device: device, selection: selection,
                                      scan: scan, priorEntries: priorEntries)
        plannedRequests[plan.id] = Request(repository: repositoryInfo.id, device: device, selection: selection)
        return plan
    }

    public func startBackup(using plan: BackupPlanID, omissions: BackupOmissionChoice = .requireComplete) async throws -> OperationID {
        guard let request = plannedRequests.removeValue(forKey: plan) else {
            throw EngineError.transport("Backup plan has expired; create a new plan")
        }
        return try await launch(request: request, attempt: nil, omissions: omissions)
    }

    public func resumeBackup(_ attempt: BackupAttemptID, omissions: BackupOmissionChoice = .requireComplete) async throws -> OperationID {
        let storedAttempt = try await findAttempt(attempt)
        let request = Request(repository: storedAttempt.repository, device: storedAttempt.device, selection: storedAttempt.selection)
        return try await launch(request: request, attempt: storedAttempt, omissions: omissions)
    }

    public func finishWithOmissions(_ attempt: BackupAttemptID) async throws -> OperationID {
        try await resumeBackup(attempt, omissions: .finishWithOmissions)
    }

    public func attempts(in repository: RepositoryID) async throws -> [BackupAttempt] {
        try await repositoryStore.backupAttempts(in: repository)
    }

    public func events(for operation: OperationID) async -> AsyncStream<OperationEvent> {
        let (stream, continuation) = AsyncStream<OperationEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        guard var record = operationRecords[operation] else {
            continuation.finish()
            return stream
        }
        continuation.yield(record.latestEvent)
        if record.isFinished {
            continuation.finish()
        } else {
            let subscriberID = UUID()
            record.subscribers[subscriberID] = continuation
            operationRecords[operation] = record
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID, from: operation) }
            }
        }
        return stream
    }

    public func cancel(_ operation: OperationID) async {
        operationTasks[operation]?.cancel()
    }

    private func launch(request: Request, attempt existingAttempt: BackupAttempt?, omissions: BackupOmissionChoice) async throws -> OperationID {
        guard activeRepositories.insert(request.repository).inserted else {
            let info = try await repositoryInfo(request.repository)
            throw EngineError.repositoryBusy(info.location)
        }
        do {
            _ = try await requireRepository(request.repository, for: request.device)
            let attempt: BackupAttempt
            if let existingAttempt {
                attempt = try await repositoryStore.backupAttempt(existingAttempt.id, in: request.repository)
                try await repositoryStore.updateBackupAttempt(attempt.id, in: request.repository, state: .running, omissions: attempt.omissions)
            } else {
                attempt = try await repositoryStore.beginBackupAttempt(in: request.repository, device: request.device, selection: request.selection)
            }
            let operation = OperationID()
            operationRecords[operation] = OperationRecord(latestEvent: OperationEvent(operationID: operation, phase: .scanning))
            let task = Task { [weak self] in
                guard let self else { return }
                await self.run(operation: operation, request: request, attempt: attempt, omissions: omissions)
            }
            operationTasks[operation] = task
            return operation
        } catch {
            activeRepositories.remove(request.repository)
            throw error
        }
    }

    private func run(operation: OperationID, request: Request, attempt: BackupAttempt, omissions choice: BackupOmissionChoice) async {
        var currentOmissions: [OperationWarning] = []
        defer {
            activeRepositories.remove(request.repository)
            operationTasks.removeValue(forKey: operation)
        }
        do {
            try Task.checkCancellation()
            let scanResult = try await scan(selection: request.selection, device: request.device, operation: operation)
            currentOmissions = scanResult.omissions
            emit(OperationEvent(operationID: operation, phase: .planning,
                                progress: OperationProgress(completedItems: scanResult.visitedCount), warnings: currentOmissions), for: operation)

            let latest = try await latestPoint(in: request.repository)
            let priorEntries: [BackupEntry]
            if let latest {
                priorEntries = try await repositoryStore.entries(in: request.repository, point: latest.id, below: nil)
            } else {
                priorEntries = []
            }
            let previousByPath = Dictionary(uniqueKeysWithValues: priorEntries.map { ($0.path, $0) })
            let checkpoints = try await repositoryStore.checkpoints(for: attempt.id, in: request.repository)
            let checkpointsByPath = Dictionary(uniqueKeysWithValues: checkpoints.map { ($0.path, $0) })
            let remoteFiles = scanResult.entries.filter { $0.kind == .file }
            var transferFiles: [RemoteEntry] = []
            var reused: [RemotePath: ContentObjectReference] = [:]
            for entry in remoteFiles {
                try Task.checkCancellation()
                if let checkpoint = checkpointsByPath[entry.path], Self.metadataMatches(entry, checkpoint: checkpoint) {
                    let reference = ContentObjectReference(sha256: checkpoint.contentHash, size: checkpoint.size)
                    try await repositoryStore.verifyObject(reference, in: request.repository)
                    reused[entry.path] = reference
                    continue
                }
                if let previous = previousByPath[entry.path], Self.metadataMatches(entry, previous: previous),
                   let hash = previous.contentHash {
                    let reference = ContentObjectReference(sha256: hash, size: previous.size)
                    try await repositoryStore.verifyObject(reference, in: request.repository)
                    reused[entry.path] = reference
                    continue
                }
                transferFiles.append(entry)
            }
            let bytesToTransfer = try Self.sum(transferFiles.compactMap(\.size))
            emit(OperationEvent(operationID: operation, phase: .transferring,
                                progress: OperationProgress(completedItems: reused.count, totalItems: remoteFiles.count,
                                                            completedBytes: 0, totalBytes: bytesToTransfer),
                                warnings: currentOmissions), for: operation)

            var manifestEntries: [BackupEntry] = scanResult.entries.compactMap { entry in
                if entry.kind == .directory {
                    return BackupEntry(path: entry.path, kind: .directory, size: 0, modifiedAt: entry.modifiedAt, contentHash: nil)
                }
                return nil
            }
            var transferredItems = 0
            var transferredBytes: Int64 = 0
            for entry in remoteFiles {
                try Task.checkCancellation()
                if let reference = reused[entry.path] {
                    manifestEntries.append(BackupEntry(path: entry.path, kind: .file, size: reference.size,
                                                       modifiedAt: entry.modifiedAt, contentHash: reference.sha256))
                    continue
                }
                let result = try await transfer(entry, device: request.device, repository: request.repository,
                                                attempt: attempt.id, operation: operation)
                currentOmissions.append(contentsOf: result.omissions)
                if let transferred = result.entry {
                    manifestEntries.append(transferred)
                    transferredItems += 1
                    transferredBytes = try Self.add(transferred.size, to: transferredBytes)
                }
                let completed = reused.count + transferredItems
                emit(OperationEvent(operationID: operation, phase: .transferring,
                                    progress: OperationProgress(completedItems: completed, totalItems: remoteFiles.count,
                                                                completedBytes: transferredBytes, totalBytes: bytesToTransfer),
                                    warnings: currentOmissions), for: operation)
            }

            currentOmissions = Self.uniqueWarnings(currentOmissions)
            try await repositoryStore.updateBackupAttempt(attempt.id, in: request.repository,
                                                          state: currentOmissions.isEmpty ? .running : .needsOmissionDecision,
                                                          omissions: currentOmissions)
            emit(OperationEvent(operationID: operation, phase: .verifying,
                                progress: OperationProgress(completedItems: manifestEntries.filter { $0.kind == .file }.count,
                                                            totalItems: remoteFiles.count,
                                                            completedBytes: transferredBytes,
                                                            totalBytes: bytesToTransfer),
                                warnings: currentOmissions), for: operation)
            for entry in manifestEntries where entry.kind == .file {
                try Task.checkCancellation()
                guard let hash = entry.contentHash else { throw EngineError.corruptedRepository("File has no content hash") }
                try await repositoryStore.verifyObject(ContentObjectReference(sha256: hash, size: entry.size), in: request.repository)
            }

            let omissionsWereExplicitlyAccepted = choice == .finishWithOmissions &&
                Self.omissionKeys(currentOmissions) == Self.omissionKeys(attempt.omissions)
            if !currentOmissions.isEmpty && !omissionsWereExplicitlyAccepted {
                emit(OperationEvent(operationID: operation, phase: .incomplete,
                                    progress: OperationProgress(completedItems: manifestEntries.count, totalItems: scanResult.entries.count,
                                                            completedBytes: transferredBytes,
                                                                totalBytes: bytesToTransfer),
                                    warnings: currentOmissions), for: operation)
                finish(operation)
                return
            }

            try Task.checkCancellation()
            emit(OperationEvent(operationID: operation, phase: .committing,
                                progress: OperationProgress(completedItems: manifestEntries.count, totalItems: scanResult.entries.count,
                                                            completedBytes: transferredBytes,
                                                            totalBytes: bytesToTransfer),
                                warnings: currentOmissions), for: operation)
            let manifest = RestorePointManifest(selection: request.selection,
                                                entries: manifestEntries.sorted { RemotePath.bytewiseLess($0.path, $1.path) },
                                                omissions: currentOmissions)
            _ = try await repositoryStore.publish(manifest, in: request.repository, completing: attempt.id)
            emit(OperationEvent(operationID: operation, phase: .completed,
                                progress: OperationProgress(completedItems: manifestEntries.count, totalItems: scanResult.entries.count,
                                                            completedBytes: try Self.sum(manifestEntries.filter { $0.kind == .file && !reused.keys.contains($0.path) }.map(\.size)),
                                                            totalBytes: bytesToTransfer), warnings: currentOmissions), for: operation)
            finish(operation)
        } catch is CancellationError {
            try? await repositoryStore.updateBackupAttempt(attempt.id, in: request.repository, state: .interrupted, omissions: currentOmissions)
            emit(OperationEvent(operationID: operation, phase: .cancelled, warnings: currentOmissions), for: operation)
            finish(operation)
        } catch let error as EngineError {
            try? await repositoryStore.updateBackupAttempt(attempt.id, in: request.repository, state: .interrupted, omissions: currentOmissions)
            emit(OperationEvent(operationID: operation, phase: .failed, warnings: currentOmissions, failure: error), for: operation)
            finish(operation)
        } catch {
            let failure = EngineError.transport(error.localizedDescription)
            try? await repositoryStore.updateBackupAttempt(attempt.id, in: request.repository, state: .interrupted, omissions: currentOmissions)
            emit(OperationEvent(operationID: operation, phase: .failed, warnings: currentOmissions, failure: failure), for: operation)
            finish(operation)
        }
    }

    private func scan(selection: BackupSelection, device: DeviceID, operation: OperationID?) async throws -> ScanResult {
        guard !selection.normalizedRoots.isEmpty else { throw EngineError.emptySelection }
        var result = ScanResult()
        let visited = VisitedPaths()
        for root in selection.normalizedRoots {
            try Task.checkCancellation()
            guard selection.includes(root) else { continue }
            do {
                let entry = try await remote.metadata(of: root, on: device)
                result.merge(try await scan(entry, selection: selection, device: device, visited: visited, operation: operation))
            } catch let error as EngineError {
                if let warning = Self.omission(for: error, path: root) { result.omissions.append(warning) }
                else { throw error }
            }
        }
        result.entries = Dictionary(result.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { RemotePath.bytewiseLess($0.path, $1.path) }
        result.omissions = Self.uniqueWarnings(result.omissions)
        return result
    }

    private func scan(_ entry: RemoteEntry, selection: BackupSelection, device: DeviceID,
                      visited: VisitedPaths, operation: OperationID?) async throws -> ScanResult {
        try Task.checkCancellation()
        guard selection.includes(entry.path), visited.paths.insert(entry.path).inserted else { return ScanResult() }
        var result = ScanResult(visitedCount: 1)
        if let operation {
            emit(OperationEvent(operationID: operation, phase: .scanning,
                                progress: OperationProgress(completedItems: visited.paths.count)), for: operation)
        }
        switch entry.kind {
        case .file:
            guard let size = entry.size, size >= 0 else {
                result.omissions.append(OperationWarning(code: .sourceChanged, path: entry.path, message: "File size was unavailable during scan."))
                return result
            }
            result.entries.append(RemoteEntry(path: entry.path, kind: .file, size: size, modifiedAt: entry.modifiedAt))
        case .directory:
            result.entries.append(RemoteEntry(path: entry.path, kind: .directory, size: nil, modifiedAt: entry.modifiedAt))
            do {
                let children = try await remote.children(of: entry.path, on: device)
                for child in children.sorted(by: { RemotePath.bytewiseLess($0.path, $1.path) }) {
                    try Task.checkCancellation()
                    guard child.path.parent == entry.path else {
                        result.omissions.append(OperationWarning(code: .unsupportedFilename, path: entry.path,
                                                                 message: "A directory entry could not be represented safely."))
                        continue
                    }
                    if !selection.includes(child.path) { continue }
                    result.merge(try await scan(child, selection: selection, device: device, visited: visited, operation: operation))
                }
            } catch let error as EngineError {
                if let warning = Self.omission(for: error, path: entry.path) { result.omissions.append(warning) }
                else { throw error }
            }
        case .symbolicLink, .other:
            result.omissions.append(OperationWarning(code: .unsupportedEntryKind, path: entry.path,
                                                     message: "This entry type is not included in file backups."))
        }
        return result
    }

    private func transfer(_ scanned: RemoteEntry, device: DeviceID, repository: RepositoryID,
                          attempt: BackupAttemptID, operation: OperationID) async throws -> (entry: BackupEntry?, omissions: [OperationWarning]) {
        var lastError: EngineError?
        for tryIndex in 0..<maximumTransferAttempts {
            try Task.checkCancellation()
            let before: RemoteEntry
            do { before = try await remote.metadata(of: scanned.path, on: device) }
            catch let error as EngineError {
                if let warning = Self.omission(for: error, path: scanned.path) { return (nil, [warning]) }
                throw error
            }
            guard before.kind == .file, let expectedSize = before.size, expectedSize >= 0 else {
                lastError = .sourceChanged(scanned.path)
                continue
            }
            let localURL = stagingRoot.appendingPathComponent(UUID().uuidString.lowercased())
            do {
                try Self.prepareStagingDirectory(stagingRoot)
                try await remote.pull(from: scanned.path, on: device, to: localURL)
                let after = try await remote.metadata(of: scanned.path, on: device)
                let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard after.kind == .file, after.size == expectedSize,
                      after.modifiedAt == before.modifiedAt,
                      values.isRegularFile == true, let localSize = values.fileSize,
                      Int64(localSize) == expectedSize else {
                    lastError = .sourceChanged(scanned.path)
                    try? FileManager.default.removeItem(at: localURL)
                    continue
                }
                let reference = try await repositoryStore.importFile(from: localURL, expectedSize: expectedSize, into: repository)
                try await repositoryStore.saveCheckpoint(
                    BackupCheckpoint(path: scanned.path, size: expectedSize, modifiedAt: after.modifiedAt,
                                     contentHash: reference.sha256), for: attempt, in: repository
                )
                let backupEntry = BackupEntry(path: scanned.path, kind: .file, size: expectedSize,
                                              modifiedAt: after.modifiedAt, contentHash: reference.sha256)
                try? FileManager.default.removeItem(at: localURL)
                _ = tryIndex
                return (backupEntry, [])
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: localURL)
                throw CancellationError()
            } catch let error as EngineError {
                try? FileManager.default.removeItem(at: localURL)
                if let warning = Self.omission(for: error, path: scanned.path) { return (nil, [warning]) }
                lastError = error
                if case .sourceChanged = error { continue }
                throw error
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                throw error
            }
        }
        let warning = OperationWarning(code: .sourceChanged, path: scanned.path,
                                       message: "The file changed during all \(maximumTransferAttempts) transfer attempts.")
        _ = lastError
        return (nil, [warning])
    }

    private func makePlan(repository: RepositoryID, device: DeviceID, selection: BackupSelection,
                          scan: ScanResult, priorEntries: [BackupEntry]) async throws -> BackupPlan {
        let previousByPath = Dictionary(uniqueKeysWithValues: priorEntries.map { ($0.path, $0) })
        let currentPaths = Set(scan.entries.map(\.path))
        var fileCount = 0
        var directoryCount = 0
        var transferCount = 0
        var reusedCount = 0
        var bytesToTransfer: Int64 = 0
        var totalBytes: Int64 = 0
        for entry in scan.entries {
            if entry.kind == .directory { directoryCount += 1; continue }
            guard entry.kind == .file, let size = entry.size, size >= 0 else { continue }
            fileCount += 1
            totalBytes = try Self.add(size, to: totalBytes)
            if let previous = previousByPath[entry.path], Self.metadataMatches(entry, previous: previous),
               let hash = previous.contentHash {
                let reference = ContentObjectReference(sha256: hash, size: previous.size)
                try await repositoryStore.verifyObject(reference, in: repository)
                reusedCount += 1
            } else {
                transferCount += 1
                bytesToTransfer = try Self.add(size, to: bytesToTransfer)
            }
        }
        return BackupPlan(repository: repository, device: device, selection: selection, scannedAt: Date(),
                         directoryCount: directoryCount, fileCount: fileCount, transferCount: transferCount,
                         reusedCount: reusedCount, deletedCount: Set(priorEntries.map(\.path)).subtracting(currentPaths).count,
                         bytesToTransfer: bytesToTransfer, totalBytes: totalBytes, omissions: scan.omissions)
    }

    private func requireRepository(_ repository: RepositoryID, for device: DeviceID) async throws -> BackupRepositoryInfo {
        guard let info = try await repositoryStore.repositories().first(where: { $0.id == repository }) else {
            throw EngineError.corruptedRepository("Repository is not open")
        }
        guard info.deviceID == device else { throw EngineError.repositoryDeviceMismatch(repository) }
        return info
    }

    private func repositoryInfo(_ repository: RepositoryID) async throws -> BackupRepositoryInfo {
        guard let info = try await repositoryStore.repositories().first(where: { $0.id == repository }) else {
            throw EngineError.corruptedRepository("Repository is not open")
        }
        return info
    }

    private func findAttempt(_ id: BackupAttemptID) async throws -> BackupAttempt {
        for repository in try await repositoryStore.repositories() {
            if let attempt = try await repositoryStore.backupAttempts(in: repository.id).first(where: { $0.id == id }) {
                return attempt
            }
        }
        throw EngineError.transport("Backup attempt is no longer available")
    }

    private func latestPoint(in repository: RepositoryID) async throws -> RestorePoint? {
        let points = try await repositoryStore.restorePoints(in: repository)
        return points.first(where: { $0.state == .completed })
    }

    private static func metadataMatches(_ entry: RemoteEntry, previous: BackupEntry) -> Bool {
        guard entry.kind == .file, previous.kind == .file, let size = entry.size, size >= 0,
              previous.size == size, let modifiedAt = entry.modifiedAt,
              modifiedAt.timeIntervalSince1970.isFinite,
              let oldModifiedAt = previous.modifiedAt else { return false }
        return modifiedAt == oldModifiedAt
    }

    private static func metadataMatches(_ entry: RemoteEntry, checkpoint: BackupCheckpoint) -> Bool {
        guard entry.kind == .file, let size = entry.size, size >= 0, checkpoint.size == size,
              let modifiedAt = entry.modifiedAt, modifiedAt.timeIntervalSince1970.isFinite,
              let checkpointModifiedAt = checkpoint.modifiedAt else { return false }
        return modifiedAt == checkpointModifiedAt
    }

    private static func omission(for error: EngineError, path: RemotePath) -> OperationWarning? {
        switch error {
        case .missingPath, .notDirectory:
            OperationWarning(code: .missingPath, path: path, message: "The selected path is no longer available.")
        case .inaccessiblePath:
            OperationWarning(code: .inaccessiblePath, path: path, message: "Android denied access to this path.")
        case .unsupportedFilename:
            OperationWarning(code: .unsupportedFilename, path: path, message: "A name in this path cannot be represented safely.")
        case .unsupportedDirectoryListing:
            OperationWarning(code: .inaccessiblePath, path: path, message: "This device cannot list the selected directory safely.")
        case .sourceChanged:
            OperationWarning(code: .sourceChanged, path: path, message: "The file changed while it was being backed up.")
        default: nil
        }
    }

    private static func uniqueWarnings(_ warnings: [OperationWarning]) -> [OperationWarning] {
        var seen = Set<OmissionKey>()
        return warnings.filter {
            seen.insert(OmissionKey(code: $0.code, path: $0.path, message: $0.message)).inserted
        }
    }

    private static func omissionKeys(_ warnings: [OperationWarning]) -> Set<OmissionKey> {
        Set(warnings.map { OmissionKey(code: $0.code, path: $0.path, message: $0.message) })
    }

    private static func add(_ value: Int64, to total: Int64) throws -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw EngineError.transport("Backup size exceeds the supported range") }
        return sum
    }

    private static func sum(_ values: [Int64]) throws -> Int64 {
        try values.reduce(0) { try add($1, to: $0) }
    }

    private static func prepareStagingDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw EngineError.repositoryIO("Temporary staging location is not a directory")
        }
        guard url.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else {
            throw EngineError.repositoryIO("Could not secure temporary staging location")
        }
    }

    private func emit(_ event: OperationEvent, for operation: OperationID) {
        guard var record = operationRecords[operation], !record.isFinished else { return }
        record.latestEvent = event
        for subscriber in record.subscribers.values { subscriber.yield(event) }
        operationRecords[operation] = record
    }

    private func finish(_ operation: OperationID) {
        guard var record = operationRecords[operation], !record.isFinished else { return }
        record.isFinished = true
        for subscriber in record.subscribers.values { subscriber.finish() }
        record.subscribers.removeAll()
        operationRecords[operation] = record
    }

    private func removeSubscriber(_ id: UUID, from operation: OperationID) {
        operationRecords[operation]?.subscribers.removeValue(forKey: id)
    }
}
