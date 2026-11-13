import PhoneBackupCore
import PhoneBackupUI
import SwiftUI

@main
struct PhoneBackupApp: App {
    @State private var model: AppModel

    init() {
        let preferences = AppPreferences()
        let savedADB = preferences.adbExecutablePath.map { URL(fileURLWithPath: $0) }
        _model = State(initialValue: AppModel(services: .live(adbExecutable: savedADB), preferences: preferences))
    }

    var body: some Scene {
        WindowGroup(PhoneBackupCore.applicationName) {
            MainWindow()
                .environment(model)
                .environment(model.fileBrowser)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 760)

        Settings {
            PhoneBackupSettings().environment(model)
        }
    }
}
