import PhoneBackupCore
import SwiftUI

struct OperationProgressDetails: View {
    @Environment(AppModel.self) private var model
    @Binding var showingOmissionConfirmation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failure = model.progressSession?.failure {
                MessageBanner(text: failure, symbol: "exclamationmark.triangle", isWarning: true)
            }
            if model.progressSession?.kind == .installADB,
               model.progressSession?.failure == nil,
               let message = model.adbInstallationResultMessage {
                MessageBanner(text: message, symbol: "checkmark.circle", isWarning: false)
            }
            if !isADBInstallation, showsOperationDetails, let event = model.operationEvent {
                if let failure = event.failure {
                    MessageBanner(text: failureMessage(failure), symbol: "exclamationmark.triangle", isWarning: true)
                }
            }
            if !isADBInstallation, showsOperationDetails, let event = model.operationEvent, !event.warnings.isEmpty {
                DisclosureGroup("Warning details (\(event.warnings.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(event.warnings) { warning in
                                VStack(alignment: .leading, spacing: 3) {
                                    if let path = warning.path { Text(path.description).textSelection(.enabled) }
                                    Text(warning.message).foregroundStyle(.secondary).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.font(.callout)
                    }.frame(maxHeight: 110)
                }
            }
            if !isADBInstallation, (model.progressSession == nil || model.progressSession?.isFinished == true),
               model.recoveryAttempt != nil || !model.pendingAttempts.isEmpty {
                ScrollView { recoveryContent }.frame(maxHeight: 170)
            }
            if !isADBInstallation, showsOperationDetails, let result = model.restoreResult {
                Text("Restore result: \(result.items.filter { $0.state == .publishedAndVerified }.count) verified, \(result.items.filter { $0.state != .publishedAndVerified }.count) need attention.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !isADBInstallation, showsOperationDetails, let result = model.copyResult {
                Text("Copy result: \(result.items.filter { $0.state == .publishedAndVerified }.count) verified, \(result.items.filter { $0.state != .publishedAndVerified }.count) need attention.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureMessage(_ error: EngineError) -> String {
        if model.operationKind == .restore, case .safeNoOverwriteUnavailable(let path) = error {
            return "Android cannot create \(path.description) with safe no-overwrite publication. To continue, start a new restore and choose “Replace files in this restore”. Review the batch before confirming."
        }
        return UserFacingError.message(for: error)
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let attempt = model.recoveryAttempt {
                MessageBanner(text: attempt.state == .interrupted
                              ? "This backup was interrupted. \(attempt.checkpointCount) items were saved; resume to continue."
                              : "\(attempt.omissions.count) paths could not be saved. Review them, retry, or explicitly finish with omissions.", symbol: "exclamationmark.triangle", isWarning: true)
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

    private var showsOperationDetails: Bool {
        guard let session = model.progressSession else { return true }
        return (session.stage == .running || session.stage == .finished) && session.failure == nil && !session.wasCancelled
    }

    private var isADBInstallation: Bool { model.progressSession?.kind == .installADB }
}

/// Compact background presentation. Detailed results and recovery remain in the progress window.
struct OperationStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: model.progressPresentation.symbol)
                .font(.title3).foregroundStyle(AppIdentity.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.progressPresentation.title).font(.callout.weight(.semibold))
                Text(model.progressPresentation.phase).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if model.canCancelProgress {
                Button("Cancel") { Task { await model.cancelProgress() } }
            }
            Button(model.progressSession?.isFinished == true ? "Show Details" : "Show Progress") { model.showProgress() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
