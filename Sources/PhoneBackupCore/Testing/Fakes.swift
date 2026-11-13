import Foundation

public actor FakeDeviceTransport: DeviceTransport, RemoteFileAccess {
    private var devices: [AndroidDevice]
    private var entries: [DeviceID: [RemoteEntry]] = [:]
    private var fileData: [DeviceID: [RemotePath: Data]] = [:]

    public init(devices: [AndroidDevice] = []) {
        self.devices = devices
    }

    public func setDevices(_ devices: [AndroidDevice]) {
        self.devices = devices
    }

    public func seed(_ entry: RemoteEntry, on device: DeviceID, data: Data? = nil) {
        entries[device, default: []].removeAll { $0.path == entry.path }
        entries[device, default: []].append(entry)
        entries[device, default: []].sort { RemotePath.bytewiseLess($0.path, $1.path) }
        if let data { fileData[device, default: [:]][entry.path] = data }
    }

    public func connectedDevices() async throws -> [AndroidDevice] {
        devices
    }

    public func children(of path: RemotePath, on device: DeviceID) async throws -> [RemoteEntry] {
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        return entries[device, default: []]
            .filter { $0.path.parent == path }
            .sorted { RemotePath.bytewiseLess($0.path, $1.path) }
    }

    public func pull(from path: RemotePath, on device: DeviceID, to localURL: URL) async throws {
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        guard let data = fileData[device]?[path] else { throw EngineError.inaccessiblePath(path) }
        try data.write(to: localURL, options: .atomic)
    }

    public func push(from localURL: URL, to path: RemotePath, on device: DeviceID) async throws {
        guard devices.contains(where: { $0.id == device && $0.state == .device }) else {
            throw EngineError.deviceUnavailable(device)
        }
        let data = try Data(contentsOf: localURL)
        fileData[device, default: [:]][path] = data
        let entry = RemoteEntry(path: path, kind: .file, size: Int64(data.count))
        entries[device, default: []].removeAll { $0.path == path }
        entries[device, default: []].append(entry)
    }
}

public actor FakeBackupRepositoryStore: BackupRepositoryStore {
    private var stored: [RepositoryID: (BackupRepositoryInfo, [RestorePoint], [RestorePointID: [BackupEntry]])] = [:]

    public init() {}

    public func seed(
        repository: BackupRepositoryInfo,
        restorePoints: [RestorePoint] = [],
        entries: [RestorePointID: [BackupEntry]] = [:]
    ) {
        stored[repository.id] = (repository, restorePoints, entries)
    }

    public func repositories() async throws -> [BackupRepositoryInfo] {
        stored.values.map(\.0).sorted { $0.displayName < $1.displayName }
    }

    public func restorePoints(in repository: RepositoryID) async throws -> [RestorePoint] {
        guard let value = stored[repository] else { throw EngineError.corruptedRepository("Unknown repository") }
        return value.1.sorted { $0.createdAt > $1.createdAt }
    }

    public func entries(in repository: RepositoryID, point: RestorePointID, below path: RemotePath?) async throws -> [BackupEntry] {
        guard let value = stored[repository], let entries = value.2[point] else {
            throw EngineError.corruptedRepository("Unknown restore point")
        }
        guard let path else { return entries.sorted { $0.path.description < $1.path.description } }
        return entries
            .filter { $0.path.parent == path }
            .sorted { RemotePath.bytewiseLess($0.path, $1.path) }
    }
}
