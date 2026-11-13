import PhoneBackupCore
import SwiftUI

struct BackupReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review backup").font(.title2.weight(.semibold))
                    Text("Check the scope and changes before copying anything.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start Backup") { Task { await model.startBackup(); dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            if let plan = model.backupPlan {
                HStack(spacing: 12) {
                    metric("Files", value: plan.fileCount, symbol: "doc")
                    metric("Folders", value: plan.directoryCount, symbol: "folder")
                    metric("Transfer", value: plan.transferCount, symbol: "arrow.down.to.line")
                    metric("Reused", value: plan.reusedCount, symbol: "checkmark.icloud")
                }
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    row("Data to transfer", UIFormatting.bytes(plan.bytesToTransfer))
                    row("Data in snapshot", UIFormatting.bytes(plan.totalBytes))
                    row("Previously stored items removed", "\(plan.deletedCount)")
                    row("Device", plan.device.serial)
                    row("Repository", plan.repository.id.uuidString)
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                if !plan.omissions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        MessageBanner(text: "The scan found \(plan.omissions.count) path(s) it could not include. The backup will pause for your choice; it will not silently publish a complete restore point.", symbol: "exclamationmark.triangle", isWarning: true)
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
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 430)
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title2.weight(.semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
