import Foundation

public struct DeviceID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let serial: String

    public init(serial: String) throws {
        guard !serial.isEmpty, !serial.contains("\0") else {
            throw EngineError.invalidIdentifier
        }
        self.serial = serial
    }

    public var description: String { serial }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(serial: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serial)
    }
}

public enum DeviceState: Codable, Equatable, Sendable {
    case device
    case unauthorized
    case offline
    case bootloader
    case recovery
    case sideload
    case unknown(String)
}

public struct AndroidDevice: Codable, Equatable, Sendable, Identifiable {
    public let id: DeviceID
    public let state: DeviceState
    public let model: String?
    public let product: String?

    public init(id: DeviceID, state: DeviceState, model: String? = nil, product: String? = nil) {
        self.id = id
        self.state = state
        self.model = model
        self.product = product
    }
}

/// A normalized absolute path on the device. Names must be valid UTF-8 strings.
public struct RemotePath: Codable, Hashable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ absolutePath: String) throws {
        guard absolutePath.hasPrefix("/") else { throw EngineError.invalidRemotePath(absolutePath) }
        if absolutePath == "/" {
            components = []
            return
        }

        let parts = absolutePath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw EngineError.invalidRemotePath(absolutePath)
        }
        components = parts.map(String.init)
    }

    public init(components: [String]) throws {
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0)
        }) else {
            throw EngineError.invalidRemotePath(components.joined(separator: "/"))
        }
        self.components = components
    }

    public static let root = try! RemotePath("/")

    public var description: String {
        components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    public var name: String? { components.last }

    public static func == (lhs: RemotePath, rhs: RemotePath) -> Bool {
        guard lhs.components.count == rhs.components.count else { return false }
        return zip(lhs.components, rhs.components).allSatisfy {
            Array($0.utf8) == Array($1.utf8)
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components.count)
        for component in components {
            hasher.combine(Array(component.utf8))
        }
    }

    public static func bytewiseLess(_ lhs: RemotePath, _ rhs: RemotePath) -> Bool {
        Array(lhs.description.utf8).lexicographicallyPrecedes(Array(rhs.description.utf8))
    }

    public var parent: RemotePath? {
        guard !components.isEmpty else { return nil }
        return try? RemotePath(components: Array(components.dropLast()))
    }

    public func appending(_ component: String) throws -> RemotePath {
        try RemotePath(components: components + [component])
    }

    public func isEqualOrDescendant(of ancestor: RemotePath) -> Bool {
        guard ancestor.components.count <= components.count else { return false }
        return zip(components, ancestor.components).allSatisfy {
            Array($0.utf8) == Array($1.utf8)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public enum RemoteEntryKind: String, Codable, Sendable {
    case directory
    case file
    case symbolicLink
    case other
}

public struct RemoteEntry: Codable, Equatable, Sendable, Identifiable {
    public let path: RemotePath
    public let kind: RemoteEntryKind
    public let size: Int64?
    public let modifiedAt: Date?

    public init(path: RemotePath, kind: RemoteEntryKind, size: Int64? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var id: RemotePath { path }
    public var name: String { path.name ?? "/" }
}

public enum BackupScope: Codable, Equatable, Sendable {
    case allSharedStorage
    case selected([RemotePath])
}

/// Empty selections select nothing. The shared-storage scope is explicit and distinct from `/`.
public struct BackupSelection: Codable, Equatable, Sendable {
    public let scope: BackupScope
    public let excludedRoots: [RemotePath]

    public init(scope: BackupScope = .selected([]), excludedRoots: [RemotePath] = []) {
        switch scope {
        case .allSharedStorage:
            self.scope = scope
        case .selected(let roots):
            let unique = Set(roots)
            self.scope = .selected(unique.sorted(by: RemotePath.bytewiseLess))
        }
        self.excludedRoots = Array(Set(excludedRoots)).sorted(by: RemotePath.bytewiseLess)
    }

    public var selectsEverything: Bool {
        if case .allSharedStorage = scope { return excludedRoots.isEmpty }
        return false
    }

    public func includes(_ path: RemotePath) -> Bool {
        guard !excludedRoots.contains(where: { path.isEqualOrDescendant(of: $0) }) else { return false }
        switch scope {
        case .allSharedStorage:
            return path.isEqualOrDescendant(of: try! RemotePath("/sdcard"))
        case .selected(let roots):
            return roots.contains(where: { path.isEqualOrDescendant(of: $0) })
        }
    }

    public var normalizedRoots: [RemotePath] {
        let roots: [RemotePath]
        switch scope {
        case .allSharedStorage: roots = [try! RemotePath("/sdcard")]
        case .selected(let selected): roots = selected
        }
        return roots.filter { candidate in
            !roots.contains(where: { $0 != candidate && candidate.isEqualOrDescendant(of: $0) })
        }.sorted(by: RemotePath.bytewiseLess)
    }
}

public struct BackupPlanID: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public struct BackupPlan: Codable, Equatable, Sendable, Identifiable {
    public let id: BackupPlanID
    public let repository: RepositoryID
    public let device: DeviceID
    public let selection: BackupSelection
    public let scannedAt: Date
    public let directoryCount: Int
    public let fileCount: Int
    public let transferCount: Int
    public let reusedCount: Int
    public let deletedCount: Int
    public let bytesToTransfer: Int64
    public let totalBytes: Int64
    public let omissions: [OperationWarning]

    public init(id: BackupPlanID = BackupPlanID(), repository: RepositoryID, device: DeviceID,
                selection: BackupSelection, scannedAt: Date, directoryCount: Int, fileCount: Int,
                transferCount: Int, reusedCount: Int, deletedCount: Int, bytesToTransfer: Int64,
                totalBytes: Int64, omissions: [OperationWarning]) {
        self.id = id
        self.repository = repository
        self.device = device
        self.selection = selection
        self.scannedAt = scannedAt
        self.directoryCount = directoryCount
        self.fileCount = fileCount
        self.transferCount = transferCount
        self.reusedCount = reusedCount
        self.deletedCount = deletedCount
        self.bytesToTransfer = bytesToTransfer
        self.totalBytes = totalBytes
        self.omissions = omissions
    }
}

public struct BackupAttemptID: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public enum BackupAttemptState: String, Codable, Sendable {
    case running
    case interrupted
    case needsOmissionDecision
}

public struct BackupAttempt: Codable, Equatable, Sendable, Identifiable {
    public let id: BackupAttemptID
    public let repository: RepositoryID
    public let device: DeviceID
    public let selection: BackupSelection
    public let startedAt: Date
    public let state: BackupAttemptState
    public let omissions: [OperationWarning]
    public let checkpointCount: Int

    public init(id: BackupAttemptID, repository: RepositoryID, device: DeviceID, selection: BackupSelection,
                startedAt: Date, state: BackupAttemptState, omissions: [OperationWarning], checkpointCount: Int) {
        self.id = id
        self.repository = repository
        self.device = device
        self.selection = selection
        self.startedAt = startedAt
        self.state = state
        self.omissions = omissions
        self.checkpointCount = checkpointCount
    }
}

public struct BackupCheckpoint: Codable, Equatable, Sendable {
    public let path: RemotePath
    public let size: Int64
    public let modifiedAt: Date?
    public let contentHash: String

    public init(path: RemotePath, size: Int64, modifiedAt: Date?, contentHash: String) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
    }
}

public enum BackupOmissionChoice: Equatable, Sendable {
    case requireComplete
    case finishWithOmissions
}

public struct RepositoryID: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public struct BackupRepositoryInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: RepositoryID
    public let location: URL
    public let deviceID: DeviceID
    public let displayName: String

    public init(id: RepositoryID = RepositoryID(), location: URL, deviceID: DeviceID, displayName: String) {
        self.id = id
        self.location = location
        self.deviceID = deviceID
        self.displayName = displayName
    }
}

public struct RestorePointID: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public enum RestorePointState: String, Codable, Sendable {
    case completed
    case incomplete
}

public struct RestorePoint: Codable, Equatable, Sendable, Identifiable {
    public let id: RestorePointID
    public let createdAt: Date
    public let state: RestorePointState
    public let selection: BackupSelection
    public let entryCount: Int
    public let totalBytes: Int64
    public let omissions: [OperationWarning]

    public init(
        id: RestorePointID = RestorePointID(),
        createdAt: Date,
        state: RestorePointState,
        selection: BackupSelection = BackupSelection(),
        entryCount: Int,
        totalBytes: Int64,
        omissions: [OperationWarning] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.state = state
        self.selection = selection
        self.entryCount = entryCount
        self.totalBytes = totalBytes
        self.omissions = omissions
    }
}

public struct ContentObjectReference: Codable, Equatable, Hashable, Sendable {
    public let sha256: String
    public let size: Int64

    public init(sha256: String, size: Int64) {
        self.sha256 = sha256
        self.size = size
    }
}

public struct RestorePointManifest: Codable, Equatable, Sendable {
    public let id: RestorePointID
    public let createdAt: Date
    public let selection: BackupSelection
    public let entries: [BackupEntry]
    public let omissions: [OperationWarning]

    public init(
        id: RestorePointID = RestorePointID(),
        createdAt: Date = Date(),
        selection: BackupSelection,
        entries: [BackupEntry],
        omissions: [OperationWarning] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.selection = selection
        self.entries = entries
        self.omissions = omissions
    }
}

public struct RepositoryIntegrityReport: Codable, Equatable, Sendable {
    public let restorePointsChecked: Int
    public let objectsChecked: Int
    public let totalBytes: Int64

    public init(restorePointsChecked: Int, objectsChecked: Int, totalBytes: Int64) {
        self.restorePointsChecked = restorePointsChecked
        self.objectsChecked = objectsChecked
        self.totalBytes = totalBytes
    }
}

public struct BackupEntry: Codable, Equatable, Sendable, Identifiable {
    public let path: RemotePath
    public let kind: RemoteEntryKind
    public let size: Int64
    public let modifiedAt: Date?
    public let contentHash: String?

    public init(path: RemotePath, kind: RemoteEntryKind, size: Int64, modifiedAt: Date?, contentHash: String?) {
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
    }

    public var id: RemotePath { path }
}

public enum RestoreTarget: Equatable, Sendable {
    case localFolder(URL, sourceBase: RemotePath)
    case originalPhonePaths
    case phoneFolder(RemotePath, sourceBase: RemotePath)
}

public enum RestoreDestination: Hashable, Sendable {
    case local(URL)
    case phone(RemotePath)
}

public enum PhoneRestoreConflictPolicy: String, CaseIterable, Sendable {
    /// Requires atomic no-overwrite publication; unsupported Android filesystems fail clearly.
    case stopIfFileExists
    /// Authorizes replacement publication only for exact files captured and approved in this plan.
    case replaceFiles
}

public struct RestorePlanningProgress: Sendable {
    public enum Stage: Sendable { case verifyingBackup, checkingDestinations }
    public let stage: Stage
    public let completedItems: Int
    public let totalItems: Int

    public init(stage: Stage, completedItems: Int, totalItems: Int) {
        self.stage = stage
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}

public struct RestoreRequest: Sendable {
    public let repository: RepositoryID
    public let point: RestorePointID
    public let selectedRoots: [RemotePath]
    public let target: RestoreTarget
    public let phoneConflictPolicy: PhoneRestoreConflictPolicy
    public init(repository: RepositoryID, point: RestorePointID, selectedRoots: [RemotePath], target: RestoreTarget,
                phoneConflictPolicy: PhoneRestoreConflictPolicy = .stopIfFileExists) {
        self.repository = repository
        self.point = point
        self.selectedRoots = Array(Set(selectedRoots)).sorted(by: RemotePath.bytewiseLess)
        self.target = target
        self.phoneConflictPolicy = phoneConflictPolicy
    }
}

public struct RestoreMapping: Equatable, Sendable, Identifiable {
    public let source: BackupEntry
    public let destination: RestoreDestination
    public var id: RemotePath { source.path }

    public init(source: BackupEntry, destination: RestoreDestination) {
        self.source = source
        self.destination = destination
    }
}

public enum RestoreConflictKind: String, Equatable, Sendable {
    case fileExists
    case directoryExists
    case unsafePath
    case caseOrUnicodeAlias
}

public enum RemoteDestinationState: Equatable, Sendable {
    case missing
    case regularFile(identity: String, size: Int64)
    case directory(identity: String)
    case symbolicLink(identity: String)
    case other(identity: String)
}

public struct RestoreConflict: Equatable, Sendable, Identifiable {
    public static let approvedMissingTargetIdentity = "<missing>"
    public let id: UUID
    public let destination: RestoreDestination
    public let kind: RestoreConflictKind
    public let observedIdentity: String?
    public let replaceable: Bool

    public init(id: UUID = UUID(), destination: RestoreDestination, kind: RestoreConflictKind,
                observedIdentity: String? = nil, replaceable: Bool) {
        self.id = id
        self.destination = destination
        self.kind = kind
        self.observedIdentity = observedIdentity
        self.replaceable = replaceable
    }
}

public struct RestorePlanID: Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public struct RestorePlan: Sendable, Identifiable {
    public let id: RestorePlanID
    public let request: RestoreRequest
    public let mappings: [RestoreMapping]
    public let conflicts: [RestoreConflict]
    public let totalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let sourceOmissions: [OperationWarning]

    public init(id: RestorePlanID = RestorePlanID(), request: RestoreRequest, mappings: [RestoreMapping],
                conflicts: [RestoreConflict], totalBytes: Int64, fileCount: Int, directoryCount: Int,
                sourceOmissions: [OperationWarning] = []) {
        self.id = id
        self.request = request
        self.mappings = mappings
        self.conflicts = conflicts
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.sourceOmissions = sourceOmissions
    }
}

public enum RestoreItemState: String, Sendable {
    case publishedAndVerified
    case publishedUnverified
    case skipped
    case failed
    case cancelled
}

public struct RestoreItemResult: Equatable, Sendable, Identifiable {
    public let id: RemotePath
    public let source: RemotePath
    public let destination: RestoreDestination
    public let state: RestoreItemState
    public let detail: String?

    public init(source: RemotePath, destination: RestoreDestination, state: RestoreItemState, detail: String? = nil) {
        self.id = source
        self.source = source
        self.destination = destination
        self.state = state
        self.detail = detail
    }
}

public struct RestoreBatchResult: Sendable {
    public let operationID: OperationID
    public let items: [RestoreItemResult]

    public init(operationID: OperationID, items: [RestoreItemResult]) {
        self.operationID = operationID
        self.items = items
    }
}

public enum ConflictKind: String, Codable, Sendable {
    case fileExists
    case directoryExists
    case caseOrUnicodeAlias
    case unsafePath
}

public struct TransferConflict: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let destination: String
    public let kind: ConflictKind

    public init(id: UUID = UUID(), destination: String, kind: ConflictKind) {
        self.id = id
        self.destination = destination
        self.kind = kind
    }
}

public enum OperationPhase: String, Codable, Sendable {
    case scanning
    case planning
    case transferring
    case verifying
    case committing
    case completed
    case incomplete
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .incomplete, .cancelled, .failed: true
        default: false
        }
    }

    public func canTransition(to next: OperationPhase) -> Bool {
        switch self {
        case .scanning:
            [.planning, .incomplete, .cancelled, .failed].contains(next)
        case .planning:
            [.transferring, .committing, .incomplete, .cancelled, .failed].contains(next)
        case .transferring:
            [.verifying, .incomplete, .cancelled, .failed].contains(next)
        case .verifying:
            [.committing, .incomplete, .cancelled, .failed].contains(next)
        case .committing:
            [.completed, .incomplete, .failed].contains(next)
        case .completed, .incomplete, .cancelled, .failed:
            false
        }
    }
}

public struct OperationProgress: Codable, Equatable, Sendable {
    public let completedItems: Int
    public let totalItems: Int?
    public let completedBytes: Int64
    public let totalBytes: Int64?

    public init(completedItems: Int = 0, totalItems: Int? = nil, completedBytes: Int64 = 0, totalBytes: Int64? = nil) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

public enum WarningCode: String, Codable, Hashable, Sendable {
    case inaccessiblePath
    case unsupportedFilename
    case sourceChanged
    case missingPath
    case unsupportedEntryKind
}

public struct OperationWarning: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let code: WarningCode
    public let path: RemotePath?
    public let message: String

    public init(id: UUID = UUID(), code: WarningCode, path: RemotePath? = nil, message: String) {
        self.id = id
        self.code = code
        self.path = path
        self.message = message
    }
}

public enum RecoveryAction: String, Codable, Sendable {
    case retry
    case locateADB
    case reconnectDevice
    case chooseAccessiblePaths
    case chooseDestination
    case allowReplacement
    case closeOtherRepository
    case reconnectVolume
}

public enum EngineError: Error, Codable, Equatable, Sendable {
    case invalidIdentifier
    case invalidRemotePath(String)
    case adbUnavailable(String)
    case operationTimedOut
    case deviceUnavailable(DeviceID)
    case missingPath(RemotePath)
    case inaccessiblePath(RemotePath)
    case notDirectory(RemotePath)
    case unsupportedDirectoryListing(DeviceID)
    case destinationConflict(TransferConflict)
    case unsupportedFilename(RemotePath)
    case sourceChanged(RemotePath)
    case insufficientSpace
    case safeNoOverwriteUnavailable(RemotePath)
    case destinationPublishedUnverified(String, String)
    case corruptedRepository(String)
    case repositoryBusy(URL)
    case repositoryDeviceMismatch(RepositoryID)
    case repositoryUnavailable(URL)
    case repositoryFormatUnsupported(Int)
    case repositoryIO(String)
    case emptySelection
    case transport(String)

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .deviceUnavailable: [.reconnectDevice, .retry]
        case .inaccessiblePath, .unsupportedFilename, .unsupportedDirectoryListing: [.chooseAccessiblePaths]
        case .missingPath: [.chooseAccessiblePaths]
        case .notDirectory: [.chooseAccessiblePaths]
        case .adbUnavailable: [.locateADB]
        case .operationTimedOut: [.retry]
        case .repositoryBusy: [.closeOtherRepository, .retry]
        case .repositoryDeviceMismatch: [.chooseDestination]
        case .repositoryUnavailable: [.reconnectVolume, .retry]
        case .repositoryFormatUnsupported: [.retry]
        case .repositoryIO: [.retry, .chooseDestination]
        case .emptySelection: [.chooseAccessiblePaths]
        case .destinationConflict(let conflict):
            conflict.kind == .fileExists ? [.allowReplacement] : [.chooseDestination]
        case .safeNoOverwriteUnavailable: [.chooseDestination]
        case .destinationPublishedUnverified: [.retry]
        case .sourceChanged: [.retry]
        case .insufficientSpace: [.chooseDestination]
        case .corruptedRepository, .transport: [.retry]
        case .invalidIdentifier, .invalidRemotePath: []
        }
    }
}

public struct OperationID: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public struct OperationEvent: Codable, Equatable, Sendable {
    public let operationID: OperationID
    public let phase: OperationPhase
    public let progress: OperationProgress
    public let warnings: [OperationWarning]
    public let failure: EngineError?

    public init(
        operationID: OperationID,
        phase: OperationPhase,
        progress: OperationProgress = OperationProgress(),
        warnings: [OperationWarning] = [],
        failure: EngineError? = nil
    ) {
        self.operationID = operationID
        self.phase = phase
        self.progress = progress
        self.warnings = warnings
        self.failure = failure
    }
}
