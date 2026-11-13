import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            AppPageHeader(title: "Recent Operations")
            Divider()
            if model.activityStore.records.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath", description: Text("Backups, restores, and copies appear here while the app is open."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.activityStore.records) { record in
                    HStack(spacing: 14) {
                        Image(systemName: symbol(for: record))
                            .font(.title3).foregroundStyle(color(for: record))
                            .frame(width: 38, height: 38).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.kind.rawValue).font(.headline)
                                Text(record.outcome.rawValue.capitalized)
                                    .font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(color(for: record).opacity(0.12), in: Capsule())
                            }
                            if record.outcome != .completed, !record.safeSummary.isEmpty {
                                Text(record.safeSummary).font(.callout).foregroundStyle(.secondary)
                            }
                            Text("\(record.verifiedItems) verified · \(record.warningCount) warnings")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }
    }

    private func symbol(for record: ActivityRecord) -> String {
        switch record.kind {
        case .backup: "arrow.down.to.line"
        case .restore: "arrow.uturn.backward"
        case .copy: "doc.on.doc"
        }
    }

    private func color(for record: ActivityRecord) -> Color {
        switch record.outcome {
        case .running: .accentColor
        case .completed: .green
        case .incomplete: .orange
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}


struct RecentOperationsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ActivityView()
            Divider()
            HStack {
                Text("This session only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear Finished") { model.activityStore.clearFinished() }
                    .disabled(model.activityStore.records.allSatisfy { $0.outcome == .running })
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
        }
        .frame(minWidth: 620, minHeight: 420)
        .controlSize(.large)
    }
}
