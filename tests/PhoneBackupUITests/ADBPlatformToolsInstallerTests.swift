import Foundation
import XCTest
import ZIPFoundation
import PhoneBackupCore
@testable import PhoneBackupUI

final class ADBPlatformToolsInstallerTests: XCTestCase {
    func testInstallPublishesValidatedToolsUnderInjectedApplicationSupportRoot() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: fixture.archiveURL))
        let updates = InstallationProgressRecorder()

        let installed = try await installer.install { await updates.append($0) }
        let progress = await updates.values()

        XCTAssertEqual(installed, installer.managedADBExecutableURL)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.deletingLastPathComponent()
            .appendingPathComponent("lib64/libfixture.dylib").path))
        XCTAssertEqual(progress.first?.phase, .downloading)
        XCTAssertEqual(progress.last?.phase, .publishing)
        XCTAssertEqual(progress.compactMap(\.downloadFraction).last, 1)
        XCTAssertEqual(installer.managedADBExecutableURL,
                       fixture.home.appendingPathComponent("Library/Application Support/Androdo/Platform Tools/current/platform-tools/adb"))
        XCTAssertEqual(ADBExecutableResolver.resolve(environment: ["PATH": ""], homeDirectory: fixture.home), installed)
    }

    func testUnsafeArchiveCannotReplacePreviouslyPublishedGeneration() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: fixture.archiveURL))
        _ = try await installer.install { _ in }
        let previousTarget = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.toolsRoot
            .appendingPathComponent("current").path)

        let unsafeArchive = try fixture.makeUnsafePathArchive()
        let unsafeInstaller = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                                downloader: FixtureDownloader(archiveURL: unsafeArchive))
        do {
            _ = try await unsafeInstaller.install { _ in }
            XCTFail("Expected the archive path traversal to be rejected")
        } catch let error as ADBPlatformToolsInstallError {
            guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.toolsRoot
            .appendingPathComponent("current").path), previousTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.toolsRoot.deletingLastPathComponent()
            .appendingPathComponent("adb").path))
    }

    func testADBVersionFailureLeavesPreviousGenerationActive() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: fixture.archiveURL))
        _ = try await installer.install { _ in }
        let current = fixture.toolsRoot.appendingPathComponent("current")
        let previousTarget = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)

        let invalidArchive = try fixture.makeArchive(adbScript: "#!/bin/sh\necho not-adb\nexit 3\n")
        let invalidInstaller = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                                 downloader: FixtureDownloader(archiveURL: invalidArchive))
        do {
            _ = try await invalidInstaller.install { _ in }
            XCTFail("Expected the adb version check to fail")
        } catch let error as ADBPlatformToolsInstallError {
            XCTAssertEqual(error, .adbValidationFailed)
        }

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), previousTarget)
    }

    func testCRCFailureInSupportingFileRejectsWholeArchive() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = try fixture.makeMutatedArchive(path: "platform-tools/lib64/libfixture.dylib", fieldOffset: 16,
                                                     localFieldOffset: 14) { $0[0] ^= 1 }
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: archive))

        do {
            _ = try await installer.install { _ in }
            XCTFail("Expected the supporting file CRC mismatch to be rejected")
        } catch let error as ADBPlatformToolsInstallError {
            guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.toolsRoot.appendingPathComponent("current").path))
    }

    func testActualExpandedBytesCannotExceedDeclaredZipSize() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = try fixture.makeMutatedArchive(path: "platform-tools/adb", fieldOffset: 24,
                                                     localFieldOffset: 22) { data in
            data[0] = 1
            data[1] = 0
            data[2] = 0
            data[3] = 0
        }
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: archive))

        do {
            _ = try await installer.install { _ in }
            XCTFail("Expected the forged uncompressed size to be rejected")
        } catch let error as ADBPlatformToolsInstallError {
            guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.toolsRoot.appendingPathComponent("current").path))
    }

    func testZIP64OffsetsAndSizesAreRejectedBeforeArchiveParsing() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        for (centralField, localField) in [(20, Optional(18)), (42, Optional<Int>.none)] {
            let archive = try fixture.makeMutatedArchive(path: "platform-tools/adb", fieldOffset: centralField,
                                                         localFieldOffset: localField) { data in
                data = [0xff, 0xff, 0xff, 0xff]
            }
            let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                              downloader: FixtureDownloader(archiveURL: archive))
            do {
                _ = try await installer.install { _ in }
                XCTFail("Expected ZIP64 metadata to be rejected")
            } catch let error as ADBPlatformToolsInstallError {
                guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.toolsRoot.appendingPathComponent("current").path))
    }

    func testArchiveCommentIsRejectedBeforeZIPFoundationCanSelectAnotherEndRecord() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = try fixture.makeArchiveWithComment()
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: archive))

        do {
            _ = try await installer.install { _ in }
            XCTFail("Expected ZIP archive comments to be rejected")
        } catch let error as ADBPlatformToolsInstallError {
            guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testFabricatedZIP64LocatorInCentralCommentIsRejectedBeforeDependencyParsing() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = try fixture.makeArchiveWithFabricatedZIP64EndRecord()
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: archive))

        do {
            _ = try await installer.install { _ in }
            XCTFail("Expected the ZIP64 end-record signatures to be rejected")
        } catch let error as ADBPlatformToolsInstallError {
            guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.toolsRoot.appendingPathComponent("current").path))
    }

    func testArchiveEntryLimitIsCheckedDuringEnumeration() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let archive = try fixture.makeOversizedEntryCountArchive()
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: archive))

        do {
            _ = try await installer.install { _ in }
            XCTFail("Expected the archive entry limit to be enforced")
        } catch let error as ADBPlatformToolsInstallError {
            guard case .invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.toolsRoot.appendingPathComponent("current").path))
    }

    func testCancellationAtPublicationDoesNotSwitchCurrentGeneration() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let installer = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                          downloader: FixtureDownloader(archiveURL: fixture.archiveURL))
        _ = try await installer.install { _ in }
        let current = fixture.toolsRoot.appendingPathComponent("current")
        let previousTarget = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
        let gate = AsyncGate()
        let update = Task {
            try await GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot,
                                                        downloader: FixtureDownloader(archiveURL: fixture.archiveURL))
                .install { progress in
                    if progress.phase == .publishing { await gate.pause() }
                }
        }
        await gate.waitUntilReached()
        update.cancel()
        await gate.release()

        do {
            _ = try await update.value
            XCTFail("Expected installation cancellation")
        } catch is CancellationError {
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.path), previousTarget)
    }

    func testInstallersSharingARootCannotPruneEachOthersGeneration() async throws {
        let fixture = try InstallerFixture()
        defer { fixture.cleanup() }
        let downloader = CountingDownloader(archiveURL: fixture.archiveURL)
        let gate = AsyncGate()
        let first = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot, downloader: downloader)
        let second = GoogleADBPlatformToolsInstaller(rootDirectory: fixture.toolsRoot, downloader: downloader)
        let firstTask = Task {
            try await first.install { progress in
                if progress.phase == .publishing { await gate.pause() }
            }
        }
        await gate.waitUntilReached()
        let secondTask = Task { try await second.install { _ in } }
        try await Task.sleep(for: .milliseconds(120))
        let callsWhileFirstIsPaused = await downloader.callCount()
        XCTAssertEqual(callsWhileFirstIsPaused, 1)

        await gate.release()
        _ = try await firstTask.value
        _ = try await secondTask.value
        let finalCallCount = await downloader.callCount()
        XCTAssertEqual(finalCallCount, 2)
        let currentTarget = try FileManager.default.destinationOfSymbolicLink(atPath: fixture.toolsRoot
            .appendingPathComponent("current").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.toolsRoot.appendingPathComponent(currentTarget)
            .appendingPathComponent("platform-tools/adb").path))
        let generations = try FileManager.default.contentsOfDirectory(at: fixture.toolsRoot.appendingPathComponent("generations"),
                                                                       includingPropertiesForKeys: nil)
        XCTAssertEqual(generations.count, 2, "The active and immediate previous generation remain available")
    }
}

private struct FixtureDownloader: PlatformToolsDownloading {
    let archiveURL: URL

    func downloadPlatformTools(to destination: URL,
                               progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
        try Task.checkCancellation()
        let archive = try Data(contentsOf: archiveURL)
        try archive.write(to: destination, options: .atomic)
        await progress(Int64(archive.count), Int64(archive.count))
    }
}

private actor InstallationProgressRecorder {
    private var progress: [ADBInstallationProgress] = []
    func append(_ value: ADBInstallationProgress) { progress.append(value) }
    func values() -> [ADBInstallationProgress] { progress }
}

private struct InstallerFixture {
    let home: URL
    let toolsRoot: URL
    let archiveURL: URL
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        toolsRoot = home.appendingPathComponent("Library/Application Support/Androdo/Platform Tools", isDirectory: true)
        archiveURL = root.appendingPathComponent("platform-tools.zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.writeArchive(adbScript: "#!/bin/sh\nif [ \"$1\" = version ]; then echo 'Android Debug Bridge version 1.0.41'; exit 0; fi\nexit 91\n",
                              to: archiveURL, under: root)
    }

    func makeArchive(adbScript: String) throws -> URL {
        let archive = root.appendingPathComponent("fixture-\(UUID().uuidString).zip")
        try Self.writeArchive(adbScript: adbScript, to: archive, under: root)
        return archive
    }

    private static func writeArchive(adbScript: String, to archive: URL, under root: URL) throws {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        let tools = source.appendingPathComponent("platform-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools.appendingPathComponent("lib64", isDirectory: true),
                                                withIntermediateDirectories: true)
        let adb = tools.appendingPathComponent("adb")
        try Data(adbScript.utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        try Data("fixture support file".utf8).write(to: tools.appendingPathComponent("lib64/libfixture.dylib"))
        try FileManager.default.zipItem(at: tools, to: archive, shouldKeepParent: true,
                                        compressionMethod: .deflate)
    }

    func makeUnsafePathArchive() throws -> URL {
        let source = try makeArchive(adbScript: "#!/bin/sh\necho 'Android Debug Bridge version 1.0.41'\n")
        var data = try Data(contentsOf: source)
        let original = Data("platform-tools/adb".utf8)
        let traversal = Data("../../../xx/../adb".utf8)
        guard original.count == traversal.count else { throw CocoaError(.fileWriteInvalidFileName) }
        var replaced = 0
        var offset = data.startIndex
        while let range = data.range(of: original, in: offset..<data.endIndex) {
            data.replaceSubrange(range, with: traversal)
            offset = range.lowerBound + traversal.count
            replaced += 1
        }
        guard replaced >= 2 else { throw CocoaError(.fileReadCorruptFile) }
        let unsafe = root.appendingPathComponent("unsafe-\(UUID().uuidString).zip")
        try data.write(to: unsafe)
        return unsafe
    }

    func makeMutatedArchive(path: String, fieldOffset: Int, localFieldOffset: Int? = nil,
                            mutation: (inout [UInt8]) -> Void) throws -> URL {
        let source = try makeArchive(adbScript: "#!/bin/sh\necho 'Android Debug Bridge version 1.0.41'\n")
        var data = try Data(contentsOf: source)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        let targetName = Data(path.utf8)
        var offset = 0
        var found = false
        while offset + 46 <= data.count {
            if data[offset..<(offset + 4)] == signature {
                let nameLength = Int(data[offset + 28]) | (Int(data[offset + 29]) << 8)
                let extraLength = Int(data[offset + 30]) | (Int(data[offset + 31]) << 8)
                let commentLength = Int(data[offset + 32]) | (Int(data[offset + 33]) << 8)
                let nameStart = offset + 46
                let nameEnd = nameStart + nameLength
                guard nameEnd + extraLength + commentLength <= data.count else { throw CocoaError(.fileReadCorruptFile) }
                if data[nameStart..<nameEnd] == targetName {
                    let localOffset = Int(read32(data, offset + 42))
                    var field = Array(data[(offset + fieldOffset)..<(offset + fieldOffset + 4)])
                    mutation(&field)
                    data.replaceSubrange((offset + fieldOffset)..<(offset + fieldOffset + 4), with: field)
                    if let localFieldOffset {
                        guard localOffset + 30 <= data.count,
                              read32(data, localOffset) == 0x04034b50 else { throw CocoaError(.fileReadCorruptFile) }
                        var localField = Array(data[(localOffset + localFieldOffset)..<(localOffset + localFieldOffset + 4)])
                        mutation(&localField)
                        data.replaceSubrange((localOffset + localFieldOffset)..<(localOffset + localFieldOffset + 4),
                                              with: localField)
                    }
                    found = true
                    break
                }
                offset = nameEnd + extraLength + commentLength
            } else {
                offset += 1
            }
        }
        guard found else { throw CocoaError(.fileReadCorruptFile) }
        let mutatedURL = root.appendingPathComponent("mutated-\(UUID().uuidString).zip")
        try data.write(to: mutatedURL)
        return mutatedURL
    }

    private func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    func makeOversizedEntryCountArchive() throws -> URL {
        let source = root.appendingPathComponent("many-entries-\(UUID().uuidString)", isDirectory: true)
        let tools = source.appendingPathComponent("platform-tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for index in 0..<4096 {
            try Data().write(to: tools.appendingPathComponent("fixture-\(index).bin"))
        }
        let archive = root.appendingPathComponent("many-entries-\(UUID().uuidString).zip")
        try FileManager.default.zipItem(at: tools, to: archive, shouldKeepParent: true,
                                        compressionMethod: .none)
        return archive
    }

    func makeArchiveWithComment() throws -> URL {
        let source = try makeArchive(adbScript: "#!/bin/sh\necho 'Android Debug Bridge version 1.0.41'\n")
        var data = try Data(contentsOf: source)
        let endRecord = data.count - 22
        data[endRecord + 20] = 1
        data[endRecord + 21] = 0
        data.append(0x41)
        let result = root.appendingPathComponent("archive-comment-\(UUID().uuidString).zip")
        try data.write(to: result)
        return result
    }

    func makeArchiveWithFabricatedZIP64EndRecord() throws -> URL {
        let source = try makeArchive(adbScript: "#!/bin/sh\necho 'Android Debug Bridge version 1.0.41'\n")
        var data = try Data(contentsOf: source)
        let oldEndRecord = data.count - 22
        let centralOffset = Int(read32(data, oldEndRecord + 16))
        let centralSize = read32(data, oldEndRecord + 12)
        let entryCount = read16(data, oldEndRecord + 10)
        var cursor = centralOffset
        var lastCentralEntry: Int?
        for _ in 0..<entryCount {
            guard read32(data, cursor) == 0x02014b50 else { throw CocoaError(.fileReadCorruptFile) }
            let nameLength = read16(data, cursor + 28)
            let extraLength = read16(data, cursor + 30)
            let commentLength = read16(data, cursor + 32)
            lastCentralEntry = cursor
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == oldEndRecord, let lastCentralEntry else { throw CocoaError(.fileReadCorruptFile) }
        data[lastCentralEntry + 32] = 76
        data[lastCentralEntry + 33] = 0

        var zip64Tail = [UInt8](repeating: 0, count: 76)
        write32(0x06064b50, into: &zip64Tail, at: 0)
        write64(44, into: &zip64Tail, at: 4)
        write16(45, into: &zip64Tail, at: 14)
        write64(UInt64(entryCount), into: &zip64Tail, at: 24)
        write64(UInt64(entryCount), into: &zip64Tail, at: 32)
        write64(UInt64(centralSize), into: &zip64Tail, at: 40)
        write64(0x8000000000000000, into: &zip64Tail, at: 48)
        write32(0x07064b50, into: &zip64Tail, at: 56)
        write64(UInt64(oldEndRecord), into: &zip64Tail, at: 64)
        write32(1, into: &zip64Tail, at: 72)
        data.replaceSubrange(oldEndRecord..<oldEndRecord, with: zip64Tail)
        let endRecord = oldEndRecord + zip64Tail.count
        var bytes = Array(data)
        write32(centralSize + UInt32(zip64Tail.count), into: &bytes, at: endRecord + 12)
        data = Data(bytes)
        let result = root.appendingPathComponent("fake-zip64-\(UUID().uuidString).zip")
        try data.write(to: result)
        return result
    }

    private func write16(_ value: UInt16, into data: inout [UInt8], at offset: Int) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private func write32(_ value: UInt32, into data: inout [UInt8], at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    private func write64(_ value: UInt64, into data: inout [UInt8], at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8((value >> (index * 8)) & 0xff) }
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private actor CountingDownloader: PlatformToolsDownloading {
    private let archiveURL: URL
    private var calls = 0

    init(archiveURL: URL) { self.archiveURL = archiveURL }

    func downloadPlatformTools(to destination: URL,
                               progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
        calls += 1
        try Task.checkCancellation()
        let archive = try Data(contentsOf: archiveURL)
        try archive.write(to: destination, options: .atomic)
        await progress(Int64(archive.count), Int64(archive.count))
    }

    func callCount() -> Int { calls }
}

private actor AsyncGate {
    private var isPaused = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        reachedContinuation?.resume()
        reachedContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilReached() async {
        guard !isPaused else { return }
        await withCheckedContinuation { reachedContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
