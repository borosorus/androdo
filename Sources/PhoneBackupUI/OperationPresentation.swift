import PhoneBackupCore

public enum OperationKind: Sendable, Equatable { case backup, restore, export, copy }

/// Presentation identity survives completion; cancellation state remains owned by AppModel.
struct OperationPresentation: Equatable {
    let title: String
    let symbol: String
    let phase: String

    init(title: String, symbol: String, phase: String) {
        self.title = title
        self.symbol = symbol
        self.phase = phase
    }

    init(kind: OperationKind?, event: OperationEvent?, isRunning: Bool,
         recovery: BackupAttempt?, pendingCount: Int) {
        let noun: String = switch kind { case .backup: "Backup"; case .restore: "Restore"; case .copy: "Copy"; case .export: "Export"; case nil: "Operation" }
        guard let event else {
            if isRunning {
                title = "Starting \(noun.lowercased())…"
                phase = "Preparing…"
                symbol = "arrow.triangle.2.circlepath"
            } else if let recovery {
                title = recovery.state == .interrupted ? "Backup interrupted" : "Backup incomplete"
                phase = recovery.state == .interrupted ? "Resume the saved progress to continue." : "Review skipped paths before finishing."
                symbol = "exclamationmark.triangle"
            } else {
                title = pendingCount > 0 ? "Unfinished backups" : "Recent operation"
                phase = pendingCount > 0 ? "A previous backup can be resumed below." : ""
                symbol = pendingCount > 0 ? "arrow.clockwise" : "checkmark.circle"
            }
            return
        }
        switch event.phase {
        case .completed:
            title = event.warnings.isEmpty ? "\(noun) complete" : "\(noun) finished with skipped paths"
            phase = event.warnings.isEmpty ? "Verified" : "Review the warning details below."
            symbol = event.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle"
        case .incomplete:
            title = "\(noun) incomplete"
            phase = "Some items were not completed. Review the details before retrying."
            symbol = "exclamationmark.triangle"
        case .failed:
            title = "\(noun) failed"
            phase = event.failure == nil ? "The operation did not finish. Review its results before retrying." : "The operation stopped because of the error below."
            symbol = "exclamationmark.triangle"
        case .cancelled:
            title = "\(noun) cancelled"
            phase = "Previously completed data remains available."
            symbol = "xmark.circle"
        case .scanning, .planning, .transferring, .verifying, .committing:
            title = switch kind { case .backup: "Backing up"; case .restore: "Restoring files"; case .copy: "Copying files"; case .export: "Exporting files"; case nil: "Working…" }
            phase = switch event.phase {
            case .scanning: "Scanning selected files…"
            case .planning: "Checking destinations…"
            case .transferring: "Copying files…"
            case .verifying: "Verifying files…"
            case .committing: "Finishing…"
            default: "Working…"
            }
            symbol = "arrow.triangle.2.circlepath"
        }
    }
}
