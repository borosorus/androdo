import Foundation
import Observation
import PhoneBackupCore

public enum ActivityKind: String, Sendable {
    case backup = "Backup"
    case restore = "Restore"
    case copy = "File copy"
}

public enum ActivityOutcome: String, Sendable {
    case running, completed, incomplete, failed, cancelled
}

public struct ActivityRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: ActivityKind
    public let startedAt: Date
    public var finishedAt: Date?
    public var outcome: ActivityOutcome
    public var completedItems: Int
    public var verifiedItems: Int
    public var warningCount: Int
    public var safeSummary: String

    public init(id: UUID = UUID(), kind: ActivityKind, startedAt: Date = Date(),
                finishedAt: Date? = nil, outcome: ActivityOutcome = .running,
                completedItems: Int = 0, verifiedItems: Int = 0,
                warningCount: Int = 0, safeSummary: String = "") {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.completedItems = completedItems
        self.verifiedItems = verifiedItems
        self.warningCount = warningCount
        self.safeSummary = safeSummary
    }
}

/// Activity stays in memory in v1. Paths, serial numbers, and raw transport errors are never persisted.
@MainActor
@Observable
public final class ActivityStore {
    public private(set) var records: [ActivityRecord] = []
    private let recordLimit: Int

    public init(recordLimit: Int = 200) { self.recordLimit = max(1, recordLimit) }

    @discardableResult
    public func begin(_ kind: ActivityKind) -> UUID {
        let record = ActivityRecord(kind: kind)
        records.insert(record, at: 0)
        trim()
        return record.id
    }

    public func update(_ id: UUID, event: OperationEvent) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].completedItems = event.progress.completedItems
        records[index].warningCount = event.warnings.count
        records[index].outcome = Self.outcome(for: event.phase)
        if event.phase.isTerminal {
            records[index].finishedAt = Date()
            records[index].safeSummary = Self.summary(for: event.phase, warningCount: event.warnings.count)
        }
    }

    public func setVerifiedItems(_ count: Int, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].verifiedItems = count
    }

    public func clearFinished() { records.removeAll { $0.outcome != .running } }

    private func trim() {
        if records.count > recordLimit { records.removeLast(records.count - recordLimit) }
    }

    private static func outcome(for phase: OperationPhase) -> ActivityOutcome {
        switch phase {
        case .completed: .completed
        case .incomplete: .incomplete
        case .cancelled: .cancelled
        case .failed: .failed
        case .scanning, .planning, .transferring, .verifying, .committing: .running
        }
    }

    private static func summary(for phase: OperationPhase, warningCount: Int) -> String {
        switch phase {
        case .completed: "Completed and verified."
        case .incomplete: "Incomplete; \(warningCount) item(s) need attention."
        case .cancelled: "Cancelled; previous completed data remains available."
        case .failed: "Failed; review the operation and try again."
        case .scanning, .planning, .transferring, .verifying, .committing: "In progress."
        }
    }
}
