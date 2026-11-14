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
        if session.kind == .installADB {
            let noun = "Platform Tools"
            if session.cancellationRequested && !session.isFinished {
                return OperationPresentation(title: "Cancelling installation…", symbol: "xmark.circle",
                                             phase: "Waiting for the download or extraction to stop safely.")
            }
            if session.failure != nil {
                return OperationPresentation(title: "Platform Tools needs attention", symbol: "exclamationmark.triangle",
                                             phase: "Review the installation details below before trying again.")
            }
            if session.wasCancelled {
                return OperationPresentation(title: "Installation cancelled", symbol: "xmark.circle",
                                             phase: "Your existing ADB setup was left unchanged.")
            }
            if session.isFinished {
                return OperationPresentation(title: "Platform Tools installed", symbol: "checkmark.circle.fill",
                                             phase: adbInstallationResultMessage ?? "Choose Check Again when you’re ready to look for your phone.")
            }
            let phase: String
            switch adbInstallationProgress?.phase {
            case .downloading:
                if let progress = adbInstallationProgress,
                   let expected = progress.expectedBytes, expected > 0 {
                    phase = "Downloading · \(UIFormatting.bytes(progress.downloadedBytes)) of \(UIFormatting.bytes(expected))"
                } else { phase = "Downloading Google’s Platform Tools for macOS…" }
            case .extracting: phase = "Unpacking Platform Tools…"
            case .validating: phase = "Checking that ADB runs…"
            case .publishing: phase = "Finishing installation…"
            case nil: phase = "Preparing the download…"
            }
            return OperationPresentation(title: "Installing \(noun)", symbol: "arrow.down.circle",
                                         phase: phase)
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
            case .installADB: phase = "Preparing the Platform Tools download…"
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
        switch self { case .backup: "Backup"; case .restore: "Restore"; case .export: "Export"; case .copy: "Copy"; case .installADB: "Platform Tools" }
    }
}
