import SwiftUI

/// Focused connection guidance. ADB installation lives in its own destination.
struct ConnectionSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var method: ConnectionMethod = .usb
    @State private var showingADBTools = false

    var body: some View {
        ReviewSheetLayout(title: "Connect your Android",
                          subtitle: "Choose a connection method and follow the steps for your phone.",
                          minimumWidth: 620, minimumHeight: 530) {
            VStack(alignment: .leading, spacing: 16) {
                adbStatus

                if let error = model.errorMessage {
                    MessageBanner(text: error, symbol: "exclamationmark.triangle", isWarning: true)
                }

                if model.canUseWirelessADB {
                    Picker("Connection method", selection: $method) {
                        Label("USB", systemImage: "cable.connector").tag(ConnectionMethod.usb)
                        Label("Wi-Fi", systemImage: "wifi").tag(ConnectionMethod.wifi)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Connection method")
                }

                if method == .wifi, model.canUseWirelessADB {
                    AndroidWirelessSetupView()
                } else {
                    AndroidConnectionGuide(hasADB: model.hasADB,
                                           deviceState: model.connectionGuideDeviceState,
                                           discoveryIssue: model.connectionGuideDiscoveryIssue)
                }

                Text("Connecting checks the phone only. Choose Open Shared Storage in File Explorer when you’re ready to browse files.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            Button {
                Task { await model.recheckADB() }
            } label: {
                if model.isRefreshingDevices { ProgressView().controlSize(.small); Text("Checking…") }
                else { Text("Check Again") }
            }
            .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
            .disabled(model.isBusy)
        }
        .sheet(isPresented: $showingADBTools) { ADBToolsView() }
    }

    private var adbStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: model.hasADB ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                .font(.title3)
                .foregroundStyle(model.hasADB ? AppIdentity.teal : AppIdentity.copper)
                .frame(width: 36, height: 36)
                .background((model.hasADB ? AppIdentity.teal : AppIdentity.copper).opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasADB ? "ADB is ready" : "ADB is needed to connect")
                    .font(.callout.weight(.semibold))
                Text(model.hasADB ? "Android Platform Tools are available on this Mac." : "Set up Android Platform Tools before checking for your phone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(model.hasADB ? "ADB Tools…" : "Set Up ADB…") { showingADBTools = true }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private enum ConnectionMethod: Hashable {
        case usb
        case wifi
    }
}
