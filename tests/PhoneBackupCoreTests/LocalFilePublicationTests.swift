import CryptoKit
import Foundation
import XCTest
@testable import PhoneBackupCore

final class LocalFilePublicationTests: XCTestCase {
    func testPublishesVerifiedFileAndCreatesOnlyNeededDirectories() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("restored bytes".utf8)
        let source = try write(bytes, in: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        try await LocalFilePublication.publish(source: source, expected: reference(bytes), modifiedAt: date,
                                               root: root, components: ["Pictures", "image.jpg"], replacing: nil)

        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Pictures/image.jpg")), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Pictures/image.jpg").path)
        let restoredDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertEqual(restoredDate.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
    }

    func testNoOverwritePreservesRacingDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing.txt")
        try Data("keep me".utf8).write(to: destination)
        let source = try write(Data("replacement".utf8), in: root)

        do {
            try await LocalFilePublication.publish(source: source, expected: reference(Data("replacement".utf8)),
                                                   modifiedAt: nil, root: root,
                                                   components: ["existing.txt"], replacing: nil)
            XCTFail("Expected an explicit replacement decision")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep me".utf8))
    }

    func testSymlinkAncestorIsNeverFollowed() async throws {
        let root = try temporaryDirectory()
        let external = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        let symlink = root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: external)
        let source = try write(Data("safe".utf8), in: root)

        do {
            try await LocalFilePublication.publish(source: source, expected: reference(Data("safe".utf8)),
                                                   modifiedAt: nil, root: root,
                                                   components: ["redirect", "escape.txt"], replacing: nil)
            XCTFail("Expected the symlink ancestor to be rejected")
        } catch let error as EngineError {
            guard case .destinationConflict = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("escape.txt").path))
    }

    private func reference(_ data: Data) -> ContentObjectReference {
        ContentObjectReference(sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                               size: Int64(data.count))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}
