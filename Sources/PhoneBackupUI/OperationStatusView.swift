import PhoneBackupCore
import SwiftUI

struct OperationStatusView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingOmissionConfirmation: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(model.operationTitle ?? (model.pendingAttempts.isEmpty ? "Backup needs attention" : "Unfinished backups"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Spacer()
                    if model.isOperationRunning {
                        Button("Cancel", role: .cancel) { Task { await model.cancelOperation() } }
                            .disabled(model.operationEvent?.phase.isTerminal == true)
                    }
                }
                if let event = model.operationEvent {
                    HStack(spacing: 10) {
                        if event.phase == .scanning || event.phase == .planning { ProgressView().controlSize(.small) }
                        else if let total = event.progress.totalBytes, total > 0 {
                            ProgressView(value: Double(event.progress.completedBytes), total: Double(total))
                        } else if let total = event.progress.totalItems, total > 0 {
                            ProgressView(value: Double(event.progress.completedItems), total: Double(total))
                        } else { ProgressView() }
                        Text(phaseLabel(event.phase)).foregroundStyle(.secondary)
                    }
                    if event.progress.totalItems != nil || event.progress.completedItems > 0 {
                        Text("\(event.progress.completedItems) of \(event.progress.totalItems.map(String.init) ?? "…") items · \(UIFormatting.bytes(event.progress.completedBytes)) transferred")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let failure = event.failure { MessageBanner(text: UserFacingError.message(for: failure), symbol: "exclamationmark.triangle", isWarning: true) }
                }
                if let attempt = model.recoveryAttempt {
                    MessageBanner(text: "This backup is incomplete. \(attempt.omissions.count) path(s) need attention before a restore point can be finished.", symbol: "exclamationmark.triangle", isWarning: true)
                    if !model.recoveryWarnings.isEmpty {
                        DisclosureGroup("Skipped paths (\(model.recoveryWarnings.count))") {
                            ForEach(model.recoveryWarnings) { warning in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(warning.path?.description ?? warning.message).font(.callout).textSelection(.enabled)
                                    if warning.path != nil { Text(warning.message).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                            }
                        }
                    }
                    HStack {
                        Button(attempt.state == .interrupted ? "Resume backup" : "Retry skipped paths") { Task { await model.retryBackup() } }
                            .buttonStyle(.borderedProminent).disabled(model.isBusy)
                        if attempt.state == .needsOmissionDecision {
                            Button("Finish with omissions…", role: .destructive) { showingOmissionConfirmation = true }
                                .disabled(model.isBusy)
                        }
                    }
                }
                let recoverable = model.pendingAttempts.filter { $0.id != model.recoveryAttempt?.id }
                if !recoverable.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Unfinished backups").font(.headline)
                        ForEach(recoverable) { attempt in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attempt.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                                    Text("\(attempt.checkpointCount) saved checkpoints · \(attempt.omissions.count) skipped paths")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Resume") { Task { await model.retryBackup(attempt) } }
                                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
                                if attempt.state == .needsOmissionDecision {
                                    Button("Finish with omissions…", role: .destructive) {
                                        model.prepareToFinishBackup(attempt)
                                        showingOmissionConfirmation = true
                                    }.disabled(model.isBusy)
                                }
                            }
                        }
                    }
                }
                if let result = model.restoreResult {
                    Text("Restore result: \(result.items.filter { $0.state == .publishedAndVerified }.count) verified, \(result.items.filter { $0.state != .publishedAndVerified }.count) need attention.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let result = model.copyResult {
                    Text("Copy result: \(result.items.filter { $0.state == .publishedAndVerified }.count) verified, \(result.items.filter { $0.state != .publishedAndVerified }.count) need attention.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !model.isOperationRunning && model.recoveryAttempt == nil && model.operationEvent?.phase.isTerminal == true {
                    HStack { Spacer(); Button("Dismiss") { model.clearStatus() }.keyboardShortcut(.cancelAction) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }

    private func phaseLabel(_ phase: OperationPhase) -> String {
        switch phase {
        case .scanning: "Scanning files…"
        case .planning:
            if model.operationTitle?.localizedCaseInsensitiveContains("restore") == true || model.operationTitle?.localizedCaseInsensitiveContains("export") == true { "Checking restore destinations…" }
            else if model.operationTitle?.localizedCaseInsensitiveContains("copy") == true { "Planning file copy…" }
            else { "Preparing backup…" }
        case .transferring:
            if model.operationTitle?.localizedCaseInsensitiveContains("copy") == true { "Copying files…" }
            else if model.operationTitle?.localizedCaseInsensitiveContains("restore") == true { "Restoring files to Android…" }
            else { "Copying files from device…" }
        case .verifying: "Verifying files…"
        case .committing:
            if model.operationTitle?.localizedCaseInsensitiveContains("backup") == true { "Finishing restore point…" }
            else { "Publishing verified files…" }
        case .completed: "Operation completed and verified."
        case .incomplete: "Operation incomplete. Review the outcome below."
        case .cancelled: "Operation cancelled."
        case .failed: "Operation failed. Review the message below."
        }
    }
}
