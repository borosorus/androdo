import PhoneBackupCore
import SwiftUI

struct OperationStatusView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingOmissionConfirmation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.operationTitle ?? "Backup needs attention", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                Spacer()
                if model.isOperationRunning {
                    Button("Cancel", role: .cancel) { Task { await model.cancelOperation() } }
                        .disabled(model.operationEvent?.phase.isTerminal == true)
                } else if model.recoveryAttempt == nil && model.operationEvent?.phase.isTerminal == true {
                    Button("Dismiss") { model.clearStatus() }.keyboardShortcut(.cancelAction)
                }
            }
            if let event = model.operationEvent {
                HStack(spacing: 12) {
                    if event.phase.isTerminal {
                        Image(systemName: event.phase == .completed && event.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(event.phase == .completed && event.warnings.isEmpty ? AppIdentity.teal : Color.secondary)
                    } else if event.phase == .scanning || event.phase == .planning {
                        ProgressView().controlSize(.small)
                    } else if let total = event.progress.totalBytes, total > 0 {
                        ProgressView(value: Double(event.progress.completedBytes), total: Double(total)).frame(maxWidth: 220)
                    } else if let total = event.progress.totalItems, total > 0 {
                        ProgressView(value: Double(event.progress.completedItems), total: Double(total)).frame(maxWidth: 220)
                    } else { ProgressView().controlSize(.small) }
                    Text(phaseLabel(event.phase)).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if event.progress.totalItems != nil || event.progress.completedItems > 0 {
                        Text("\(event.progress.completedItems) / \(event.progress.totalItems.map(String.init) ?? "…") items · \(UIFormatting.bytes(event.progress.completedBytes))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let failure = event.failure {
                    MessageBanner(text: UserFacingError.message(for: failure), symbol: "exclamationmark.triangle", isWarning: true)
                }
            }
            if model.recoveryAttempt != nil || !model.pendingAttempts.isEmpty {
                ScrollView { recoveryContent }.frame(maxHeight: 170)
            }
            if let result = model.restoreResult {
                Text("Restore result: \(result.items.filter { $0.state == .publishedAndVerified }.count) verified, \(result.items.filter { $0.state != .publishedAndVerified }.count) need attention.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let result = model.copyResult {
                Text("Copy result: \(result.items.filter { $0.state == .publishedAndVerified }.count) verified, \(result.items.filter { $0.state != .publishedAndVerified }.count) need attention.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let attempt = model.recoveryAttempt {
                MessageBanner(text: "Backup incomplete · \(attempt.omissions.count) paths need attention.", symbol: "exclamationmark.triangle", isWarning: true)
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
                        .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).disabled(model.isBusy)
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
                                .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).disabled(model.isBusy)
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
        }.frame(maxWidth: .infinity, alignment: .leading)
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
        case .completed: model.operationEvent?.warnings.isEmpty == false ? "Finished with skipped paths" : "Verified"
        case .incomplete: "Incomplete"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}
