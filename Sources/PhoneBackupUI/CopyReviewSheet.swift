import PhoneBackupCore
import SwiftUI

struct CopyReviewSheet: View {
    @Environment(AppModel.self) private var model
    @State private var approvedConflicts: Set<UUID> = []

    var body: some View {
        ReviewSheetLayout(title: "Review File Copy",
                          subtitle: "The copy starts only after you confirm this plan.",
                          minimumWidth: 700, minimumHeight: 460) {
            if let plan = model.copyPlan {
                VStack(alignment: .leading, spacing: 18) {
                    if let notice = model.statusMessage {
                        MessageBanner(text: notice, symbol: "exclamationmark.triangle", isWarning: true)
                    }
                    HStack(spacing: 12) {
                        SummaryMetric("Files", value: plan.fileCount, symbol: "doc")
                        SummaryMetric("Folders", value: plan.directoryCount, symbol: "folder")
                        SummaryMetric("Total", value: UIFormatting.bytes(plan.totalBytes), symbol: "externaldrive")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination preview").font(.headline)
                        ForEach(plan.mappings.prefix(12)) { mapping in
                            HStack(spacing: 8) {
                                Image(systemName: mapping.kind == .directory ? "folder" : "doc").foregroundStyle(.secondary)
                                Text(sourceName(mapping.source)).lineLimit(1)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(UIFormatting.destination(mapping.destination)).lineLimit(1).textSelection(.enabled)
                            }.font(.callout)
                        }
                        if plan.mappings.count > 12 {
                            Text("and \(plan.mappings.count - 12) more items").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    conflictList(plan.conflicts)
                }
            }
        } footer: {
            Button("Cancel") { model.cancelCopyReview() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isStartingOperation)
            Button {
                Task { await model.startCopy(replacing: approvedConflicts) }
            } label: {
                if model.isStartingOperation { ProgressView().controlSize(.small); Text("Starting…") }
                else { Text("Copy") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCopy || model.isStartingOperation)
            .keyboardShortcut(.defaultAction)
        }
        .interactiveDismissDisabled(model.isStartingOperation)
        .onChange(of: model.copyPlan?.id) { _, _ in approvedConflicts = [] }
    }

    private func conflictList(_ conflicts: [RestoreConflict]) -> some View {
        Group {
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Existing destination items").font(.headline)
                    Text("Nothing is replaced unless you approve each item below.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(conflicts) { conflict in
                        if conflict.replaceable {
                            Toggle(isOn: Binding(get: { approvedConflicts.contains(conflict.id) }, set: { value in
                                if value { approvedConflicts.insert(conflict.id) } else { approvedConflicts.remove(conflict.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(UIFormatting.destination(conflict.destination)).lineLimit(2).textSelection(.enabled)
                                    Text("Replace existing destination item").font(.caption).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        } else {
                            Label("Cannot safely replace \(UIFormatting.destination(conflict.destination))", systemImage: "hand.raised.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var canCopy: Bool {
        guard let plan = model.copyPlan, !plan.mappings.isEmpty,
              !plan.conflicts.contains(where: { !$0.replaceable }) else { return false }
        return plan.conflicts.allSatisfy { approvedConflicts.contains($0.id) }
    }

    private func sourceName(_ source: CopySource) -> String {
        switch source {
        case .phone(let entry): entry.path.description
        case .local(let url): url.lastPathComponent
        }
    }
}
