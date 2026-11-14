import Foundation
import CryptoKit

public enum FakeDeviceOperation: Hashable, Sendable {
    case children
    case metadata
    case pull
}

private struct FakeDeviceFailureKey: Hashable {
    let operation: FakeDeviceOperation
    let path: RemotePath
}

private struct FakePullMutation {
    let path: RemotePath
    let entry: RemoteEntry
    let data: Data
}

public actor FakeDeviceTransport: DeviceTransport, RemoteDestinationAccess {
    public struct Publication: Sendable {
        public let path: RemotePath
        public let replacing: String?
    }
    private var devices: [AndroidDevice]
    private var entries: [DeviceID: [RemoteEntry]] = [:]
    private var fileData: [DeviceID: [RemotePath: Data]] = [:]
    private var directories: [DeviceID: Set<RemotePath>] = [:]
    private var failures: [FakeDeviceFailureKey: [EngineError]] = [:]
    private var mutationsAfterPull: [DeviceID: [FakePullMutation]] = [:]
    private var publishUnverifiedPaths: Set<RemotePath> = []
    private var publicationFailuresWithoutEngineError: Set<RemotePath> = []
    private var pullCalls: [DeviceID: [RemotePath]] = [:]
    private var childrenCalls: [DeviceID: [RemotePath]] = [:]
    private var destinationBatches: [[RemotePath]] = []
    private var publications: [Publication] = []
    private var supportsNoOverwritePublication = true

    public init(devices: [AndroidDevice] = []) {
        self.devices = devices
    }

    public func setDevices(_ devices: [AndroidDevice]) {
        self.devices = devices
    }

    public func seed(_ entry: RemoteEntry, on device: DeviceID, data: Data? = nil) {
        entries[device, default: []].removeAll { $0.path == entry.path }
        entries[device, default: []].append(entry)
        if entry.kind == .directory { directories[device, default: []].insert(entry.path) }
        var parent = entry.path.parent
        while let value = parent {
            directories[device, default: []].insert(value)
            if !entries[device, default: []].contains(where: { $0.path == value }) {
                entries[device, default: []].append(RemoteEntry(path: value, kind: .directory, size: nil))
            }
            parent = value.parent
        }
        entries[device, default: []].sort { RemotePath.bytewiseLess($0.path, $1.path) }
        if let data { fileData[device, default: [:]][entry.path] = data }
    }

    public func remove(_ path: RemotePath, on device: DeviceID) {
        entries[device, default: []].removeAll { $0.path.isEqualOrDescendant(of: path) }
        fileData[device, default: [:]].keys.filter { $0.isEqualOrDescendant(of: path) }.forEach {
            fileData[device, default: [:]].removeValue(forKey: $0)
        }
        directories[device, default: []].subtract(directories[device, default: []].filter { $0.isEqualOrDescendant(of: path) })
    }

    public func failNext(_ error: EngineError, operation: FakeDeviceOperation, at path: RemotePath, on device: DeviceID) {
        failures[FakeDeviceFailureKey(operation: operation, path: path), default: []].append(error)
    }

    public func mutateAfterNextPull(_ entry: RemoteEntry, data: Data, on device: DeviceID) {
        mutationsAfterPull[device, default: []].append(FakePullMutation(path: entry.path, entry: entry, data: data))
    }

    public func reportNextPublicationUnverified(at path: RemotePath) {
        publishUnverifiedPaths.insert(path)
    }

    public func failNextPublicationWithoutEngineError(at path: RemotePath) {
        publicationFailuresWithoutEngineError.insert(path)
    }

    public func recordedPulls(on device: DeviceID) -> [RemotePath] { pullCalls[device, default: []] }
    public func recordedChildrenCalls(on device: DeviceID) -> [RemotePath] { childrenCalls[device, default: []] }
    public func recordedDestinationBatches() -> [[RemotePath]] { destinationBatches }
    public func recordedPublications() -> [Publication] { publications }
    public func setSupportsNoOverwritePublication(_ supported: Bool) { supportsNoOverwritePublication = supported }

    public func connectedDevices() async throws -> DeviceDiscoveryResult {
        DeviceDiscoveryResult(devices: devices)
    }

    public func children(of path: RemotePath, on session: DeviceSession) async throws -> [RemoteEntry] {
        let device = session.deviceID
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        try throwNextFailure(.children, path: path)
        childrenCalls[device, default: []].append(path)
        guard path == .root || directories[device, default: []].contains(path) else { throw EngineError.missingPath(path) }
        return entries[device, default: []]
            .filter { $0.path.parent == path }
            .sorted { RemotePath.bytewiseLess($0.path, $1.path) }
    }

    public func metadata(of path: RemotePath, on session: DeviceSession) async throws -> RemoteEntry {
        let device = session.deviceID
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        try throwNextFailure(.metadata, path: path)
        guard let entry = entries[device, default: []].first(where: { $0.path == path }) else {
            throw EngineError.missingPath(path)
        }
        return entry
    }

    public func inspectDestinations(_ paths: [RemotePath], on session: DeviceSession) async throws -> [RemotePath: RemoteDestinationState] {
        destinationBatches.append(paths)
        var states: [RemotePath: RemoteDestinationState] = [:]
        for path in paths { states[path] = try await inspectDestination(path, on: session) }
        return states
    }

    public func inspectDestination(_ path: RemotePath, on session: DeviceSession) async throws -> RemoteDestinationState {
        let device = session.deviceID
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        guard let entry = entries[device, default: []].first(where: { $0.path == path }) else { return .missing }
        let identity = "\(entry.kind.rawValue):\(entry.size ?? -1):\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)"
        switch entry.kind {
        case .file: return .regularFile(identity: identity, size: entry.size ?? 0)
        case .directory: return .directory(identity: identity)
        case .symbolicLink: return .symbolicLink(identity: identity)
        case .other: return .other(identity: identity)
        }
    }

    public func createDestinationDirectory(_ path: RemotePath, on session: DeviceSession) async throws {
        let device = session.deviceID
        if case .directory = try await inspectDestination(path, on: session) { return }
        guard case .missing = try await inspectDestination(path, on: session) else {
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .directoryExists))
        }
        seed(RemoteEntry(path: path, kind: .directory), on: device)
    }

    public func publishStagedFile(from localURL: URL, to path: RemotePath, on session: DeviceSession,
                                  expected: ContentObjectReference, replacing identity: String?) async throws {
        let device = session.deviceID
        let state = try await inspectDestination(path, on: session)
        switch state {
        case .missing:
            guard identity == nil || identity == RestoreConflict.approvedMissingTargetIdentity else {
                throw EngineError.sourceChanged(path)
            }
        case .regularFile(let actual, _):
            guard identity == actual else {
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .fileExists))
            }
        case .directory:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .directoryExists))
        case .symbolicLink, .other:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
        }
        publications.append(Publication(path: path, replacing: identity))
        if identity == nil, !supportsNoOverwritePublication { throw EngineError.safeNoOverwriteUnavailable(path) }
        let data = try Data(contentsOf: localURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard Int64(data.count) == expected.size, digest == expected.sha256 else {
            throw EngineError.corruptedRepository("Fake remote publication verification failed")
        }
        if publicationFailuresWithoutEngineError.remove(path) != nil {
            throw NSError(domain: "FakeDeviceTransport", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: "Simulated local publication error"])
        }
        let date = Date()
        seed(RemoteEntry(path: path, kind: .file, size: Int64(data.count), modifiedAt: date), on: device, data: data)
        if publishUnverifiedPaths.remove(path) != nil {
            throw EngineError.destinationPublishedUnverified(path.description, "Simulated final verification failure")
        }
    }

    public func pull(from path: RemotePath, on session: DeviceSession, to localURL: URL) async throws {
        let device = session.deviceID
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        try throwNextFailure(.pull, path: path)
        guard let data = fileData[device]?[path] else { throw EngineError.inaccessiblePath(path) }
        pullCalls[device, default: []].append(path)
        try data.write(to: localURL, options: .atomic)
        if let index = mutationsAfterPull[device]?.firstIndex(where: { $0.path == path }) {
            let mutation = mutationsAfterPull[device]!.remove(at: index)
            seed(mutation.entry, on: device, data: mutation.data)
        }
    }

    public func push(from localURL: URL, to path: RemotePath, on session: DeviceSession) async throws {
        let device = session.deviceID
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        let data = try Data(contentsOf: localURL)
        fileData[device, default: [:]][path] = data
        let entry = RemoteEntry(path: path, kind: .file, size: Int64(data.count))
        entries[device, default: []].removeAll { $0.path == path }
        entries[device, default: []].append(entry)
    }

    private func throwNextFailure(_ operation: FakeDeviceOperation, path: RemotePath) throws {
        let key = FakeDeviceFailureKey(operation: operation, path: path)
        guard var values = failures[key], !values.isEmpty else { return }
        let error = values.removeFirst()
        failures[key] = values
        throw error
    }
}

public actor FakeBackupRepositoryStore: BackupRepositoryWriting {
    private struct StoredAttempt {
        var metadata: BackupAttempt
        var checkpoints: [RemotePath: BackupCheckpoint]
    }

    private var stored: [RepositoryID: (BackupRepositoryInfo, [RestorePoint], [RestorePointID: [BackupEntry]])] = [:]
    private var objects: [RepositoryID: [String: Data]] = [:]
    private var attempts: [BackupAttemptID: StoredAttempt] = [:]
    private var stagingDelayForTesting: Duration?
    private var failNextOpenForTesting = false
    private var pausedRestoreReads: Set<RepositoryID> = []
    private var restoreReadGates: [RepositoryID: [CheckedContinuation<Void, Never>]] = [:]
    private var restoreReadWaiters: [RepositoryID: [CheckedContinuation<Void, Never>]] = [:]
    private var failingRestoreReads: Set<RepositoryID> = []
    private var pausedEntryReads: Set<RestorePointID> = []
    private var entryReadGates: [RestorePointID: [CheckedContinuation<Void, Never>]] = [:]
    private var entryReadWaiters: [RestorePointID: [CheckedContinuation<Void, Never>]] = [:]
    private var failingEntryReads: Set<RestorePointID> = []

    public init() {}

    public func delayStagingForTesting(_ duration: Duration?) {
        stagingDelayForTesting = duration
    }

    public func pauseEntryReadsForTesting(point: RestorePointID) { pausedEntryReads.insert(point) }
    public func waitForPausedEntryRead(point: RestorePointID) async {
        if !(entryReadGates[point] ?? []).isEmpty { return }
        await withCheckedContinuation { entryReadWaiters[point, default: []].append($0) }
    }
    public func resumeEntryReadsForTesting(point: RestorePointID, failing: Bool = false) {
        pausedEntryReads.remove(point)
        if failing { failingEntryReads.insert(point) }
        (entryReadGates.removeValue(forKey: point) ?? []).forEach { $0.resume() }
    }
    public func failNextEntryReadForTesting(point: RestorePointID) { failingEntryReads.insert(point) }

    public func failNextRepositoryOpenForTesting() { failNextOpenForTesting = true }

    public func pauseRestorePointReadsForTesting(in repository: RepositoryID) {
        pausedRestoreReads.insert(repository)
    }

    public func waitForPausedRestorePointRead(in repository: RepositoryID) async {
        if !(restoreReadGates[repository] ?? []).isEmpty { return }
        await withCheckedContinuation { restoreReadWaiters[repository, default: []].append($0) }
    }

    public func resumeRestorePointReadsForTesting(in repository: RepositoryID, failing: Bool = false) {
        pausedRestoreReads.remove(repository)
        if failing { failingRestoreReads.insert(repository) }
        let gates = restoreReadGates.removeValue(forKey: repository) ?? []
        gates.forEach { $0.resume() }
    }

    public func failNextRestorePointReadForTesting(in repository: RepositoryID) {
        failingRestoreReads.insert(repository)
    }

    public func seed(
        repository: BackupRepositoryInfo,
        restorePoints: [RestorePoint] = [],
        entries: [RestorePointID: [BackupEntry]] = [:]
    ) {
        stored[repository.id] = (repository, restorePoints, entries)
    }

    public func openRepositories(in location: URL) async throws -> [BackupRepositoryInfo] {
        if failNextOpenForTesting {
            failNextOpenForTesting = false
            throw EngineError.corruptedRepository("Fixture discovery failure")
        }
        let root = location.standardizedFileURL
        return stored.values.map(\.0).filter {
            $0.location.deletingLastPathComponent().deletingLastPathComponent() == root
        }
    }

    public func openOrCreateRepository(in location: URL, for device: AndroidDevice) async throws -> BackupRepositoryInfo {
        let root = location.standardizedFileURL
        if let existing = stored.values.map(\.0).first(where: {
            $0.deviceID == device.id && $0.location.deletingLastPathComponent().deletingLastPathComponent() == root
        }) { return existing }
        let repositoryPath = root.appendingPathComponent("PhoneBackup/device-\(device.id.value)", isDirectory: true)
        let repository = BackupRepositoryInfo(location: repositoryPath, deviceID: device.id,
                                              displayName: device.model ?? "Android device")
        seed(repository: repository)
        return repository
    }

    public func closeRepository(_ repository: RepositoryID) async throws {}

    public func verifyObject(_ reference: ContentObjectReference, in repository: RepositoryID) async throws {
        guard let data = objects[repository]?[reference.sha256], Int64(data.count) == reference.size,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == reference.sha256 else {
            throw EngineError.corruptedRepository("Content object verification failed")
        }
    }

    public func stageObject(_ reference: ContentObjectReference, in repository: RepositoryID) async throws -> URL {
        if let stagingDelayForTesting { try await Task.sleep(for: stagingDelayForTesting) }
        try await verifyObject(reference, in: repository)
        guard let data = objects[repository]?[reference.sha256] else {
            throw EngineError.corruptedRepository("Missing content object")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-backup-stage-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    public func discardStagedObject(at url: URL, in repository: RepositoryID) async {
        guard url.lastPathComponent.hasPrefix("phone-backup-stage-") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func backupAttempts(in repository: RepositoryID) async throws -> [BackupAttempt] {
        attempts.values.map(\.metadata).filter { $0.repository == repository }.sorted { $0.startedAt > $1.startedAt }
    }

    public func beginBackupAttempt(in repository: RepositoryID, device: DeviceID, selection: BackupSelection) async throws -> BackupAttempt {
        guard let value = stored[repository], value.0.deviceID == device else {
            throw EngineError.repositoryDeviceMismatch(repository)
        }
        let attempt = BackupAttempt(id: BackupAttemptID(), repository: repository, device: device, selection: selection,
                                   startedAt: Date(), state: .running, omissions: [], checkpointCount: 0)
        attempts[attempt.id] = StoredAttempt(metadata: attempt, checkpoints: [:])
        return attempt
    }

    public func backupAttempt(_ attempt: BackupAttemptID, in repository: RepositoryID) async throws -> BackupAttempt {
        guard let value = attempts[attempt], value.metadata.repository == repository else {
            throw EngineError.corruptedRepository("Unknown backup attempt")
        }
        return value.metadata
    }

    public func checkpoints(for attempt: BackupAttemptID, in repository: RepositoryID) async throws -> [BackupCheckpoint] {
        guard let value = attempts[attempt], value.metadata.repository == repository else {
            throw EngineError.corruptedRepository("Unknown backup attempt")
        }
        return value.checkpoints.values.sorted { RemotePath.bytewiseLess($0.path, $1.path) }
    }

    public func saveCheckpoint(_ checkpoint: BackupCheckpoint, for attempt: BackupAttemptID, in repository: RepositoryID) async throws {
        try await verifyObject(ContentObjectReference(sha256: checkpoint.contentHash, size: checkpoint.size), in: repository)
        guard var value = attempts[attempt], value.metadata.repository == repository else {
            throw EngineError.corruptedRepository("Unknown backup attempt")
        }
        value.checkpoints[checkpoint.path] = checkpoint
        value.metadata = BackupAttempt(id: value.metadata.id, repository: repository, device: value.metadata.device,
                                       selection: value.metadata.selection, startedAt: value.metadata.startedAt,
                                       state: value.metadata.state, omissions: value.metadata.omissions,
                                       checkpointCount: value.checkpoints.count)
        attempts[attempt] = value
    }

    public func updateBackupAttempt(_ attempt: BackupAttemptID, in repository: RepositoryID,
                                    state: BackupAttemptState, omissions: [OperationWarning]) async throws {
        guard var value = attempts[attempt], value.metadata.repository == repository else {
            throw EngineError.corruptedRepository("Unknown backup attempt")
        }
        value.metadata = BackupAttempt(id: value.metadata.id, repository: repository, device: value.metadata.device,
                                       selection: value.metadata.selection, startedAt: value.metadata.startedAt,
                                       state: state, omissions: omissions, checkpointCount: value.checkpoints.count)
        attempts[attempt] = value
    }

    public func importFile(from localURL: URL, expectedSize: Int64, into repository: RepositoryID) async throws -> ContentObjectReference {
        guard stored[repository] != nil else { throw EngineError.corruptedRepository("Unknown repository") }
        let data = try Data(contentsOf: localURL)
        guard Int64(data.count) == expectedSize else { throw EngineError.repositoryIO("Source file size did not match the expected size") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        objects[repository, default: [:]][hash] = data
        return ContentObjectReference(sha256: hash, size: Int64(data.count))
    }

    public func removeObjectForTesting(_ reference: ContentObjectReference, in repository: RepositoryID) {
        objects[repository]?.removeValue(forKey: reference.sha256)
    }

    public func publish(_ manifest: RestorePointManifest, in repository: RepositoryID) async throws -> RestorePoint {
        guard var value = stored[repository] else { throw EngineError.corruptedRepository("Unknown repository") }
        let paths = manifest.entries.map(\.path)
        guard Set(paths).count == paths.count else { throw EngineError.corruptedRepository("Duplicate manifest path") }
        for entry in manifest.entries where entry.kind == .file {
            guard let hash = entry.contentHash, let bytes = objects[repository]?[hash], Int64(bytes.count) == entry.size else {
                throw EngineError.corruptedRepository("Manifest references unavailable content")
            }
        }
        let point = RestorePoint(id: manifest.id, createdAt: manifest.createdAt, state: .completed,
                                 selection: manifest.selection, entryCount: manifest.entries.count,
                                 totalBytes: manifest.entries.filter { $0.kind == .file }.reduce(0) { $0 + $1.size },
                                 omissions: manifest.omissions)
        value.1.append(point)
        value.2[point.id] = manifest.entries
        stored[repository] = value
        return point
    }

    public func publish(_ manifest: RestorePointManifest, in repository: RepositoryID,
                        completing attempt: BackupAttemptID) async throws -> RestorePoint {
        guard let storedAttempt = attempts[attempt], storedAttempt.metadata.repository == repository,
              storedAttempt.metadata.selection == manifest.selection,
              storedAttempt.metadata.omissions == manifest.omissions else {
            throw EngineError.corruptedRepository("Attempt does not match restore point")
        }
        let point = try await publish(manifest, in: repository)
        attempts.removeValue(forKey: attempt)
        return point
    }

    public func verify(repository: RepositoryID, point: RestorePointID?) async throws -> RepositoryIntegrityReport {
        guard let value = stored[repository] else { throw EngineError.corruptedRepository("Unknown repository") }
        let points = point.map { id in value.1.filter { $0.id == id } } ?? value.1
        guard point == nil || points.count == 1 else { throw EngineError.corruptedRepository("Unknown restore point") }
        let hashes = Set(points.flatMap { value.2[$0.id] ?? [] }.compactMap(\.contentHash))
        var total: Int64 = 0
        for hash in hashes {
            guard let data = objects[repository]?[hash], SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw EngineError.corruptedRepository("Content object verification failed")
            }
            total += Int64(data.count)
        }
        return RepositoryIntegrityReport(restorePointsChecked: points.count, objectsChecked: hashes.count, totalBytes: total)
    }

    public func repositories() async throws -> [BackupRepositoryInfo] {
        stored.values.map(\.0).sorted { $0.displayName < $1.displayName }
    }

    public func restorePoints(in repository: RepositoryID) async throws -> [RestorePoint] {
        guard let value = stored[repository] else { throw EngineError.corruptedRepository("Unknown repository") }
        if pausedRestoreReads.contains(repository) {
            await withCheckedContinuation { continuation in
                restoreReadGates[repository, default: []].append(continuation)
                let waiters = restoreReadWaiters.removeValue(forKey: repository) ?? []
                waiters.forEach { $0.resume() }
            }
        }
        if failingRestoreReads.remove(repository) != nil { throw EngineError.corruptedRepository("Fixture read failure") }
        return value.1.sorted { $0.createdAt > $1.createdAt }
    }

    public func entries(in repository: RepositoryID, point: RestorePointID, below path: RemotePath?) async throws -> [BackupEntry] {
        guard let value = stored[repository], let entries = value.2[point] else {
            throw EngineError.corruptedRepository("Unknown restore point")
        }
        if pausedEntryReads.contains(point) {
            await withCheckedContinuation { continuation in
                entryReadGates[point, default: []].append(continuation)
                (entryReadWaiters.removeValue(forKey: point) ?? []).forEach { $0.resume() }
            }
        }
        if failingEntryReads.remove(point) != nil { throw EngineError.corruptedRepository("Fixture saved-file read failed") }
        guard let path else { return entries.sorted { $0.path.description < $1.path.description } }
        return entries
            .filter { $0.path.parent == path }
            .sorted { RemotePath.bytewiseLess($0.path, $1.path) }
    }
}
