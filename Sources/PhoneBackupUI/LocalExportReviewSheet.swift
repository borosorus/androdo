import PhoneBackupCore
import SwiftUI

struct LocalExportReviewSheet: View {
    @Environment(AppModel.self) private var model
    @State private var approvedConflicts: Set<UUID> = []

    var body: some View {
        ReviewSheetLayout(title: model.restorePlanTitle,
                          subtitle: "Check the destination and approve any replacements before writing.",
                          minimumWidth: 620, minimumHeight: 430) {
            if let plan = model.restorePlan {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice = model.statusMessage {
                        MessageBanner(text: notice, symbol: "exclamationmark.triangle", isWarning: true)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        row("Files", "\(plan.fileCount)")
                        row("Folders", "\(plan.directoryCount)")
                        row("Total data", UIFormatting.bytes(plan.totalBytes))
                        row("Destination", plan.mappings.first.map { UIFormatting.destination($0.destination) } ?? "Unavailable")
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    if !plan.sourceOmissions.isEmpty {
                        MessageBanner(text: "The selected restore point records \(plan.sourceOmissions.count) omitted path(s).", symbol: "exclamationmark.triangle", isWarning: true)
                    }
                    if !plan.conflicts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Destination conflicts").font(.headline)
                            Text("Existing items stay untouched unless you approve replacing them below.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(plan.conflicts) { conflict in
                                if conflict.replaceable {
                                    Toggle(isOn: Binding(get: { approvedConflicts.contains(conflict.id) }, set: { value in
                                        if value { approvedConflicts.insert(conflict.id) } else { approvedConflicts.remove(conflict.id) }
                                    })) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(UIFormatting.destination(conflict.destination)).lineLimit(2).textSelection(.enabled)
                                            Text("Replace existing \(conflict.kind == .fileExists ? "file" : "folder")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.toggleStyle(.checkbox)
                                } else {
                                    Label("Cannot safely replace \(UIFormatting.destination(conflict.destination))", systemImage: "hand.raised.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    if !plan.mappings.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Planned destinations").font(.headline)
                            ForEach(plan.mappings.prefix(8)) { mapping in
                                HStack {
                                    Image(systemName: mapping.source.kind == .directory ? "folder" : "doc")
                                        .foregroundStyle(.secondary)
                                    Text(mapping.source.path.description).lineLimit(1)
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                    Text(UIFormatting.destination(mapping.destination)).lineLimit(1).textSelection(.enabled)
                                }.font(.callout)
                            }
                            if plan.mappings.count > 8 {
                                Text("and \(plan.mappings.count - 8) more items").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if plan.mappings.isEmpty { ContentUnavailableView("Nothing to restore", systemImage: "doc.questionmark") }
                }
            }
        } footer: {
            Button("Cancel") { model.cancelExportReview() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isStartingOperation)
            Button {
                Task { await model.startRestore(replacing: approvedConflicts) }
            } label: {
                if model.isStartingOperation { ProgressView().controlSize(.small); Text("Starting…") }
                else { Text(model.restoreTargetIsPhone ? "Restore to Phone" : "Export") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExport || model.isStartingOperation)
            .keyboardShortcut(.defaultAction)
        }
        .interactiveDismissDisabled(model.isStartingOperation)
        .onChange(of: model.restorePlan?.id) { _, _ in approvedConflicts = [] }
    }

    private var canExport: Bool {
        guard let plan = model.restorePlan, !plan.mappings.isEmpty,
              !plan.conflicts.contains(where: { !$0.replaceable }) else { return false }
        return plan.conflicts.filter(\.replaceable).allSatisfy { approvedConflicts.contains($0.id) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
