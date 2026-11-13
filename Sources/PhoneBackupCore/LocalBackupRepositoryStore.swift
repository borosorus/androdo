import CryptoKit
import Darwin
import Foundation
import SQLite3

/// A durable, device-bound repository catalog rooted in a folder selected by the user.
public actor LocalBackupRepositoryStore: BackupRepositoryWriting {
    private final class OpenRepository {
        let info: BackupRepositoryInfo
        let database: SQLiteDatabase
        let lockDescriptor: Int32
        let volumeIdentity: String

        init(info: BackupRepositoryInfo, database: SQLiteDatabase, lockDescriptor: Int32, volumeIdentity: String) {
            self.info = info
            self.database = database
            self.lockDescriptor = lockDescriptor
            self.volumeIdentity = volumeIdentity
        }

        deinit {
            _ = Darwin.close(lockDescriptor)
        }
    }

    private var open: [RepositoryID: OpenRepository] = [:]

    public init() {}

    public func repositories() async throws -> [BackupRepositoryInfo] {
        open.values.map(\.info).sorted { Array($0.displayName.utf8).lexicographicallyPrecedes(Array($1.displayName.utf8)) }
    }

    public func openRepositories(in location: URL) async throws -> [BackupRepositoryInfo] {
        let selectedRoot = try Self.validateSelectedFolder(location)
        let managedRoot = selectedRoot.appendingPathComponent("PhoneBackup", isDirectory: true)
        guard FileManager.default.fileExists(atPath: managedRoot.path) else { return [] }
        try Self.requireDirectory(managedRoot)

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: managedRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw Self.mapFilesystemError(error, location: managedRoot)
        }

        var found: [BackupRepositoryInfo] = []
        for child in children where child.lastPathComponent.hasPrefix("device-") {
            let metadataURL = child.appendingPathComponent("metadata.sqlite")
            guard FileManager.default.fileExists(atPath: metadataURL.path) else { continue }
            found.append(try openExistingRepository(at: child, selectedRoot: selectedRoot))
        }
        return found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func openOrCreateRepository(in location: URL, for device: AndroidDevice) async throws -> BackupRepositoryInfo {
        let selectedRoot = try Self.validateSelectedFolder(location)
        if let alreadyOpen = open.values.first(where: { $0.info.deviceID == device.id && $0.info.location.deletingLastPathComponent().deletingLastPathComponent() == selectedRoot }) {
            try ensureMounted(alreadyOpen)
            return alreadyOpen.info
        }
        let managedRoot = selectedRoot.appendingPathComponent("PhoneBackup", isDirectory: true)
        do {
            try Self.createPrivateDirectory(managedRoot)
            try Self.requireDirectory(managedRoot)
            try Self.syncDirectory(selectedRoot)
        } catch let error as EngineError {
            throw error
        } catch {
            throw Self.mapFilesystemError(error, location: managedRoot)
        }

        let serialHash = Self.sha256(Data(device.id.serial.utf8))
        let repositoryURL = managedRoot.appendingPathComponent("device-\(serialHash)", isDirectory: true)
        if FileManager.default.fileExists(atPath: repositoryURL.path) {
            let info = try openExistingRepository(at: repositoryURL, selectedRoot: selectedRoot)
            guard info.deviceID == device.id else { throw EngineError.repositoryDeviceMismatch(info.id) }
            return info
        }

        var createdRepository = false
        do {
            try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            createdRepository = true
            try Self.createPrivateDirectory(repositoryURL.appendingPathComponent("objects", isDirectory: true))
            try Self.createPrivateDirectory(repositoryURL.appendingPathComponent("objects/sha256", isDirectory: true))
            try Self.createPrivateDirectory(repositoryURL.appendingPathComponent("staging", isDirectory: true))
            return try createRepository(at: repositoryURL, selectedRoot: selectedRoot, device: device)
        } catch let error as EngineError {
            if createdRepository { try? FileManager.default.removeItem(at: repositoryURL) }
            throw error
        } catch {
            if createdRepository { try? FileManager.default.removeItem(at: repositoryURL) }
            throw Self.mapFilesystemError(error, location: repositoryURL)
        }
    }

    public func closeRepository(_ repository: RepositoryID) async throws {
        guard open.removeValue(forKey: repository) != nil else {
            throw EngineError.corruptedRepository("Repository is not open")
        }
    }

    public func restorePoints(in repository: RepositoryID) async throws -> [RestorePoint] {
        let handle = try requireOpen(repository)
        do {
            return try handle.database.rows(
                "SELECT id, created_at, state, selection, entry_count, total_bytes, omissions FROM restore_points ORDER BY created_at DESC, id DESC"
            ) { statement in
                guard let rawID = sqliteText(statement, 0), let uuid = UUID(uuidString: rawID),
                      let stateRaw = sqliteText(statement, 2), let state = RestorePointState(rawValue: stateRaw),
                      let selectionData = sqliteBlob(statement, 3), let omissionsData = sqliteBlob(statement, 6) else {
                    throw EngineError.corruptedRepository("Invalid restore point metadata")
                }
                let selection = try JSONDecoder().decode(BackupSelection.self, from: selectionData)
                let omissions = try JSONDecoder().decode([OperationWarning].self, from: omissionsData)
                return RestorePoint(
                    id: RestorePointID(uuid), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    state: state, selection: selection, entryCount: Int(sqlite3_column_int64(statement, 4)),
                    totalBytes: sqlite3_column_int64(statement, 5), omissions: omissions
                )
            }
        } catch {
            throw Self.mapRepositoryError(error, location: handle.info.location)
        }
    }

    public func entries(in repository: RepositoryID, point: RestorePointID, below path: RemotePath?) async throws -> [BackupEntry] {
        let handle = try requireOpen(repository)
        do {
            let bindings: [SQLiteValue]
            let sql: String
            if let path {
                sql = "SELECT path, kind, size, modified_at, content_hash FROM entries WHERE point_id = ? AND parent_path = ?"
                bindings = [.text(point.id.uuidString), .blob(Self.pathBytes(path))]
            } else {
                sql = "SELECT path, kind, size, modified_at, content_hash FROM entries WHERE point_id = ?"
                bindings = [.text(point.id.uuidString)]
            }
            return try handle.database.rows(sql, bindings: bindings) { statement in
                guard let pathData = sqliteBlob(statement, 0), let pathText = String(data: pathData, encoding: .utf8),
                      let entryPath = try? RemotePath(pathText),
                      let kindRaw = sqliteText(statement, 1), let kind = RemoteEntryKind(rawValue: kindRaw) else {
                    throw EngineError.corruptedRepository("Invalid restore point entry")
                }
                let modifiedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                return BackupEntry(
                    path: entryPath, kind: kind, size: sqlite3_column_int64(statement, 2), modifiedAt: modifiedAt,
                    contentHash: sqliteText(statement, 4)
                )
            }.sorted { RemotePath.bytewiseLess($0.path, $1.path) }
        } catch {
            throw Self.mapRepositoryError(error, location: handle.info.location)
        }
    }

    public func importFile(from localURL: URL, expectedSize: Int64, into repository: RepositoryID) async throws -> ContentObjectReference {
        let handle = try requireOpen(repository)
        guard expectedSize >= 0 else { throw EngineError.corruptedRepository("Negative source file size") }
        do {
            try ensureMounted(handle)
            let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw EngineError.repositoryIO("Content source must be a regular file")
            }
            if let size = values.fileSize, Int64(size) != expectedSize {
                throw EngineError.repositoryIO("Source file size did not match the expected size")
            }

            let staging = handle.info.location.appendingPathComponent("staging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased())
            let descriptor = staging.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR) }
            guard descriptor >= 0 else { throw Self.posixFailure(errno, location: staging) }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var keepStaging = true
            defer {
                try? output.close()
                if keepStaging { _ = staging.path.withCString { Darwin.unlink($0) } }
            }

            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            var hasher = SHA256()
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                copied += Int64(chunk.count)
                guard copied <= expectedSize else { throw EngineError.repositoryIO("Source file changed during import") }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard copied == expectedSize else { throw EngineError.repositoryIO("Source file changed during import") }
            try output.synchronize()
            try output.close()

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let reference = ContentObjectReference(sha256: digest, size: copied)
            let objectURL = objectURL(for: digest, repository: handle.info.location)
            try Self.requireDirectory(handle.info.location.appendingPathComponent("objects", isDirectory: true))
            try Self.requireDirectory(handle.info.location.appendingPathComponent("objects/sha256", isDirectory: true))
            try Self.createPrivateDirectory(objectURL.deletingLastPathComponent())
            try Self.requireDirectory(objectURL.deletingLastPathComponent())
            try ensureMounted(handle)
            let publishResult = staging.path.withCString { source in
                objectURL.path.withCString { destination in Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL)) }
            }
            if publishResult == 0 {
                keepStaging = false
                try Self.syncDirectory(objectURL.deletingLastPathComponent())
                try Self.syncDirectory(objectURL.deletingLastPathComponent().deletingLastPathComponent())
            } else if errno == EEXIST {
                try Self.verifyObject(at: objectURL, reference: reference)
                _ = staging.path.withCString { Darwin.unlink($0) }
                keepStaging = false
            } else {
                throw Self.posixFailure(errno, location: objectURL)
            }
            return reference
        } catch {
            throw Self.mapRepositoryError(error, location: handle.info.location)
        }
    }

    public func publish(_ manifest: RestorePointManifest, in repository: RepositoryID) async throws -> RestorePoint {
        let handle = try requireOpen(repository)
        do {
            try ensureMounted(handle)
            let totalBytes = try validate(manifest, repository: handle.info.location)
            let selectionData = try JSONEncoder().encode(manifest.selection)
            let omissionsData = try JSONEncoder().encode(manifest.omissions)
            let point = RestorePoint(
                id: manifest.id, createdAt: manifest.createdAt, state: .completed, selection: manifest.selection,
                entryCount: manifest.entries.count, totalBytes: totalBytes, omissions: manifest.omissions
            )

            try handle.database.transaction {
                try handle.database.execute(
                    "INSERT INTO restore_points(id, created_at, state, selection, entry_count, total_bytes, omissions) VALUES(?, ?, 'completed', ?, ?, ?, ?)",
                    bindings: [.text(manifest.id.id.uuidString), .real(manifest.createdAt.timeIntervalSince1970),
                               .blob(selectionData), .integer(Int64(manifest.entries.count)), .integer(totalBytes), .blob(omissionsData)]
                )
                for entry in manifest.entries {
                    if let hash = entry.contentHash {
                        try handle.database.execute(
                            "INSERT OR IGNORE INTO objects(sha256, size) VALUES(?, ?)",
                            bindings: [.text(hash), .integer(entry.size)]
                        )
                    }
                    let parent = entry.path.parent.map(Self.pathBytes) ?? Data()
                    try handle.database.execute(
                        "INSERT INTO entries(point_id, path, parent_path, kind, size, modified_at, content_hash) VALUES(?, ?, ?, ?, ?, ?, ?)",
                        bindings: [.text(manifest.id.id.uuidString), .blob(Self.pathBytes(entry.path)), .blob(parent),
                                   .text(entry.kind.rawValue), .integer(entry.size),
                                   entry.modifiedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                                   entry.contentHash.map(SQLiteValue.text) ?? .null]
                    )
                }
            }
            return point
        } catch {
            throw Self.mapRepositoryError(error, location: handle.info.location)
        }
    }

    public func verify(repository: RepositoryID, point: RestorePointID? = nil) async throws -> RepositoryIntegrityReport {
        let handle = try requireOpen(repository)
        do {
            try ensureMounted(handle)
            let pointIDs: [String] = try handle.database.rows(
                point.map { _ in "SELECT id FROM restore_points WHERE id = ?" } ?? "SELECT id FROM restore_points",
                bindings: point.map { [.text($0.id.uuidString)] } ?? []
            ) { statement in
                guard let id = sqliteText(statement, 0) else { throw EngineError.corruptedRepository("Invalid restore point id") }
                return id
            }
            if point != nil && pointIDs.isEmpty { throw EngineError.corruptedRepository("Unknown restore point") }
            var references: [String: Int64] = [:]
            for id in pointIDs {
                let rows: [(String, Int64)] = try handle.database.rows(
                    "SELECT content_hash, size FROM entries WHERE point_id = ? AND content_hash IS NOT NULL", bindings: [.text(id)]
                ) { statement in
                    guard let hash = sqliteText(statement, 0) else { throw EngineError.corruptedRepository("Invalid object hash") }
                    return (hash, sqlite3_column_int64(statement, 1))
                }
                for (hash, size) in rows {
                    if let oldSize = references[hash], oldSize != size { throw EngineError.corruptedRepository("Object size mismatch") }
                    references[hash] = size
                }
            }
            var totalBytes: Int64 = 0
            for (hash, size) in references {
                try Self.validateHash(hash)
                let object = objectURL(for: hash, repository: handle.info.location)
                try Self.verifyObject(at: object, reference: ContentObjectReference(sha256: hash, size: size))
                totalBytes += size
            }
            return RepositoryIntegrityReport(restorePointsChecked: pointIDs.count, objectsChecked: references.count, totalBytes: totalBytes)
        } catch {
            throw Self.mapRepositoryError(error, location: handle.info.location)
        }
    }

    private func createRepository(at url: URL, selectedRoot: URL, device: AndroidDevice) throws -> BackupRepositoryInfo {
        let lockDescriptor = try acquireLock(at: url)
        do {
            let metadataURL = url.appendingPathComponent("metadata.sqlite")
            let metadataDescriptor = metadataURL.path.withCString {
                Darwin.open($0, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard metadataDescriptor >= 0 else { throw Self.posixFailure(errno, location: metadataURL) }
            _ = Darwin.close(metadataDescriptor)
            let database = try SQLiteDatabase(path: metadataURL.path)
            guard metadataURL.path.withCString({ Darwin.chmod($0, S_IRUSR | S_IWUSR) }) == 0 else {
                throw Self.posixFailure(errno, location: metadataURL)
            }
            try Self.createSchema(database)
            let id = RepositoryID()
            let info = BackupRepositoryInfo(id: id, location: url, deviceID: device.id, displayName: device.model ?? device.id.serial)
            try database.execute(
                "INSERT INTO repository(id, device_serial, model, product, display_name) VALUES(?, ?, ?, ?, ?)",
                bindings: [.text(id.id.uuidString), .text(device.id.serial), device.model.map(SQLiteValue.text) ?? .null,
                           device.product.map(SQLiteValue.text) ?? .null, .text(info.displayName)]
            )
            try Self.syncDirectory(url)
            try Self.syncDirectory(url.deletingLastPathComponent())
            let handle = OpenRepository(info: info, database: database, lockDescriptor: lockDescriptor,
                                        volumeIdentity: try Self.volumeIdentity(selectedRoot))
            open[id] = handle
            return info
        } catch {
            _ = Darwin.close(lockDescriptor)
            throw Self.mapRepositoryError(error, location: url)
        }
    }

    private func openExistingRepository(at candidateURL: URL, selectedRoot: URL) throws -> BackupRepositoryInfo {
        let url = URL(fileURLWithPath: candidateURL.path, isDirectory: true).standardizedFileURL
        try Self.requireDirectory(url)
        if let alreadyOpen = open.values.first(where: { $0.info.location == url.standardizedFileURL }) {
            try ensureMounted(alreadyOpen)
            return alreadyOpen.info
        }
        let selectedRoot = try Self.validateSelectedFolder(selectedRoot)
        let lockDescriptor = try acquireLock(at: url)
        do {
            try Self.protectDirectory(url)
            try Self.protectDirectory(url.appendingPathComponent("objects", isDirectory: true))
            try Self.protectDirectory(url.appendingPathComponent("objects/sha256", isDirectory: true))
            try Self.protectDirectory(url.appendingPathComponent("staging", isDirectory: true))
            let metadataURL = url.appendingPathComponent("metadata.sqlite")
            var metadataInfo = stat()
            guard metadataURL.path.withCString({ Darwin.lstat($0, &metadataInfo) }) == 0,
                  (metadataInfo.st_mode & S_IFMT) == S_IFREG else {
                throw EngineError.corruptedRepository("Repository metadata is missing or not a regular file")
            }
            let database = try SQLiteDatabase(path: metadataURL.path)
            guard metadataURL.path.withCString({ Darwin.chmod($0, S_IRUSR | S_IWUSR) }) == 0 else {
                throw Self.posixFailure(errno, location: metadataURL)
            }
            try Self.validateSchema(database)
            let records: [(String, String, String)] = try database.rows(
                "SELECT id, device_serial, display_name FROM repository LIMIT 1"
            ) { statement in
                guard let id = sqliteText(statement, 0), let serial = sqliteText(statement, 1),
                      let name = sqliteText(statement, 2) else { throw EngineError.corruptedRepository("Missing repository identity") }
                return (id, serial, name)
            }
            guard let record = records.first, let uuid = UUID(uuidString: record.0) else {
                throw EngineError.corruptedRepository("Missing repository identity")
            }
            let deviceID = try DeviceID(serial: record.1)
            let info = BackupRepositoryInfo(id: RepositoryID(uuid), location: url, deviceID: deviceID, displayName: record.2)
            if let existingHandle = open[info.id], existingHandle.info.location != info.location {
                throw EngineError.repositoryBusy(info.location)
            }
            let handle = OpenRepository(info: info, database: database, lockDescriptor: lockDescriptor,
                                        volumeIdentity: try Self.volumeIdentity(selectedRoot))
            open[info.id] = handle
            return info
        } catch {
            _ = Darwin.close(lockDescriptor)
            throw Self.mapRepositoryError(error, location: url)
        }
    }

    private func validate(_ manifest: RestorePointManifest, repository: URL) throws -> Int64 {
        var seen = Set<RemotePath>()
        var total: Int64 = 0
        for entry in manifest.entries {
            guard entry.size >= 0, seen.insert(entry.path).inserted else {
                throw EngineError.corruptedRepository("Manifest contains a duplicate path or negative size")
            }
            switch entry.kind {
            case .directory:
                guard entry.contentHash == nil else { throw EngineError.corruptedRepository("Directory references file content") }
            case .file:
                guard let hash = entry.contentHash else { throw EngineError.corruptedRepository("File has no content hash") }
                try Self.validateHash(hash)
                let reference = ContentObjectReference(sha256: hash, size: entry.size)
                try Self.verifyObject(at: objectURL(for: hash, repository: repository), reference: reference)
                let (sum, overflow) = total.addingReportingOverflow(entry.size)
                guard !overflow else { throw EngineError.corruptedRepository("Manifest byte count overflow") }
                total = sum
            case .symbolicLink, .other:
                throw EngineError.corruptedRepository("Unsupported entry kind in restore point")
            }
        }
        return total
    }

    private func requireOpen(_ repository: RepositoryID) throws -> OpenRepository {
        guard let handle = open[repository] else { throw EngineError.corruptedRepository("Repository is not open") }
        try ensureMounted(handle)
        return handle
    }

    private func ensureMounted(_ handle: OpenRepository) throws {
        do {
            try Self.requireDirectory(handle.info.location)
            try Self.requireDirectory(handle.info.location.appendingPathComponent("objects", isDirectory: true))
            try Self.requireDirectory(handle.info.location.appendingPathComponent("objects/sha256", isDirectory: true))
            try Self.requireDirectory(handle.info.location.appendingPathComponent("staging", isDirectory: true))
            let selectedRoot = handle.info.location.deletingLastPathComponent().deletingLastPathComponent()
            guard try Self.volumeIdentity(selectedRoot) == handle.volumeIdentity else {
                throw EngineError.repositoryUnavailable(handle.info.location)
            }
        } catch let error as EngineError {
            if case .repositoryUnavailable = error { throw error }
            throw EngineError.repositoryUnavailable(handle.info.location)
        } catch {
            throw EngineError.repositoryUnavailable(handle.info.location)
        }
    }

    private func acquireLock(at repository: URL) throws -> Int32 {
        let url = repository.appendingPathComponent("repository.lock")
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw Self.posixFailure(errno, location: url) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let failure = errno
            _ = Darwin.close(descriptor)
            throw Self.posixFailure(failure, location: url)
        }
        return descriptor
    }

    private func objectURL(for hash: String, repository: URL) -> URL {
        let first = String(hash.prefix(2))
        let rest = String(hash.dropFirst(2))
        return repository.appendingPathComponent("objects/sha256/\(first)/\(rest)")
    }

    private static func createSchema(_ database: SQLiteDatabase) throws {
        let version = try schemaVersion(database)
        guard version == 0 else { throw EngineError.repositoryFormatUnsupported(version) }
        try database.transaction {
            try database.execute("CREATE TABLE repository(id TEXT PRIMARY KEY, device_serial TEXT NOT NULL, model TEXT, product TEXT, display_name TEXT NOT NULL)")
            try database.execute("CREATE TABLE objects(sha256 TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK(size >= 0))")
            try database.execute("CREATE TABLE restore_points(id TEXT PRIMARY KEY, created_at REAL NOT NULL, state TEXT NOT NULL CHECK(state = 'completed'), selection BLOB NOT NULL, entry_count INTEGER NOT NULL, total_bytes INTEGER NOT NULL, omissions BLOB NOT NULL)")
            try database.execute("CREATE TABLE entries(point_id TEXT NOT NULL REFERENCES restore_points(id), path BLOB NOT NULL, parent_path BLOB NOT NULL, kind TEXT NOT NULL, size INTEGER NOT NULL CHECK(size >= 0), modified_at REAL, content_hash TEXT REFERENCES objects(sha256), PRIMARY KEY(point_id, path))")
            try database.execute("CREATE INDEX entries_by_parent ON entries(point_id, parent_path)")
            try database.execute("CREATE TRIGGER immutable_restore_points_update BEFORE UPDATE ON restore_points BEGIN SELECT RAISE(ABORT, 'restore points are immutable'); END")
            try database.execute("CREATE TRIGGER immutable_restore_points_delete BEFORE DELETE ON restore_points BEGIN SELECT RAISE(ABORT, 'restore points are immutable'); END")
            try database.execute("CREATE TRIGGER immutable_entries_update BEFORE UPDATE ON entries BEGIN SELECT RAISE(ABORT, 'restore point entries are immutable'); END")
            try database.execute("CREATE TRIGGER immutable_entries_delete BEFORE DELETE ON entries BEGIN SELECT RAISE(ABORT, 'restore point entries are immutable'); END")
            try database.execute("PRAGMA user_version = 1")
        }
    }

    private static func validateSchema(_ database: SQLiteDatabase) throws {
        let version = try schemaVersion(database)
        guard version == 1 else { throw EngineError.repositoryFormatUnsupported(version) }
    }

    private static func schemaVersion(_ database: SQLiteDatabase) throws -> Int {
        try database.rows("PRAGMA user_version") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    private static func validateSelectedFolder(_ location: URL) throws -> URL {
        guard location.isFileURL else { throw EngineError.repositoryIO("Repository location must be a local folder") }
        try requireDirectory(location)
        return location.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { throw posixFailure(errno, location: url) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw EngineError.repositoryIO("Repository path is not a real directory: \(url.lastPathComponent)") }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try requireDirectory(url)
            guard url.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else {
                throw posixFailure(errno, location: url)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { try requireDirectory(url) }
            else { throw error }
        }
    }

    private static func protectDirectory(_ url: URL) throws {
        try requireDirectory(url)
        guard url.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else { throw posixFailure(errno, location: url) }
    }

    private static func volumeIdentity(_ url: URL) throws -> String {
        do {
            let identity = try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard let identity, !identity.isEmpty else { throw EngineError.repositoryUnavailable(url) }
            return identity
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.repositoryUnavailable(url)
        }
    }

    private static func pathBytes(_ path: RemotePath) -> Data { Data(path.description.utf8) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateHash(_ hash: String) throws {
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EngineError.corruptedRepository("Invalid SHA-256 object name")
        }
    }

    private static func verifyObject(at url: URL, reference: ContentObjectReference) throws {
        try validateHash(reference.sha256)
        var parentInfo = stat()
        guard url.deletingLastPathComponent().path.withCString({ Darwin.lstat($0, &parentInfo) }) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw EngineError.corruptedRepository("Missing or unsafe content object directory")
        }
        var fileInfo = stat()
        guard url.path.withCString({ Darwin.lstat($0, &fileInfo) }) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            throw EngineError.corruptedRepository("Missing or unsafe content object \(reference.sha256)")
        }
        let attrs: [FileAttributeKey: Any]
        do { attrs = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch { throw EngineError.corruptedRepository("Missing content object \(reference.sha256)") }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = attrs[.size] as? NSNumber, size.int64Value == reference.size else {
            throw EngineError.corruptedRepository("Invalid content object size or type")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == reference.sha256 else { throw EngineError.corruptedRepository("Content object hash mismatch") }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw posixFailure(errno, location: url) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw posixFailure(errno, location: url) }
    }

    private static func posixFailure(_ code: Int32, location: URL) -> EngineError {
        if code == ENOSPC || code == EDQUOT { return .insufficientSpace }
        if code == ENODEV || code == ENXIO || code == ESTALE || code == ENOENT || code == EROFS || code == EIO || code == ENOTCONN {
            return .repositoryUnavailable(location)
        }
        if code == EWOULDBLOCK || code == EAGAIN { return .repositoryBusy(location) }
        return .repositoryIO("\(location.lastPathComponent): \(String(cString: strerror(code)))")
    }

    private static func mapFilesystemError(_ error: Error, location: URL) -> EngineError {
        if let engine = error as? EngineError { return engine }
        if let nsError = error as NSError?, nsError.domain == NSPOSIXErrorDomain {
            return posixFailure(Int32(nsError.code), location: location)
        }
        return .repositoryIO(error.localizedDescription)
    }

    static func mapRepositoryError(_ error: Error, location: URL) -> EngineError {
        if let engine = error as? EngineError { return engine }
        if let sqlite = error as? SQLiteFailure {
            if sqlite.code == SQLITE_FULL { return .insufficientSpace }
            if sqlite.code == SQLITE_BUSY || sqlite.code == SQLITE_LOCKED { return .repositoryBusy(location) }
            if sqlite.code == SQLITE_IOERR || sqlite.code == SQLITE_CANTOPEN || sqlite.code == SQLITE_READONLY {
                return .repositoryUnavailable(location)
            }
            return .repositoryIO(sqlite.message)
        }
        return mapFilesystemError(error, location: location)
    }
}
