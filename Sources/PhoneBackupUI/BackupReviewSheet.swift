import PhoneBackupCore
import SwiftUI

struct BackupReviewSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ReviewSheetLayout(title: "Review Backup",
                          subtitle: "Check the scope and changes before creating this restore point.",
                          minimumWidth: 640, minimumHeight: 430) {
            if let plan = model.backupPlan {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        SummaryMetric("Files", value: plan.fileCount, symbol: "doc")
                        SummaryMetric("Folders", value: plan.directoryCount, symbol: "folder")
                        SummaryMetric("To copy", value: plan.transferCount, symbol: "arrow.down.to.line")
                        SummaryMetric("Already saved", value: plan.reusedCount, symbol: "checkmark.icloud")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        row("Data to transfer", UIFormatting.bytes(plan.bytesToTransfer))
                        row("Data in restore point", UIFormatting.bytes(plan.totalBytes))
                        row("Items removed from this snapshot", "\(plan.deletedCount)")
                        row("Device", model.selectedDevice?.model ?? plan.device.serial)
                        row("Backup folder", model.backupLocation?.lastPathComponent ?? "Unavailable")
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    if !plan.omissions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            MessageBanner(text: "The scan found \(plan.omissions.count) path(s) it could not include. The backup will pause for your choice and cannot be marked complete without it.", symbol: "exclamationmark.triangle", isWarning: true)
                            DisclosureGroup("Paths that need attention") {
                                ForEach(plan.omissions) { warning in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(warning.path?.description ?? "Unavailable path").textSelection(.enabled)
                                        Text(warning.message).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                                }
                            }
                        }
                    }
                }
            }
        } footer: {
            Button("Cancel") { model.cancelBackupReview() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isStartingOperation)
            Button {
                Task { await model.startBackup() }
            } label: {
                if model.isStartingOperation { ProgressView().controlSize(.small); Text("Starting…") }
                else { Text("Start Backup") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.backupPlan == nil || model.isStartingOperation)
        }
        .interactiveDismissDisabled(model.isStartingOperation)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
