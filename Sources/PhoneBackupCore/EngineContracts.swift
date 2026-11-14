import Foundation

public protocol DeviceTransport: Sendable {
    func connectedDevices() async throws -> [AndroidDevice]
}

public protocol RemoteFileAccess: Sendable {
    func children(of path: RemotePath, on device: DeviceID) async throws -> [RemoteEntry]
    func metadata(of path: RemotePath, on device: DeviceID) async throws -> RemoteEntry
    func pull(from path: RemotePath, on device: DeviceID, to localURL: URL) async throws
    func push(from localURL: URL, to path: RemotePath, on device: DeviceID) async throws
}

public protocol BackupRepositoryStore: Sendable {
    func repositories() async throws -> [BackupRepositoryInfo]
    func restorePoints(in repository: RepositoryID) async throws -> [RestorePoint]
    func entries(in repository: RepositoryID, point: RestorePointID, below path: RemotePath?) async throws -> [BackupEntry]
}

public protocol BackupRepositoryWriting: BackupRepositoryStore {
    func openRepositories(in location: URL) async throws -> [BackupRepositoryInfo]
    func openOrCreateRepository(in location: URL, for device: AndroidDevice) async throws -> BackupRepositoryInfo
    func closeRepository(_ repository: RepositoryID) async throws
    func importFile(from localURL: URL, expectedSize: Int64, into repository: RepositoryID) async throws -> ContentObjectReference
    func verifyObject(_ reference: ContentObjectReference, in repository: RepositoryID) async throws
    func stageObject(_ reference: ContentObjectReference, in repository: RepositoryID) async throws -> URL
    func discardStagedObject(at url: URL, in repository: RepositoryID) async
    func backupAttempts(in repository: RepositoryID) async throws -> [BackupAttempt]
    func beginBackupAttempt(in repository: RepositoryID, device: DeviceID, selection: BackupSelection) async throws -> BackupAttempt
    func backupAttempt(_ attempt: BackupAttemptID, in repository: RepositoryID) async throws -> BackupAttempt
    func checkpoints(for attempt: BackupAttemptID, in repository: RepositoryID) async throws -> [BackupCheckpoint]
    func saveCheckpoint(_ checkpoint: BackupCheckpoint, for attempt: BackupAttemptID, in repository: RepositoryID) async throws
    func updateBackupAttempt(_ attempt: BackupAttemptID, in repository: RepositoryID, state: BackupAttemptState,
                            omissions: [OperationWarning]) async throws
    func publish(_ manifest: RestorePointManifest, in repository: RepositoryID) async throws -> RestorePoint
    func publish(_ manifest: RestorePointManifest, in repository: RepositoryID,
                 completing attempt: BackupAttemptID) async throws -> RestorePoint
    func verify(repository: RepositoryID, point: RestorePointID?) async throws -> RepositoryIntegrityReport
}

public protocol RemoteDestinationAccess: RemoteFileAccess {
    func inspectDestination(_ path: RemotePath, on device: DeviceID) async throws -> RemoteDestinationState
    func inspectDestinations(_ paths: [RemotePath], on device: DeviceID) async throws -> [RemotePath: RemoteDestinationState]
    func createDestinationDirectory(_ path: RemotePath, on device: DeviceID) async throws
    func publishStagedFile(from localURL: URL, to path: RemotePath, on device: DeviceID,
                           expected: ContentObjectReference, replacing identity: String?) async throws
}

extension RemoteDestinationAccess {
    public func inspectDestinations(_ paths: [RemotePath], on device: DeviceID) async throws -> [RemotePath: RemoteDestinationState] {
        var states: [RemotePath: RemoteDestinationState] = [:]
        for path in paths {
            try Task.checkCancellation()
            states[path] = try await inspectDestination(path, on: device)
        }
        return states
    }
}

public protocol OperationCoordinator: Sendable {
    func events(for operation: OperationID) async -> AsyncStream<OperationEvent>
    func cancel(_ operation: OperationID) async
}

public protocol BackupEngine: OperationCoordinator {
    func plan(repository: RepositoryID, device: DeviceID, selection: BackupSelection) async throws -> BackupPlan
    func startBackup(using plan: BackupPlanID, omissions: BackupOmissionChoice) async throws -> OperationID
    func resumeBackup(_ attempt: BackupAttemptID, omissions: BackupOmissionChoice) async throws -> OperationID
    func finishWithOmissions(_ attempt: BackupAttemptID) async throws -> OperationID
    func attempts(in repository: RepositoryID) async throws -> [BackupAttempt]
    func attemptID(for operation: OperationID) async -> BackupAttemptID?
}

public protocol RestoreEngine: OperationCoordinator {
    func planRestore(_ request: RestoreRequest) async throws -> RestorePlan
    func planRestore(_ request: RestoreRequest,
                     progress: @Sendable @escaping (RestorePlanningProgress) async -> Void) async throws -> RestorePlan
    func startRestore(_ plan: RestorePlanID, replacing conflicts: Set<UUID>) async throws -> OperationID
    func result(for operation: OperationID) async -> RestoreBatchResult?
}

extension RestoreEngine {
    public func planRestore(_ request: RestoreRequest,
                            progress: @Sendable @escaping (RestorePlanningProgress) async -> Void) async throws -> RestorePlan {
        try await planRestore(request)
    }
}

public protocol CopyEngine: OperationCoordinator {
    func planCopy(_ request: CopyRequest) async throws -> CopyPlan
    func startCopy(_ plan: CopyPlanID, replacing conflicts: Set<UUID>) async throws -> OperationID
    func result(for operation: OperationID) async -> CopyBatchResult?
}
