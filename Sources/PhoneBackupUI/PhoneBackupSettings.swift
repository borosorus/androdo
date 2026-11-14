import PhoneBackupCore
import SwiftUI

public struct PhoneBackupSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showingConnectionSetup = false
    @State private var showingADBTools = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppEmblem().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PhoneBackupCore.applicationName).font(.title2.weight(.semibold))
                        Text("Local backups for Android files").foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · \(Bundle.main.object(forInfoDictionaryKey: "AndrodoBuild") as? String ?? "Source build")")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(.vertical, 8)
            }
            Section("Android connection") {
                if let error = model.errorMessage {
                    MessageBanner(text: error, symbol: "exclamationmark.triangle", isWarning: true)
                }
                LabeledContent("ADB") {
                    Text(model.hasADB ? "Configured" : "Not configured")
                        .foregroundStyle(.secondary)
                }
                if let url = model.adbExecutableURL {
                    Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Connection Setup…") { showingConnectionSetup = true }
                        .disabled(model.isBusy)
                    Button("ADB Tools…") { showingADBTools = true }
                        .disabled(model.isBusy)
                }
                Text("Android Platform Tools provides the connection to your phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 430)
        .tint(AppIdentity.blue)
        .sheet(isPresented: $showingConnectionSetup) { ConnectionSetupView() }
        .sheet(isPresented: $showingADBTools) { ADBToolsView() }
    }
}
