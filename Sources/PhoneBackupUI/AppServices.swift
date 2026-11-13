import Foundation
import PhoneBackupCore

public struct AppServices {
    public let repositoryStore: any BackupRepositoryWriting
    public let restoreEngine: any RestoreEngine
    public let deviceTransport: (any DeviceTransport)?
    public let remoteAccess: (any RemoteFileAccess)?
    public let backupEngine: (any BackupEngine)?
    public let adbExecutable: URL?

    public init(repositoryStore: any BackupRepositoryWriting,
                deviceTransport: (any DeviceTransport)? = nil,
                remoteAccess: (any RemoteFileAccess)? = nil,
                backupEngine: (any BackupEngine)? = nil,
                restoreEngine: (any RestoreEngine)? = nil,
                adbExecutable: URL? = nil) {
        self.repositoryStore = repositoryStore
        self.deviceTransport = deviceTransport
        self.remoteAccess = remoteAccess
        self.backupEngine = backupEngine
        self.restoreEngine = restoreEngine ?? DefaultRestoreEngine(repositoryStore: repositoryStore)
        self.adbExecutable = adbExecutable
    }

    public static func live(adbExecutable explicitADB: URL? = nil,
                            repositoryStore: (any BackupRepositoryWriting)? = nil) -> AppServices {
        let store = repositoryStore ?? LocalBackupRepositoryStore()
        let adbURL = explicitADB ?? ADBExecutableResolver.resolve()
        guard let adbURL,
              let configuration = try? ADBConfiguration(executable: adbURL) else {
            return AppServices(repositoryStore: store)
        }
        let transport = ADBTransport(configuration: configuration)
        let backup = DefaultBackupEngine(remote: transport, repositoryStore: store)
        return AppServices(repositoryStore: store, deviceTransport: transport, remoteAccess: transport,
                           backupEngine: backup, adbExecutable: adbURL)
    }

    public func usingADB(at executable: URL) -> AppServices {
        Self.live(adbExecutable: executable, repositoryStore: repositoryStore)
    }
}
