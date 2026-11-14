import Foundation
import PhoneBackupCore

/// Presentation intent is independent from the lifetime of the engine task.
public struct OperationProgressSession: Identifiable, Equatable {
    public enum Stage: Equatable { case planning, starting, running, finished }

    public let id = UUID()
    public let kind: OperationKind
    public internal(set) var stage: Stage
    public internal(set) var isPresented = true
    public internal(set) var cancellationRequested = false
    public internal(set) var failure: String?
    public internal(set) var wasCancelled = false

    public var presentationID: UUID? { isPresented ? id : nil }
    public var isFinished: Bool { stage == .finished }

    init(kind: OperationKind, stage: Stage) {
        self.kind = kind
        self.stage = stage
    }
}

extension AppModel {
    var progressPresentation: OperationPresentation {
        guard let session = progressSession else {
            return OperationPresentation(kind: operationKind, event: operationEvent, isRunning: isOperationRunning,
                                         recovery: recoveryAttempt, pendingCount: pendingAttempts.count)
        }
        let noun = session.kind.displayName
        if session.cancellationRequested && !session.isFinished {
            return OperationPresentation(title: "Cancelling \(noun.lowercased())…", symbol: "xmark.circle",
                                         phase: "Waiting for the current work to stop safely.")
        }
        switch session.stage {
        case .planning:
            let phase: String
            switch session.kind {
            case .backup: phase = "Scanning selected folders…"
            case .copy: phase = "Checking selected files and destinations…"
            case .restore, .export:
                if let progress = restorePlanningProgress {
                    let action = progress.stage == .verifyingBackup ? "Verifying backup" : "Checking destination paths"
                    phase = progress.totalItems > 0 ? "\(action) · \(progress.completedItems) of \(progress.totalItems)" : "\(action)…"
                } else { phase = "Checking the restore point…" }
            }
            return OperationPresentation(title: "Preparing \(noun.lowercased())", symbol: "magnifyingglass", phase: phase)
        case .starting:
            return OperationPresentation(title: "Starting \(noun.lowercased())…", symbol: "arrow.triangle.2.circlepath",
                                         phase: "Preparing to write files…")
        case .finished where session.failure != nil:
            return OperationPresentation(title: "\(noun) needs attention", symbol: "exclamationmark.triangle", phase: "Review the details below before trying again.")
        case .finished where session.wasCancelled:
            return OperationPresentation(title: "\(noun) cancelled", symbol: "xmark.circle", phase: "No files were written during preparation.")
        case .running, .finished:
            return OperationPresentation(kind: session.kind, event: operationEvent, isRunning: isOperationRunning,
                                         recovery: recoveryAttempt, pendingCount: pendingAttempts.count)
        }
    }
}

extension OperationKind {
    var displayName: String {
        switch self { case .backup: "Backup"; case .restore: "Restore"; case .export: "Export"; case .copy: "Copy" }
    }
}
