import Foundation

public protocol DeviceTransport: Sendable {
    func connectedDevices() async throws -> [AndroidDevice]
}

public protocol RemoteFileAccess: Sendable {
    func children(of path: RemotePath, on device: DeviceID) async throws -> [RemoteEntry]
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
    func publish(_ manifest: RestorePointManifest, in repository: RepositoryID) async throws -> RestorePoint
    func verify(repository: RepositoryID, point: RestorePointID?) async throws -> RepositoryIntegrityReport
}

public protocol OperationCoordinator: Sendable {
    func events(for operation: OperationID) async -> AsyncStream<OperationEvent>
    func cancel(_ operation: OperationID) async
}
