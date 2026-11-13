import SwiftUI

struct DeviceBackupHero<Summary: View, Action: View>: View {
    let name: String
    let status: String
    let connected: Bool
    @ViewBuilder let summary: () -> Summary
    @ViewBuilder let action: () -> Action

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                DeviceIllustration(connected: connected)
                VStack(alignment: .leading, spacing: 20) {
                    identity
                    summary()
                }.frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
                action().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 20) {
                    DeviceIllustration(connected: connected)
                    identity
                }
                summary()
                action()
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(name).font(.system(size: 27, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Label {
                Text(status).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: connected ? "circle.fill" : "cable.connector")
                    .font(connected ? .system(size: 6) : .callout)
                    .foregroundStyle(connected ? AppIdentity.teal : Color.secondary)
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}


struct OverviewSettingRow<Content: View, Action: View>: View {
    let title: String
    let symbol: String
    var color = AppIdentity.blue
    @ViewBuilder let content: () -> Content
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol).font(.title2).symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                content().font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            action()
        }
        .padding(18)
    }
}

/// Uses only fictional, local presentation data, never a live AppModel.
struct OverviewDesignPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DeviceBackupHero(name: "Pixel 9", status: "Connected by USB", connected: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest complete backup").font(.caption).foregroundStyle(.secondary)
                    Text("Today, 10:42").font(.headline)
                    Text("128 items · 842 MB").font(.caption).foregroundStyle(.secondary)
                }
            } action: {
                Button("Back Up…") {}.buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
            }
            VStack(spacing: 0) {
                OverviewSettingRow(title: "Back up to", symbol: "externaldrive.fill") {
                    Text("Android Backups · External drive")
                } action: { Button("Change…") {} }
                Divider().padding(.leading, 72)
                OverviewSettingRow(title: "Included folders", symbol: "folder.fill", color: AppIdentity.teal) {
                    Text("Pictures, Documents · 2 folders")
                } action: { Button("Choose…") {} }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(AppIdentity.copper)
                Text("Backup history").font(.callout.weight(.medium))
                Spacer()
                Button("Browse Backups") {}
            }.padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(width: 790, height: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(AppIdentity.blue)
        .controlSize(.large)
    }
}
