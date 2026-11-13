import SwiftUI

struct DeviceBackupHero<Action: View>: View {
    let name: String
    let status: String
    let connected: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 28) {
            DeviceIllustration(connected: connected)
            VStack(alignment: .leading, spacing: 14) {
                Text("YOUR ANDROID").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                Text(name).font(.system(size: 30, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                Label {
                    Text(status).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: connected ? "checkmark.circle.fill" : "cable.connector")
                        .foregroundStyle(connected ? AppIdentity.teal : Color.secondary)
                }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.background)
                .overlay(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(LinearGradient(colors: [AppIdentity.teal.opacity(0.06), .clear], startPoint: .topTrailing, endPoint: .bottomLeading))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.06)) }
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
            DeviceBackupHero(name: "Pixel 9", status: "Connected", connected: true) {
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
