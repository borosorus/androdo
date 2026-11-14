import Foundation
import Darwin
import ADBInstallerLock
import PhoneBackupCore
import ZIPFoundation

public enum ADBInstallationPhase: Sendable, Equatable {
    case downloading
    case extracting
    case validating
    case publishing
}

public struct ADBInstallationProgress: Sendable, Equatable {
    public let phase: ADBInstallationPhase
    public let downloadedBytes: Int64
    public let expectedBytes: Int64?

    public init(phase: ADBInstallationPhase, downloadedBytes: Int64 = 0, expectedBytes: Int64? = nil) {
        self.phase = phase
        self.downloadedBytes = downloadedBytes
        self.expectedBytes = expectedBytes
    }

    public var downloadFraction: Double? {
        guard phase == .downloading, let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(expectedBytes)))
    }
}

public protocol ADBPlatformToolsInstalling: Sendable {
    var managedADBExecutableURL: URL { get }
    func install(progress: @escaping @Sendable (ADBInstallationProgress) async -> Void) async throws -> URL
}

public enum ADBPlatformToolsInstallError: LocalizedError, Equatable {
    case invalidGoogleResponse
    case archiveTooLarge
    case invalidArchive(String)
    case adbValidationFailed
    case unsafeInstallationFolder
    case publicationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidGoogleResponse:
            "Google’s Platform Tools download could not be verified. Check your connection and try again."
        case .archiveTooLarge:
            "The Platform Tools download exceeded the allowed size. No files were installed."
        case .invalidArchive(let detail):
            "The Platform Tools archive could not be safely installed. \(detail)"
        case .adbValidationFailed:
            "The downloaded ADB executable did not pass its version check. The previous installation is unchanged."
        case .unsafeInstallationFolder:
            "Androdo’s local Platform Tools folder is not a safe app-owned folder. Choose Locate ADB or review that folder in Finder."
        case .publicationFailed:
            "Androdo could not switch to the new Platform Tools installation. The previous installation is unchanged."
        }
    }
}

/// Downloads Google's current macOS Platform Tools into an app-owned generation.
/// The stable `current` symlink changes only after archive and executable validation.
public final class GoogleADBPlatformToolsInstaller: ADBPlatformToolsInstalling, @unchecked Sendable {
    public static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    fileprivate static let maximumDownloadBytes: Int64 = 100 * 1024 * 1024
    private static let maximumEntryBytes: UInt64 = 100 * 1024 * 1024
    private static let maximumExpandedBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumEntryCount = 4096

    public let managedADBExecutableURL: URL
    private let rootDirectory: URL
    private let downloader: any PlatformToolsDownloading
    private let commandRunner: any CommandRunning

    public init(rootDirectory: URL = GoogleADBPlatformToolsInstaller.defaultRootDirectory,
                downloader: any PlatformToolsDownloading = GooglePlatformToolsDownloader(),
                commandRunner: any CommandRunning = ProcessCommandRunner()) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.managedADBExecutableURL = rootDirectory.appendingPathComponent("current/platform-tools/adb")
        self.downloader = downloader
        self.commandRunner = commandRunner
    }

    public static var defaultRootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Androdo/Platform Tools", isDirectory: true)
    }

    public func install(progress: @escaping @Sendable (ADBInstallationProgress) async -> Void) async throws -> URL {
        let fileManager = FileManager.default
        try Self.prepareOwnedDirectory(rootDirectory, fileManager: fileManager)
        let generationsDirectory = rootDirectory.appendingPathComponent("generations", isDirectory: true)
        try Self.prepareOwnedDirectory(generationsDirectory, fileManager: fileManager)
        let lockDescriptor = try await acquireInstallLock()
        defer {
            _ = androdo_flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
        }

        let identifier = UUID().uuidString.lowercased()
        let stagingDirectory = rootDirectory.appendingPathComponent(".install-\(identifier)", isDirectory: true)
        let generationDirectory = generationsDirectory.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        var published = false
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            if !published { try? fileManager.removeItem(at: generationDirectory) }
        }

        let archiveURL = stagingDirectory.appendingPathComponent("platform-tools.zip")
        guard fileManager.createFile(atPath: archiveURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        await progress(ADBInstallationProgress(phase: .downloading))
        try await downloader.downloadPlatformTools(to: archiveURL) { downloaded, expected in
            await progress(ADBInstallationProgress(phase: .downloading,
                                                   downloadedBytes: downloaded,
                                                   expectedBytes: expected))
        }
        try Task.checkCancellation()

        await progress(ADBInstallationProgress(phase: .extracting))
        let extractedRoot = stagingDirectory.appendingPathComponent("contents", isDirectory: true)
        try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        try Self.extractPlatformTools(from: archiveURL, to: extractedRoot, fileManager: fileManager)
        try Task.checkCancellation()

        try fileManager.createDirectory(at: generationDirectory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        let generationTools = generationDirectory.appendingPathComponent("platform-tools", isDirectory: true)
        try fileManager.moveItem(at: extractedRoot.appendingPathComponent("platform-tools"), to: generationTools)
        let generationADB = generationTools.appendingPathComponent("adb")

        await progress(ADBInstallationProgress(phase: .validating))
        try Task.checkCancellation()
        guard ADBExecutableResolver.isExecutableFile(at: generationADB) else {
            throw ADBPlatformToolsInstallError.invalidArchive("The archive does not contain an executable platform-tools/adb.")
        }
        let output = try await commandRunner.run(executable: generationADB, arguments: ["version"], timeout: 15)
        let version = String(data: output.data, encoding: .utf8) ?? ""
        guard output.exitCode == 0, version.contains("Android Debug Bridge version") else {
            throw ADBPlatformToolsInstallError.adbValidationFailed
        }
        try Task.checkCancellation()

        await progress(ADBInstallationProgress(phase: .publishing))
        try Task.checkCancellation()
        let previousGeneration = try Self.currentGenerationName(at: rootDirectory, fileManager: fileManager)
        try Self.publish(generation: identifier, in: rootDirectory, fileManager: fileManager)
        published = true
        Self.pruneOldGenerations(in: generationsDirectory, keeping: [identifier, previousGeneration].compactMap { $0 },
                                 fileManager: fileManager)
        return managedADBExecutableURL
    }

    private static func extractPlatformTools(from archiveURL: URL, to destination: URL,
                                             fileManager: FileManager) throws {
        try ClassicZIPPreflight.validate(archiveURL: archiveURL,
                                        maximumArchiveBytes: UInt64(maximumDownloadBytes),
                                        maximumEntryCount: maximumEntryCount,
                                        maximumEntryBytes: maximumEntryBytes,
                                        maximumExpandedBytes: maximumExpandedBytes)
        let archive: Archive
        do { archive = try Archive(url: archiveURL, accessMode: .read) }
        catch { throw ADBPlatformToolsInstallError.invalidArchive("The ZIP file is damaged or unsupported.") }

        var entries: [Entry] = []
        entries.reserveCapacity(maximumEntryCount)
        for entry in archive {
            try Task.checkCancellation()
            guard entries.count < maximumEntryCount else {
                throw ADBPlatformToolsInstallError.invalidArchive("The archive has an unexpected number of files.")
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else {
            throw ADBPlatformToolsInstallError.invalidArchive("The archive has no Platform Tools files.")
        }

        var seenPaths = Set<String>()
        var pathKinds: [String: Entry.EntryType] = [:]
        var componentSpellings: [String: String] = [:]
        var expandedBytes: UInt64 = 0
        var actualExpandedBytes: UInt64 = 0
        var containsADB = false

        for entry in entries {
            let path = entry.path
            let isDirectory = entry.type == .directory
            guard entry.type == .file || isDirectory else {
                throw ADBPlatformToolsInstallError.invalidArchive("Symbolic links and special files are not accepted.")
            }
            let components = try safeComponents(for: path, isDirectory: isDirectory)
            var normalizedComponents: [String] = []
            for component in components {
                normalizedComponents.append(component)
                let key = normalizedComponents.joined(separator: "/")
                    .precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                                     locale: Locale(identifier: "en_US_POSIX"))
                let spelling = normalizedComponents.joined(separator: "/").precomposedStringWithCanonicalMapping
                if let existing = componentSpellings[key], existing != spelling {
                    throw ADBPlatformToolsInstallError.invalidArchive("The archive contains case-colliding paths.")
                }
                componentSpellings[key] = spelling
            }
            let normalized = normalizedComponents.joined(separator: "/")
                .precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                                 locale: Locale(identifier: "en_US_POSIX"))
            guard seenPaths.insert(normalized).inserted else {
                throw ADBPlatformToolsInstallError.invalidArchive("The archive contains duplicate or case-colliding paths.")
            }
            for index in 1..<components.count {
                let parent = components.prefix(index).joined(separator: "/").precomposedStringWithCanonicalMapping
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                if pathKinds[parent] == .file {
                    throw ADBPlatformToolsInstallError.invalidArchive("A file is also used as a parent folder.")
                }
            }
            if !isDirectory, pathKinds.keys.contains(where: { $0.hasPrefix(normalized + "/") }) {
                throw ADBPlatformToolsInstallError.invalidArchive("A file conflicts with a folder in the archive.")
            }
            pathKinds[normalized] = entry.type

            guard entry.uncompressedSize <= maximumEntryBytes,
                  expandedBytes <= maximumExpandedBytes - entry.uncompressedSize else {
                throw ADBPlatformToolsInstallError.archiveTooLarge
            }
            expandedBytes += entry.uncompressedSize
            if path == "platform-tools/adb", entry.type == .file { containsADB = true }

            let target = components.reduce(destination) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }.standardizedFileURL
            let destinationPrefix = destination.standardizedFileURL.path + "/"
            guard target.path == destination.standardizedFileURL.path || target.path.hasPrefix(destinationPrefix) else {
                throw ADBPlatformToolsInstallError.invalidArchive("The archive contains a path outside Platform Tools.")
            }
        }

        guard containsADB else {
            throw ADBPlatformToolsInstallError.invalidArchive("The archive does not contain platform-tools/adb.")
        }

        for entry in entries {
            try Task.checkCancellation()
            let components = try safeComponents(for: entry.path, isDirectory: entry.type == .directory)
            let target = components.reduce(destination) { partial, component in
                partial.appendingPathComponent(component, isDirectory: false)
            }
            if entry.type == .directory {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
                guard fileManager.createFile(atPath: target.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
                    throw ADBPlatformToolsInstallError.invalidArchive("The archive contains duplicate output files.")
                }
                let handle = try FileHandle(forWritingTo: target)
                let checksum: CRC32
                var actualEntryBytes: UInt64 = 0
                do {
                    checksum = try archive.extract(entry, bufferSize: defaultReadChunkSize, skipCRC32: false) { chunk in
                        try Task.checkCancellation()
                        let chunkSize = UInt64(chunk.count)
                        guard chunkSize <= Self.maximumEntryBytes,
                              actualEntryBytes <= Self.maximumEntryBytes - chunkSize,
                              chunkSize <= entry.uncompressedSize,
                              actualEntryBytes <= entry.uncompressedSize - chunkSize else {
                            throw ADBPlatformToolsInstallError.invalidArchive("A file expanded beyond its declared ZIP size.")
                        }
                        guard chunkSize <= Self.maximumExpandedBytes,
                              actualExpandedBytes <= Self.maximumExpandedBytes - chunkSize else {
                            throw ADBPlatformToolsInstallError.archiveTooLarge
                        }
                        actualEntryBytes += chunkSize
                        actualExpandedBytes += chunkSize
                        try handle.write(contentsOf: chunk)
                    }
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                guard actualEntryBytes == entry.uncompressedSize, checksum == entry.checksum else {
                    throw ADBPlatformToolsInstallError.invalidArchive("A Platform Tools file failed its size or ZIP integrity check.")
                }
                let storedMode = (entry.fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                let isExecutableTool = ["adb", "fastboot", "etc1tool", "hprof-conv"].contains(components.last ?? "")
                let mode = isExecutableTool || storedMode & 0o111 != 0 ? 0o755 : 0o644
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            }
        }

        let adb = destination.appendingPathComponent("platform-tools/adb")
        guard ADBExecutableResolver.isExecutableFile(at: adb) else {
            throw ADBPlatformToolsInstallError.invalidArchive("The archive does not contain an executable platform-tools/adb.")
        }
    }

    private static func safeComponents(for path: String, isDirectory: Bool) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.contains(":"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ADBPlatformToolsInstallError.invalidArchive("The archive contains an invalid file path.")
        }
        var trimmed = path
        if isDirectory, trimmed.hasSuffix("/") { trimmed.removeLast() }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
        }), components[0] == "platform-tools",
              components.count > 1 || isDirectory else {
            throw ADBPlatformToolsInstallError.invalidArchive("The archive contains a path outside the platform-tools folder.")
        }
        return components
    }

    private static func prepareOwnedDirectory(_ url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw ADBPlatformToolsInstallError.unsafeInstallationFolder
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func currentGenerationName(at root: URL, fileManager: FileManager) throws -> String? {
        let current = root.appendingPathComponent("current")
        guard fileManager.fileExists(atPath: current.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: current.path)
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            throw ADBPlatformToolsInstallError.unsafeInstallationFolder
        }
        let target = try fileManager.destinationOfSymbolicLink(atPath: current.path)
        let components = target.split(separator: "/").map(String.init)
        guard components.count == 2, components[0] == "generations",
              UUID(uuidString: components[1]) != nil else {
            throw ADBPlatformToolsInstallError.unsafeInstallationFolder
        }
        return components[1]
    }

    private static func publish(generation: String, in root: URL, fileManager: FileManager) throws {
        let current = root.appendingPathComponent("current")
        let temporaryLink = root.appendingPathComponent(".current-\(UUID().uuidString.lowercased())")
        defer { try? fileManager.removeItem(at: temporaryLink) }
        try fileManager.createSymbolicLink(atPath: temporaryLink.path, withDestinationPath: "generations/\(generation)")
        let result = temporaryLink.path.withCString { source in
            current.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw ADBPlatformToolsInstallError.publicationFailed }
    }

    private static func pruneOldGenerations(in directory: URL, keeping generations: [String],
                                            fileManager: FileManager) {
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let keep = Set(generations)
        for item in contents where !keep.contains(item.lastPathComponent) {
            try? fileManager.removeItem(at: item)
        }
    }

    private func acquireInstallLock() async throws -> Int32 {
        let lockURL = rootDirectory.appendingPathComponent(".install.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw ADBPlatformToolsInstallError.unsafeInstallationFolder }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else {
            _ = Darwin.close(descriptor)
            throw ADBPlatformToolsInstallError.unsafeInstallationFolder
        }
        while androdo_flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                _ = Darwin.close(descriptor)
                throw ADBPlatformToolsInstallError.unsafeInstallationFolder
            }
            do {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
        do { try Task.checkCancellation() }
        catch {
            _ = androdo_flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }
}

public protocol PlatformToolsDownloading: Sendable {
    func downloadPlatformTools(to destination: URL,
                               progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws
}

public struct GooglePlatformToolsDownloader: PlatformToolsDownloading {
    public init() {}

    public func downloadPlatformTools(to destination: URL,
                                      progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: GoogleRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: GoogleADBPlatformToolsInstaller.downloadURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "GET"
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == "dl.google.com" else {
            throw ADBPlatformToolsInstallError.invalidGoogleResponse
        }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        if let expected, expected > GoogleADBPlatformToolsInstaller.maximumDownloadBytes {
            throw ADBPlatformToolsInstallError.archiveTooLarge
        }

        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        var downloaded: Int64 = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    downloaded += Int64(chunk.count)
                    guard downloaded <= GoogleADBPlatformToolsInstaller.maximumDownloadBytes else {
                        throw ADBPlatformToolsInstallError.archiveTooLarge
                    }
                    try handle.write(contentsOf: Data(chunk))
                    await progress(downloaded, expected)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty {
                downloaded += Int64(chunk.count)
                guard downloaded <= GoogleADBPlatformToolsInstaller.maximumDownloadBytes else {
                    throw ADBPlatformToolsInstallError.archiveTooLarge
                }
                try handle.write(contentsOf: Data(chunk))
            }
            guard downloaded > 0, expected == nil || downloaded == expected else {
                throw ADBPlatformToolsInstallError.invalidGoogleResponse
            }
            try handle.synchronize()
            await progress(downloaded, expected ?? downloaded)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

private final class GoogleRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.lowercased() == "dl.google.com" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// ZIPFoundation is used for streaming inflation, but its ZIP64 offset parsing has
/// preconditions that must not receive an untrusted offset. Validate the classic
/// ZIP layout and all ranges first; Google's current Platform Tools archive is far
/// below ZIP64 limits.
private enum ClassicZIPPreflight {
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50
    private static let centralDirectorySignature: UInt32 = 0x02014b50
    private static let localHeaderSignature: UInt32 = 0x04034b50
    private static let dataDescriptorSignature: UInt32 = 0x08074b50
    private static let zip64ExtraFieldID = 0x0001
    private static let supportedGeneralFlags = 0x080e

    static func validate(archiveURL: URL, maximumArchiveBytes: UInt64, maximumEntryCount: Int,
                         maximumEntryBytes: UInt64, maximumExpandedBytes: UInt64) throws {
        let data: Data
        do { data = try Data(contentsOf: archiveURL, options: .mappedIfSafe) }
        catch { throw invalid("The ZIP file could not be read.") }
        guard UInt64(data.count) <= maximumArchiveBytes else { throw ADBPlatformToolsInstallError.archiveTooLarge }
        guard data.count >= 22 else { throw invalid("The ZIP end record is missing.") }

        let tailStart = max(0, data.count - 65_557)
        var endRecord: Int?
        for offset in stride(from: data.count - 22, through: tailStart, by: -1) {
            guard read32(data, offset) == endOfCentralDirectorySignature else { continue }
            let commentLength = read16(data, offset + 20)
            if offset + 22 + commentLength == data.count {
                endRecord = offset
                break
            }
        }
        guard let endRecord else { throw invalid("The ZIP end record is missing or outside its allowed window.") }
        guard read16(data, endRecord + 20) == 0 else {
            throw invalid("ZIP archive comments are not supported.")
        }
        if endRecord >= 76,
           read32(data, endRecord - 76) == 0x06064b50,
           read32(data, endRecord - 20) == 0x07064b50 {
            throw invalid("ZIP64 end records are not supported.")
        }

        let diskNumber = read16(data, endRecord + 4)
        let centralDisk = read16(data, endRecord + 6)
        let entriesOnDisk = read16(data, endRecord + 8)
        let entryCount = read16(data, endRecord + 10)
        let centralSizeRaw = read32(data, endRecord + 12)
        let centralOffsetRaw = read32(data, endRecord + 16)
        guard diskNumber == 0, centralDisk == 0, entriesOnDisk == entryCount,
              entryCount != 0xffff, centralSizeRaw != UInt32.max, centralOffsetRaw != UInt32.max else {
            throw invalid("Multi-disk and ZIP64 archives are not supported.")
        }
        guard entryCount > 0, entryCount <= maximumEntryCount else {
            throw invalid("The archive has an unexpected number of files.")
        }

        let centralOffset = Int(centralOffsetRaw)
        let centralSize = Int(centralSizeRaw)
        let centralEnd = centralOffset.addingReportingOverflow(centralSize)
        guard !centralEnd.overflow, centralEnd.partialValue == endRecord,
              centralOffset >= 0, centralOffset <= data.count else {
            throw invalid("The ZIP central directory has invalid bounds.")
        }

        var cursor = centralOffset
        var expandedBytes: UInt64 = 0
        var localRanges: [(start: Int, end: Int)] = []
        localRanges.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            try Task.checkCancellation()
            guard cursor <= endRecord - 46,
                  read32(data, cursor) == centralDirectorySignature else {
                throw invalid("The ZIP central directory is incomplete.")
            }

            let versionNeeded = read16(data, cursor + 6)
            let flags = read16(data, cursor + 8)
            let method = read16(data, cursor + 10)
            let checksum = read32(data, cursor + 16)
            let compressedSizeRaw = read32(data, cursor + 20)
            let expandedSizeRaw = read32(data, cursor + 24)
            let nameLength = read16(data, cursor + 28)
            let extraLength = read16(data, cursor + 30)
            let commentLength = read16(data, cursor + 32)
            let diskStart = read16(data, cursor + 34)
            let localOffsetRaw = read32(data, cursor + 42)
            guard versionNeeded < 45, flags & ~supportedGeneralFlags == 0,
                  method == 0 || method == 8, diskStart == 0,
                  compressedSizeRaw != UInt32.max, expandedSizeRaw != UInt32.max,
                  localOffsetRaw != UInt32.max, nameLength > 0 else {
                throw invalid("The archive uses unsupported ZIP features.")
            }
            let compressedSize = UInt64(compressedSizeRaw)
            let expandedSize = UInt64(expandedSizeRaw)
            guard compressedSize <= maximumArchiveBytes, expandedSize <= maximumEntryBytes,
                  expandedBytes <= maximumExpandedBytes - expandedSize else {
                throw ADBPlatformToolsInstallError.archiveTooLarge
            }
            expandedBytes += expandedSize

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            let extraEnd = nameEnd + extraLength
            let recordEnd = extraEnd + commentLength
            guard nameEnd <= endRecord, extraEnd <= endRecord, recordEnd <= endRecord else {
                throw invalid("A ZIP central-directory record is truncated.")
            }
            try validateExtraFields(data, from: nameEnd, to: extraEnd)

            let localOffset = Int(localOffsetRaw)
            guard localOffset >= 0, localOffset <= centralOffset - 30,
                  read32(data, localOffset) == localHeaderSignature else {
                throw invalid("A ZIP entry has an invalid local-header offset.")
            }
            let localVersion = read16(data, localOffset + 4)
            let localFlags = read16(data, localOffset + 6)
            let localMethod = read16(data, localOffset + 8)
            let localChecksum = read32(data, localOffset + 14)
            let localCompressedSize = read32(data, localOffset + 18)
            let localExpandedSize = read32(data, localOffset + 22)
            let localNameLength = read16(data, localOffset + 26)
            let localExtraLength = read16(data, localOffset + 28)
            let localNameStart = localOffset + 30
            let localNameEnd = localNameStart + localNameLength
            let localExtraEnd = localNameEnd + localExtraLength
            guard localVersion < 45, localFlags == flags, localMethod == method,
                  localNameLength == nameLength, localNameEnd <= centralOffset,
                  localExtraEnd <= centralOffset,
                  data[localNameStart..<localNameEnd] == data[nameStart..<nameEnd] else {
                throw invalid("A ZIP local header does not match its central directory entry.")
            }
            try validateExtraFields(data, from: localNameEnd, to: localExtraEnd)

            let usesDescriptor = flags & 0x0008 != 0
            guard localCompressedSize != UInt32.max, localExpandedSize != UInt32.max else {
                throw invalid("ZIP64 entry sizes are not supported.")
            }
            if usesDescriptor {
                guard (localChecksum == 0 || localChecksum == checksum),
                      (localCompressedSize == 0 || localCompressedSize == compressedSizeRaw),
                      (localExpandedSize == 0 || localExpandedSize == expandedSizeRaw) else {
                    throw invalid("A ZIP data descriptor conflicts with its local header.")
                }
            } else {
                guard localChecksum == checksum, localCompressedSize == compressedSizeRaw,
                      localExpandedSize == expandedSizeRaw else {
                    throw invalid("A ZIP local header has inconsistent sizes or checksum.")
                }
            }

            let dataStart = localExtraEnd
            let dataEnd = dataStart.addingReportingOverflow(Int(compressedSize))
            guard !dataEnd.overflow, dataEnd.partialValue <= centralOffset else {
                throw invalid("A ZIP entry's compressed data is outside the archive.")
            }
            var entryEnd = dataEnd.partialValue
            if usesDescriptor {
                guard entryEnd <= centralOffset - 12 else { throw invalid("A ZIP data descriptor is truncated.") }
                let hasSignature = read32(data, entryEnd) == dataDescriptorSignature
                let descriptorStart = entryEnd + (hasSignature ? 4 : 0)
                guard descriptorStart <= centralOffset - 12,
                      read32(data, descriptorStart) == checksum,
                      read32(data, descriptorStart + 4) == compressedSizeRaw,
                      read32(data, descriptorStart + 8) == expandedSizeRaw else {
                    throw invalid("A ZIP data descriptor is invalid.")
                }
                entryEnd = descriptorStart + 12
            }
            localRanges.append((localOffset, entryEnd))
            cursor = recordEnd
        }
        guard cursor == endRecord else { throw invalid("The ZIP central-directory size is inconsistent.") }

        let sortedRanges = localRanges.sorted { $0.start < $1.start }
        if sortedRanges.count > 1 {
            for index in 1..<sortedRanges.count where sortedRanges[index].start < sortedRanges[index - 1].end {
                throw invalid("ZIP entries overlap in the archive.")
            }
        }
    }

    private static func validateExtraFields(_ data: Data, from start: Int, to end: Int) throws {
        var cursor = start
        while cursor < end {
            guard cursor <= end - 4 else { throw invalid("A ZIP extra field is truncated.") }
            let identifier = read16(data, cursor)
            let size = read16(data, cursor + 2)
            let next = cursor + 4 + size
            guard next <= end, identifier != zip64ExtraFieldID else {
                throw invalid("ZIP64 and malformed extra fields are not supported.")
            }
            cursor = next
        }
    }

    private static func read16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func invalid(_ detail: String) -> ADBPlatformToolsInstallError {
        .invalidArchive(detail)
    }
}
