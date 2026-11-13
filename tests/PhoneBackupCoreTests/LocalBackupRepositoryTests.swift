import Foundation
import SQLite3
import XCTest
@testable import PhoneBackupCore

final class LocalBackupRepositoryTests: XCTestCase {
    func testCreatesReopensAndBrowsesImmutableRestorePoints() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try testDevice("pixel-1")
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: root, for: device)
        let openedRepositories = try await store.repositories()
        XCTAssertEqual(openedRepositories, [repository])
        XCTAssertFalse(repository.location.path.contains(device.id.serial))

        let unicodeFolder = try RemotePath("/sdcard/Images\nfrom phone")
        let firstFile = try unicodeFolder.appending("é.jpg")
        let normalizedAlias = try unicodeFolder.appending("e\u{301}.jpg")
        let unchangedFile = try unicodeFolder.appending("other.jpg")
        let removedLater = try unicodeFolder.appending("empty.bin")
        let firstBytes = Data("same bytes".utf8)
        let firstObject = try await store.importFile(from: try write(firstBytes, under: root), expectedSize: Int64(firstBytes.count), into: repository.id)
        let emptyObject = try await store.importFile(from: try write(Data(), under: root), expectedSize: 0, into: repository.id)
        let duplicateObject = try await store.importFile(from: try write(firstBytes, under: root), expectedSize: Int64(firstBytes.count), into: repository.id)
        XCTAssertEqual(firstObject, duplicateObject)

        let firstManifest = RestorePointManifest(
            createdAt: Date(timeIntervalSince1970: 100),
            selection: BackupSelection(scope: .selected([unicodeFolder])),
            entries: [
                BackupEntry(path: unicodeFolder, kind: .directory, size: 0, modifiedAt: nil, contentHash: nil),
                BackupEntry(path: firstFile, kind: .file, size: firstObject.size, modifiedAt: Date(timeIntervalSince1970: 90), contentHash: firstObject.sha256),
                BackupEntry(path: normalizedAlias, kind: .file, size: firstObject.size, modifiedAt: nil, contentHash: firstObject.sha256),
                BackupEntry(path: unchangedFile, kind: .file, size: firstObject.size, modifiedAt: nil, contentHash: firstObject.sha256),
                BackupEntry(path: removedLater, kind: .file, size: emptyObject.size, modifiedAt: nil, contentHash: emptyObject.sha256),
            ]
        )
        let firstPoint = try await store.publish(firstManifest, in: repository.id)
        XCTAssertEqual(firstPoint.entryCount, 5)
        XCTAssertEqual(firstPoint.totalBytes, Int64(firstBytes.count * 3))
        XCTAssertEqual(firstPoint.selection, firstManifest.selection)
        let firstEntries = try await store.entries(in: repository.id, point: firstPoint.id, below: unicodeFolder)
        XCTAssertEqual(firstEntries.map(\.path), [firstFile, normalizedAlias, unchangedFile, removedLater].sorted(by: RemotePath.bytewiseLess))
        let managedMode = try FileManager.default.attributesOfItem(atPath: repository.location.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(managedMode?.intValue, 0o700)

        let changedBytes = Data("changed".utf8)
        let changedObject = try await store.importFile(from: try write(changedBytes, under: root), expectedSize: Int64(changedBytes.count), into: repository.id)
        let secondPoint = try await store.publish(
            RestorePointManifest(
                createdAt: Date(timeIntervalSince1970: 200), selection: firstManifest.selection,
                entries: [
                    BackupEntry(path: unicodeFolder, kind: .directory, size: 0, modifiedAt: nil, contentHash: nil),
                    BackupEntry(path: firstFile, kind: .file, size: changedObject.size, modifiedAt: nil, contentHash: changedObject.sha256),
                    BackupEntry(path: unchangedFile, kind: .file, size: firstObject.size, modifiedAt: nil, contentHash: firstObject.sha256),
                ]
            ), in: repository.id
        )

        let points = try await store.restorePoints(in: repository.id)
        let firstPointEntries = try await store.entries(in: repository.id, point: firstPoint.id, below: unicodeFolder)
        let secondPointEntries = try await store.entries(in: repository.id, point: secondPoint.id, below: unicodeFolder)
        let report = try await store.verify(repository: repository.id)
        XCTAssertEqual(points, [secondPoint, firstPoint])
        XCTAssertEqual(firstPointEntries.count, 4)
        XCTAssertEqual(secondPointEntries.count, 2)
        XCTAssertEqual(report, RepositoryIntegrityReport(restorePointsChecked: 2, objectsChecked: 3, totalBytes: Int64(firstBytes.count + changedBytes.count)))

        try await store.closeRepository(repository.id)
        let reopenedStore = LocalBackupRepositoryStore()
        let reopened = try await reopenedStore.openRepositories(in: root)
        XCTAssertEqual(reopened, [repository])
        let reopenedPoints = try await reopenedStore.restorePoints(in: repository.id)
        XCTAssertEqual(reopenedPoints, [secondPoint, firstPoint])
    }

    func testRepositoryLockRejectsConcurrentWriterAndReleasesOnClose() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try testDevice("pixel-lock")
        let first = LocalBackupRepositoryStore()
        let repository = try await first.openOrCreateRepository(in: root, for: device)
        let second = LocalBackupRepositoryStore()

        do {
            _ = try await second.openRepositories(in: root)
            XCTFail("Expected the repository lock to reject a second writer")
        } catch let error as EngineError {
            guard case .repositoryBusy = error else { return XCTFail("Unexpected error: \(error)") }
        }

        try await first.closeRepository(repository.id)
        let afterRelease = try await second.openRepositories(in: root)
        XCTAssertEqual(afterRelease, [repository])
    }

    func testInterruptedAttemptAndVerifiedCheckpointSurviveRepositoryReopen() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try testDevice("pixel-resume")
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: root, for: device)
        let selection = BackupSelection(scope: .selected([try RemotePath("/sdcard/Pictures")]))
        let attempt = try await store.beginBackupAttempt(in: repository.id, device: device.id, selection: selection)
        let bytes = Data("checkpoint bytes".utf8)
        let reference = try await store.importFile(from: try write(bytes, under: root),
                                                   expectedSize: Int64(bytes.count), into: repository.id)
        let path = try RemotePath("/sdcard/Pictures/photo.jpg")
        try await store.saveCheckpoint(
            BackupCheckpoint(path: path, size: reference.size, modifiedAt: Date(timeIntervalSince1970: 10),
                             contentHash: reference.sha256), for: attempt.id, in: repository.id
        )
        try await store.closeRepository(repository.id)

        let reopenedStore = LocalBackupRepositoryStore()
        _ = try await reopenedStore.openRepositories(in: root)
        let attempts = try await reopenedStore.backupAttempts(in: repository.id)
        let recoveredAttempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(recoveredAttempt.id, attempt.id)
        XCTAssertEqual(recoveredAttempt.state, .interrupted)
        XCTAssertEqual(recoveredAttempt.checkpointCount, 1)
        let checkpoints = try await reopenedStore.checkpoints(for: attempt.id, in: repository.id)
        XCTAssertEqual(checkpoints, [BackupCheckpoint(path: path, size: reference.size,
                                                       modifiedAt: Date(timeIntervalSince1970: 10),
                                                       contentHash: reference.sha256)])
    }

    func testCorruptObjectAndInvalidManifestAreRejectedWithoutPublishingPartialPoint() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let device = try testDevice("pixel-corrupt")
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: root, for: device)
        let path = try RemotePath("/sdcard/photo.jpg")
        let bytes = Data("original".utf8)
        let reference = try await store.importFile(from: try write(bytes, under: root), expectedSize: Int64(bytes.count), into: repository.id)
        let invalid = RestorePointManifest(selection: BackupSelection(scope: .selected([path])), entries: [
            BackupEntry(path: path, kind: .file, size: reference.size + 1, modifiedAt: nil, contentHash: reference.sha256)
        ])
        do {
            _ = try await store.publish(invalid, in: repository.id)
            XCTFail("Expected size mismatch")
        } catch let error as EngineError {
            guard case .corruptedRepository = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let pointsAfterFailure = try await store.restorePoints(in: repository.id)
        XCTAssertTrue(pointsAfterFailure.isEmpty)

        let valid = RestorePointManifest(selection: BackupSelection(scope: .selected([path])), entries: [
            BackupEntry(path: path, kind: .file, size: reference.size, modifiedAt: nil, contentHash: reference.sha256)
        ])
        let point = try await store.publish(valid, in: repository.id)
        let object = repository.location.appendingPathComponent("objects/sha256/\(reference.sha256.prefix(2))/\(reference.sha256.dropFirst(2))")
        try Data("tampered".utf8).write(to: object)
        do {
            _ = try await store.verify(repository: repository.id, point: point.id)
            XCTFail("Expected object integrity failure")
        } catch let error as EngineError {
            guard case .corruptedRepository = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testOpenOrCreateAssociatesSeparateRepositoryWithEachDevice() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBackupRepositoryStore()
        let first = try await store.openOrCreateRepository(in: root, for: testDevice("pixel-a"))
        let second = try await store.openOrCreateRepository(in: root, for: testDevice("pixel-b"))
        XCTAssertNotEqual(first.id, second.id)
        let repositories = try await store.repositories()
        let reopenedFirst = try await store.openOrCreateRepository(in: root, for: testDevice("pixel-a"))
        XCTAssertEqual(Set(repositories.map(\.deviceID)), Set([first.deviceID, second.deviceID]))
        XCTAssertEqual(reopenedFirst, first)
    }

    func testSQLiteFailureRollsBackPointAndEntryRowsTogether() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: root, for: testDevice("pixel-rollback"))
        let path = try RemotePath("/sdcard/rollback.txt")
        let data = Data("rollback".utf8)
        let reference = try await store.importFile(from: try write(data, under: root), expectedSize: Int64(data.count), into: repository.id)
        try executeSQLite(at: repository.location.appendingPathComponent("metadata.sqlite"), sql: "CREATE TRIGGER fail_entry BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'injected failure'); END")

        do {
            _ = try await store.publish(
                RestorePointManifest(selection: BackupSelection(scope: .selected([path])), entries: [
                    BackupEntry(path: path, kind: .file, size: reference.size, modifiedAt: nil, contentHash: reference.sha256)
                ]), in: repository.id
            )
            XCTFail("Expected injected SQLite failure")
        } catch let error as EngineError {
            guard case .repositoryIO = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let points = try await store.restorePoints(in: repository.id)
        XCTAssertTrue(points.isEmpty)
    }

    func testUnavailableRepositoryFolderIsReportedAfterItMoves() async throws {
        let root = try temporaryDirectory()
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: root, for: testDevice("pixel-volume"))
        try FileManager.default.moveItem(at: root, to: movedRoot)
        do {
            _ = try await store.verify(repository: repository.id, point: nil)
            XCTFail("Expected missing repository volume")
        } catch let error as EngineError {
            guard case .repositoryUnavailable = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testUnknownSQLiteSchemaIsRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: root, for: testDevice("pixel-schema"))
        try await store.closeRepository(repository.id)
        try executeSQLite(at: repository.location.appendingPathComponent("metadata.sqlite"), sql: "PRAGMA user_version = 99")

        do {
            _ = try await LocalBackupRepositoryStore().openRepositories(in: root)
            XCTFail("Expected unsupported schema error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .repositoryFormatUnsupported(99))
        }
    }

    func testCopiedRepositoryIdentityCannotReplaceAnOpenHandle() async throws {
        let firstRoot = try temporaryDirectory()
        let secondRoot = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }
        let store = LocalBackupRepositoryStore()
        let repository = try await store.openOrCreateRepository(in: firstRoot, for: testDevice("pixel-copy"))
        let copiedManagedRoot = secondRoot.appendingPathComponent("PhoneBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: copiedManagedRoot, withIntermediateDirectories: true)
        let copiedRepository = copiedManagedRoot.appendingPathComponent(repository.location.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: repository.location, to: copiedRepository)

        do {
            _ = try await store.openRepositories(in: secondRoot)
            XCTFail("Expected duplicate repository identity to be rejected")
        } catch let error as EngineError {
            guard case .repositoryBusy = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let currentRepositories = try await store.repositories()
        XCTAssertEqual(currentRepositories.map(\.location.path), [repository.location.path])
    }

    func testSQLiteFullMapsToInsufficientSpace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SQLiteDatabase(path: root.appendingPathComponent("full.sqlite").path)
        try database.execute("CREATE TABLE payloads(value BLOB NOT NULL)")
        let pageCount = try database.rows("PRAGMA page_count") { Int(sqlite3_column_int($0, 0)) }.first ?? 0
        try database.execute("PRAGMA max_page_count = \(pageCount)")
        let payload = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
        let failure: SQLiteFailure
        do {
            try database.execute("INSERT INTO payloads(value) VALUES(?)", bindings: [.blob(payload)])
            return XCTFail("Expected SQLite to run out of pages")
        } catch let error as SQLiteFailure {
            failure = error
        }
        XCTAssertEqual(failure.code, SQLITE_FULL)
        let mapped = LocalBackupRepositoryStore.mapRepositoryError(
            failure,
            location: root
        )
        XCTAssertEqual(mapped, .insufficientSpace)
    }

    private func testDevice(_ serial: String) throws -> AndroidDevice {
        AndroidDevice(id: try DeviceID(serial: serial), state: .device, model: "Pixel", product: "pixel")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, under directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw EngineError.repositoryIO("Could not open test SQLite database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw EngineError.repositoryIO(String(cString: sqlite3_errmsg(database)))
        }
    }

}
