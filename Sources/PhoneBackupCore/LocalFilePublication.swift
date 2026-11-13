import CryptoKit
import Darwin
import Foundation

enum LocalFilePublication {
    static func rootIdentity(_ root: URL) throws -> String {
        let descriptor = try openRoot(root.standardizedFileURL.resolvingSymlinksInPath())
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw EngineError.repositoryIO("Could not inspect chosen restore folder") }
        return rootID(info)
    }

    static func inspect(root: URL, components: [String], expectedRootIdentity: String? = nil) throws -> LocalDestinationState {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootDescriptor = try openRoot(rootURL)
        defer { _ = Darwin.close(rootDescriptor) }
        try requireRootIdentity(rootDescriptor, expected: expectedRootIdentity)
        guard !components.isEmpty else { return .directory(identity: "root") }
        var parentDescriptor = rootDescriptor
        var ownedParent: Int32?
        defer { if let ownedParent { _ = Darwin.close(ownedParent) } }
        for component in components.dropLast() {
            guard Self.validComponent(component) else { throw EngineError.repositoryIO("Unsafe local destination component") }
            let descriptor = component.withCString { Darwin.openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            if descriptor < 0 {
                if errno == ENOENT { return .missing }
                if errno == ELOOP || errno == ENOTDIR { return .unsafePath }
                throw EngineError.repositoryIO("Could not inspect local destination")
            }
            if let previous = ownedParent { _ = Darwin.close(previous) }
            parentDescriptor = descriptor
            ownedParent = descriptor
        }
        var info = stat()
        let result = components.last!.withCString { Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW) }
        // parentDescriptor is the root descriptor when the target is at its root.
        guard result == 0 else {
            if errno == ENOENT { return .missing }
            throw EngineError.repositoryIO("Could not inspect local destination")
        }
        let identity = Self.identity(info)
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile(identity: identity, size: Int64(info.st_size))
        case S_IFDIR: return .directory(identity: identity)
        case S_IFLNK: return .symbolicLink(identity: identity)
        default: return .other(identity: identity)
        }
    }

    static func ensureDirectory(root: URL, components: [String], expectedRootIdentity: String? = nil) throws {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootDescriptor = try openRoot(rootURL)
        defer { _ = Darwin.close(rootDescriptor) }
        try requireRootIdentity(rootDescriptor, expected: expectedRootIdentity)
        var current = rootDescriptor
        var owned: Int32?
        defer { if let owned { _ = Darwin.close(owned) } }
        for component in components {
            guard Self.validComponent(component) else { throw EngineError.repositoryIO("Unsafe local directory component") }
            var descriptor = component.withCString { Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            if descriptor < 0 && errno == ENOENT {
                guard component.withCString({ Darwin.mkdirat(current, $0, S_IRWXU) }) == 0 || errno == EEXIST else {
                    throw EngineError.repositoryIO("Could not create local destination directory")
                }
                descriptor = component.withCString { Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            }
            guard descriptor >= 0 else { throw EngineError.destinationConflict(TransferConflict(destination: component, kind: .unsafePath)) }
            if let owned { _ = Darwin.close(owned) }
            current = descriptor
            owned = descriptor
        }
    }

    static func publish(source: URL, expected: ContentObjectReference, modifiedAt: Date?, root: URL, components: [String],
                        expectedRootIdentity: String? = nil, replacing approvedIdentity: String?) async throws {
        guard let name = components.last, Self.validComponent(name) else {
            throw EngineError.repositoryIO("Invalid local destination filename")
        }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        try ensureDirectory(root: resolvedRoot, components: Array(components.dropLast()),
                            expectedRootIdentity: expectedRootIdentity)
        let rootDescriptor = try openRoot(resolvedRoot)
        defer { _ = Darwin.close(rootDescriptor) }
        try requireRootIdentity(rootDescriptor, expected: expectedRootIdentity)
        let parent = try openDirectory(rootDescriptor, components: Array(components.dropLast()))
        defer { _ = Darwin.close(parent) }
        let before = try inspectAt(parent: parent, name: name)
        switch before {
        case .missing:
            guard approvedIdentity == nil else { throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .fileExists)) }
        case .regularFile(let identity, _):
            guard approvedIdentity == identity else { throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .fileExists)) }
        case .directory:
            throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .directoryExists))
        case .symbolicLink, .other, .unsafePath:
            throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .unsafePath))
        }

        let stagingName = ".phonebackup-\(UUID().uuidString.lowercased())"
        let stagingDescriptor = stagingName.withCString {
            Darwin.openat(parent, $0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard stagingDescriptor >= 0 else { throw EngineError.repositoryIO("Could not create sibling staging file") }
        var published = false
        defer {
            _ = Darwin.close(stagingDescriptor)
            if !published { _ = stagingName.withCString { Darwin.unlinkat(parent, $0, 0) } }
        }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var hasher = SHA256()
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            copied += Int64(chunk.count)
            guard copied <= expected.size else { throw EngineError.corruptedRepository("Staged restore object exceeds its expected size") }
            hasher.update(data: chunk)
            try writeAll(chunk, to: stagingDescriptor)
        }
        try Task.checkCancellation()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard copied == expected.size, digest == expected.sha256 else {
            throw EngineError.corruptedRepository("Staged restore object failed verification")
        }
        if let modifiedAt {
            let timestamp = modifiedAt.timeIntervalSince1970
            guard timestamp.isFinite else { throw EngineError.corruptedRepository("Invalid source modification date") }
            let seconds = floor(timestamp)
            let microseconds = Int32((timestamp - seconds) * 1_000_000)
            var times = [timeval(tv_sec: 0, tv_usec: 0), timeval(tv_sec: Int(seconds), tv_usec: microseconds)]
            guard Darwin.futimes(stagingDescriptor, &times) == 0 else {
                throw EngineError.repositoryIO("Could not preserve restored file modification date")
            }
        }
        guard Darwin.fsync(stagingDescriptor) == 0 else { throw EngineError.repositoryIO("Could not synchronize staged restore file") }
        if case .regularFile(let identity, _) = try inspectAt(parent: parent, name: name) {
            guard approvedIdentity == identity else { throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .fileExists)) }
        } else if approvedIdentity != nil {
            throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .fileExists))
        }
        try verifyRootPathIdentity(resolvedRoot, expected: expectedRootIdentity)
        try Task.checkCancellation()
        let result: Int32
        if approvedIdentity == nil {
            result = stagingName.withCString { sourceName in name.withCString { Darwin.renameatx_np(parent, sourceName, parent, $0, UInt32(RENAME_EXCL)) } }
        } else {
            result = stagingName.withCString { sourceName in name.withCString { Darwin.renameat(parent, sourceName, parent, $0) } }
        }
        guard result == 0 else {
            if errno == EEXIST { throw EngineError.destinationConflict(TransferConflict(destination: name, kind: .fileExists)) }
            throw EngineError.repositoryIO("Could not publish restored file")
        }
        published = true
        do {
            try verifyRootPathIdentity(resolvedRoot, expected: expectedRootIdentity)
            guard Darwin.fsync(parent) == 0 else { throw EngineError.repositoryIO("Could not synchronize restore directory") }
            let final = try inspectAt(parent: parent, name: name)
            guard case .regularFile = final else { throw EngineError.repositoryIO("Restored file is not a regular file") }
            try verifyFinal(parent: parent, name: name, expected: expected)
        } catch {
            throw EngineError.destinationPublishedUnverified(
                root.appendingPathComponent(components.joined(separator: "/")).path, error.localizedDescription
            )
        }
    }

    enum LocalDestinationState {
        case missing
        case regularFile(identity: String, size: Int64)
        case directory(identity: String)
        case symbolicLink(identity: String)
        case other(identity: String)
        case unsafePath
    }

    private static func openRoot(_ root: URL) throws -> Int32 {
        let descriptor = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw EngineError.repositoryIO("Chosen local destination is unavailable or unsafe") }
        return descriptor
    }

    private static func requireRootIdentity(_ descriptor: Int32, expected: String?) throws {
        guard let expected else { return }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, rootID(info) == expected else {
            throw EngineError.destinationConflict(TransferConflict(destination: "chosen local folder", kind: .unsafePath))
        }
    }

    private static func verifyRootPathIdentity(_ root: URL, expected: String?) throws {
        guard let expected else { return }
        let descriptor = try openRoot(root)
        defer { _ = Darwin.close(descriptor) }
        try requireRootIdentity(descriptor, expected: expected)
    }

    private static func openDirectory(_ root: Int32, components: [String]) throws -> Int32 {
        var current = root
        var owned: Int32?
        for component in components {
            guard validComponent(component) else { throw EngineError.repositoryIO("Unsafe local destination component") }
            let next = component.withCString { Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
            guard next >= 0 else {
                if let owned { _ = Darwin.close(owned) }
                throw EngineError.destinationConflict(TransferConflict(destination: component, kind: .unsafePath))
            }
            if let owned { _ = Darwin.close(owned) }
            current = next
            owned = next
        }
        return owned ?? Darwin.dup(root)
    }

    private static func inspectAt(parent: Int32, name: String) throws -> LocalDestinationState {
        var info = stat()
        guard name.withCString({ Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            if errno == ENOENT { return .missing }
            if errno == ENOTDIR || errno == ELOOP { return .unsafePath }
            throw EngineError.repositoryIO("Could not inspect local destination entry")
        }
        let identity = self.identity(info)
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .regularFile(identity: identity, size: Int64(info.st_size))
        case S_IFDIR: return .directory(identity: identity)
        case S_IFLNK: return .symbolicLink(identity: identity)
        default: return .other(identity: identity)
        }
    }

    private static func identity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }

    private static func rootID(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT)"
    }

    private static func validComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." && !component.contains("/") && !component.utf8.contains(0)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw EngineError.repositoryIO("Could not write staged restore file") }
                offset += written
            }
        }
    }

    private static func verifyFinal(parent: Int32, name: String, expected: ContentObjectReference) throws {
        let descriptor = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw EngineError.repositoryIO("Could not reopen restored file for verification") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            size += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == expected.size, digest == expected.sha256 else {
            throw EngineError.repositoryIO("Restored file failed final verification")
        }
    }
}
