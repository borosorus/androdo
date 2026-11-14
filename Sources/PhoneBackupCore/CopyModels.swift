import Foundation

public enum CopyRequest: Sendable {
    case phoneToMac(session: DeviceSession, roots: [RemotePath], destination: URL)
    case macToPhone(session: DeviceSession, sources: [URL], destination: RemotePath,
                    replaceMissingTargets: Set<RemotePath> = [])
}

public enum CopySource: Equatable, Sendable {
    case phone(RemoteEntry)
    case local(URL)
}

public struct CopyMapping: Equatable, Sendable, Identifiable {
    public let source: CopySource
    public let destination: RestoreDestination
    public let kind: RemoteEntryKind
    public var id: String {
        switch source {
        case .phone(let entry): entry.path.description
        case .local(let url): url.standardizedFileURL.path
        }
    }

    public init(source: CopySource, destination: RestoreDestination, kind: RemoteEntryKind) {
        self.source = source
        self.destination = destination
        self.kind = kind
    }
}

public struct CopyPlanID: Hashable, Sendable, Identifiable {
    public let id: UUID
    public init(_ id: UUID = UUID()) { self.id = id }
}

public struct CopyPlan: Sendable, Identifiable {
    public let id: CopyPlanID
    public let request: CopyRequest
    public let mappings: [CopyMapping]
    public let conflicts: [RestoreConflict]
    public let totalBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int

    public init(id: CopyPlanID = CopyPlanID(), request: CopyRequest, mappings: [CopyMapping],
                conflicts: [RestoreConflict], totalBytes: Int64, fileCount: Int, directoryCount: Int) {
        self.id = id
        self.request = request
        self.mappings = mappings
        self.conflicts = conflicts
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
    }
}

public enum CopyItemState: String, Sendable {
    case publishedAndVerified
    case publishedUnverified
    case failed
    case skipped
    case cancelled
}

public struct CopyItemResult: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: String
    public let destination: String
    public let state: CopyItemState
    public let detail: String?

    public init(source: String, destination: String, state: CopyItemState, detail: String? = nil) {
        id = source
        self.source = source
        self.destination = destination
        self.state = state
        self.detail = detail
    }
}

public struct CopyBatchResult: Sendable {
    public let operationID: OperationID
    public let items: [CopyItemResult]

    public init(operationID: OperationID, items: [CopyItemResult]) {
        self.operationID = operationID
        self.items = items
    }
}
