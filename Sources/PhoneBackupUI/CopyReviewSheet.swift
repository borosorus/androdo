import PhoneBackupCore
import SwiftUI

struct CopyReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var approvedConflicts: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review file copy").font(.title2.weight(.semibold))
                    Text("The copy starts only after you confirm this plan.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelCopyReview(); dismiss() }
                    .disabled(model.isStartingOperation)
                Button("Copy") { Task { await model.startCopy(replacing: approvedConflicts) } }
                    .buttonStyle(.borderedProminent).disabled(!canCopy || model.isStartingOperation).keyboardShortcut(.defaultAction)
            }
            if let plan = model.copyPlan {
                if let notice = model.statusMessage { MessageBanner(text: notice, symbol: "exclamationmark.triangle", isWarning: true) }
                HStack(spacing: 12) {
                    metric("Files", plan.fileCount, "doc")
                    metric("Folders", plan.directoryCount, "folder")
                    metric("Total", UIFormatting.bytes(plan.totalBytes), "externaldrive")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Destination preview").font(.headline)
                    ForEach(plan.mappings.prefix(12)) { mapping in
                        HStack(spacing: 8) {
                            Image(systemName: mapping.kind == .directory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(sourceName(mapping.source)).lineLimit(1)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(UIFormatting.destination(mapping.destination)).lineLimit(1).textSelection(.enabled)
                        }.font(.callout)
                    }
                    if plan.mappings.count > 12 { Text("and \(plan.mappings.count - 12) more items").font(.caption).foregroundStyle(.secondary) }
                }
                if !plan.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Existing destination items").font(.headline)
                        Text("Nothing is replaced unless you approve each conflict below.")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(plan.conflicts) { conflict in
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
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 460)
        .interactiveDismissDisabled(model.isStartingOperation)
        .onChange(of: model.copyPlan?.id) { _, _ in approvedConflicts = [] }
    }

    private var canCopy: Bool {
        guard let plan = model.copyPlan, !plan.mappings.isEmpty,
              !plan.conflicts.contains(where: { !$0.replaceable }) else { return false }
        return plan.conflicts.allSatisfy { approvedConflicts.contains($0.id) }
    }

    private func metric(_ title: String, _ value: Int, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title2.weight(.semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceName(_ source: CopySource) -> String {
        switch source {
        case .phone(let entry): entry.path.description
        case .local(let url): url.lastPathComponent
        }
    }
}
