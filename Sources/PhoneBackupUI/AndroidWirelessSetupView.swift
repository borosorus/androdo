import PhoneBackupCore
import SwiftUI

/// Explicit Android Wireless debugging pairing and connection. No phone folders are read here.
struct AndroidWirelessSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var ownerID = UUID()
    @State private var pairingAddress = ""
    @State private var pairingPort = ""
    @State private var pairingCode = ""
    @State private var usesPairingAddress = true
    @State private var connectionAddress = ""
    @State private var connectionPort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wifi")
                    .font(.title2)
                    .foregroundStyle(AppIdentity.teal)
                    .frame(width: 42, height: 42)
                    .background(AppIdentity.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect over Wi-Fi").font(.headline)
                    Text("For Android 11 or later. Keep this Mac and your unlocked phone on the same trusted Wi-Fi network.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                stepHeading(number: 1, title: "Pair this Mac")
                Text("On Android, open Settings → System → Developer options → Wireless debugging, then choose Pair device with pairing code (sometimes called Pair new device). Enter the pairing address, port, and code shown on that screen. Settings names vary by phone.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("The six-digit code expires. Androdo uses it for this attempt and doesn’t save it. If pairing is rejected, show a new code on Android and try again.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("IP address", text: $pairingAddress, prompt: Text("192.168.1.25"))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .accessibilityLabel("Pairing IP address")
                    .disabled(model.isBusy)
                HStack(spacing: 10) {
                    TextField("Pairing port", text: $pairingPort, prompt: Text("Port"))
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                        .accessibilityLabel("Pairing port")
                        .disabled(model.isBusy)
                    SecureField("Six-digit pairing code", text: $pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Six-digit Android pairing code")
                        .disabled(model.isBusy)
                        .onChange(of: pairingCode) { _, value in
                            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            if digits != value { pairingCode = digits }
                        }
                }
                HStack {
                    Button {
                        let submittedCode = pairingCode
                        pairingCode = ""
                        model.pairWirelessADB(host: pairingAddress, port: pairingPort, code: submittedCode,
                                              ownerID: ownerID)
                    } label: {
                        Label(pairButtonTitle, systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).controlSize(.large)
                    .disabled(model.isBusy || !canPair)
                    if model.isPairingWireless && !model.isCancellingWireless {
                        Button("Cancel") {
                            pairingCode = ""
                            model.cancelWirelessSetupOperation(ownerID: ownerID)
                        }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)) }

            if let message = model.wirelessSetupMessage {
                Label(message, systemImage: model.wirelessSetupMessageIsError
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(model.wirelessSetupMessageIsError ? AppIdentity.copper : AppIdentity.teal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.wirelessSetupMessageIsError ? AppIdentity.copper : AppIdentity.teal).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 12) {
                stepHeading(number: 2, title: "Connect to the phone")
                Text("Return to Android’s main Wireless debugging screen. Use its address and port here; the connection port is different from the pairing port. If the phone is already paired with this Mac, skip Pair and connect directly.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !pairingAddress.isEmpty {
                    Toggle("Use the same IP address as pairing", isOn: $usesPairingAddress)
                        .toggleStyle(.checkbox)
                        .disabled(model.isBusy)
                }
                if !usesPairingAddress || pairingAddress.isEmpty {
                    TextField("Connection IP address", text: $connectionAddress, prompt: Text("192.168.1.25"))
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        .accessibilityLabel("Connection IP address")
                        .disabled(model.isBusy)
                }
                HStack {
                    TextField("Connection port", text: $connectionPort, prompt: Text("Port"))
                        .textFieldStyle(.roundedBorder).frame(width: 140)
                        .accessibilityLabel("Wireless debugging connection port")
                        .disabled(model.isBusy)
                    Spacer()
                    Button {
                        model.connectWirelessADB(host: connectAddress, port: connectionPort, ownerID: ownerID)
                    } label: {
                        Label(connectButtonTitle, systemImage: "wifi")
                            .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).controlSize(.large)
                    .disabled(model.isBusy || !canConnect)
                    if model.isConnectingWireless && !model.isCancellingWireless {
                        Button("Cancel") {
                            pairingCode = ""
                            model.cancelWirelessSetupOperation(ownerID: ownerID)
                        }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)) }

            DisclosureGroup("Trust, privacy, and connection help") {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Pairing trusts this Mac until you remove it on Android.", systemImage: "lock.shield")
                        .font(.callout.weight(.medium))
                    Text("To revoke trust, open Wireless debugging → Paired devices on your phone and forget this Mac. ADB may automatically find or reconnect to paired phones. Androdo does not run its own network scan; Connect uses the address and port you enter.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Pairing and connection verify phone identity and the ADB route only. Androdo does not list folders or read files until you choose a phone action.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Allow Androdo when macOS 15 or later asks to access your local network. If access was denied, open System Settings → Privacy & Security → Local Network and enable Androdo. Check that both devices are on the same network, Wireless debugging is still on, and the current connection port is entered.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("If USB and Wi-Fi are both connected, Androdo recognizes one phone and prefers USB for transfers. Unplug USB to use Wi-Fi.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("Android Wireless debugging guide…",
                         destination: URL(string: "https://developer.android.com/tools/adb#wireless")!)
                        .font(.callout)
                    Link("Enable Developer options…",
                         destination: URL(string: "https://developer.android.com/studio/debug/dev-options#enable")!)
                        .font(.callout)
                }
                .padding(.top, 9)
            }
            .font(.callout.weight(.medium))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07)) }
        .onChange(of: usesPairingAddress) { _, usePairing in
            if !usePairing && connectionAddress.isEmpty { connectionAddress = pairingAddress }
        }
        .onChange(of: pairingAddress) { _, newAddress in
            if usesPairingAddress || connectionAddress.isEmpty { connectionAddress = newAddress }
        }
        .onDisappear {
            pairingCode = ""
            model.cancelWirelessSetupOperation(ownerID: ownerID)
        }
    }

    private var connectAddress: String {
        usesPairingAddress && !pairingAddress.isEmpty ? pairingAddress : connectionAddress
    }

    private var canPair: Bool {
        (try? ADBWirelessEndpoint(host: pairingAddress, port: pairingPort)) != nil
            && (try? ADBPairingCode(pairingCode)) != nil
    }

    private var canConnect: Bool {
        (try? ADBWirelessEndpoint(host: connectAddress, port: connectionPort)) != nil
    }

    private var pairButtonTitle: String {
        guard model.isPairingWireless else { return "Pair This Mac" }
        return model.isCancellingWireless ? "Cancelling…" : "Pairing…"
    }

    private var connectButtonTitle: String {
        guard model.isConnectingWireless else { return "Connect" }
        return model.isCancellingWireless ? "Cancelling…" : "Connecting…"
    }

    private func stepHeading(number: Int, title: String) -> some View {
        HStack(spacing: 9) {
            Text(number.formatted())
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AppIdentity.blue)
                .frame(width: 25, height: 25)
                .background(AppIdentity.blue.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.callout.weight(.semibold))
        }
    }
}
