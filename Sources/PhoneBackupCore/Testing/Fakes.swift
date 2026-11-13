import Foundation
import CryptoKit

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

public actor FakeBackupRepositoryStore: BackupRepositoryWriting {
    private var stored: [RepositoryID: (BackupRepositoryInfo, [RestorePoint], [RestorePointID: [BackupEntry]])] = [:]
    private var objects: [RepositoryID: [String: Data]] = [:]

    public init() {}

    public func seed(
        repository: BackupRepositoryInfo,
        restorePoints: [RestorePoint] = [],
        entries: [RestorePointID: [BackupEntry]] = [:]
    ) {
        stored[repository.id] = (repository, restorePoints, entries)
    }

    public func openRepositories(in location: URL) async throws -> [BackupRepositoryInfo] {
        stored.values.map(\.0).filter { $0.location.deletingLastPathComponent() == location.standardizedFileURL }
    }

    public func openOrCreateRepository(in location: URL, for device: AndroidDevice) async throws -> BackupRepositoryInfo {
        if let existing = stored.values.map(\.0).first(where: { $0.deviceID == device.id }) { return existing }
        let repository = BackupRepositoryInfo(location: location.standardizedFileURL, deviceID: device.id,
                                              displayName: device.model ?? device.id.serial)
        seed(repository: repository)
        return repository
    }

    public func closeRepository(_ repository: RepositoryID) async throws {}

    public func importFile(from localURL: URL, expectedSize: Int64, into repository: RepositoryID) async throws -> ContentObjectReference {
        guard stored[repository] != nil else { throw EngineError.corruptedRepository("Unknown repository") }
        let data = try Data(contentsOf: localURL)
        guard Int64(data.count) == expectedSize else { throw EngineError.repositoryIO("Source file size did not match the expected size") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        objects[repository, default: [:]][hash] = data
        return ContentObjectReference(sha256: hash, size: Int64(data.count))
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
