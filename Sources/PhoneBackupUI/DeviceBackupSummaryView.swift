import PhoneBackupCore
import SwiftUI

struct DeviceBackupSummaryView: View {
    let state: DeviceBackupSummaryState
    var canRetry = true
    var retry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch state {
            case .noDevice: EmptyView()
            case .noLocation: Text("No backup folder selected").font(.callout).foregroundStyle(.secondary)
            case .loading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking backup history…").font(.callout).foregroundStyle(.secondary)
                }
            case .unavailable:
                Text("Backup history unavailable").font(.callout).foregroundStyle(.secondary)
                Button("Retry") { retry() }.disabled(!canRetry)
            case .loaded(let summary):
                if let point = summary.latestComplete {
                    Text("Latest complete backup").font(.caption).foregroundStyle(.secondary)
                    Text(point.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    Text("\(point.entryCount) items · \(UIFormatting.bytes(point.totalBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(summary.points.isEmpty ? "No backups yet" : "No complete backup yet").font(.headline)
                }
                if let incomplete = summary.latestIncomplete,
                   incomplete.createdAt > (summary.latestComplete?.createdAt ?? .distantPast) {
                    Label(incomplete.omissions.isEmpty ? "Latest backup incomplete" : "Latest backup incomplete · \(incomplete.omissions.count) paths skipped",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

