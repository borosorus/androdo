import PhoneBackupCore
import SwiftUI

@main
struct PhoneBackupApp: App {
    var body: some Scene {
        WindowGroup(PhoneBackupCore.applicationName) {
            MainWindow()
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 960, height: 640)
    }
}

private enum SidebarSection: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case backups = "Backups"
    case activity = "Activity"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .devices: "iphone"
        case .backups: "externaldrive"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

private struct MainWindow: View {
    @State private var selection = SidebarSection.devices

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle(PhoneBackupCore.applicationName)
        } detail: {
            ContentUnavailableView(
                selection.rawValue,
                systemImage: selection.symbol,
                description: Text("Connect an Android device to get started.")
            )
            .navigationTitle(selection.rawValue)
        }
    }
}
