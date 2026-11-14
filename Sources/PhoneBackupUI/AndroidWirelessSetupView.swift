import PhoneBackupCore
import SwiftUI

/// Explicit Android Wireless debugging pairing and connection. No phone folders are read here.
struct AndroidWirelessSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var ownerID = UUID()
    @State private var task: WirelessTask = .pair
    @State private var feedbackTask: WirelessTask?
    @State private var pairingAddress = ""
    @State private var pairingPort = ""
    @State private var pairingCode = ""
    @State private var usesPairingAddress = true
    @State private var connectionAddress = ""
    @State private var connectionPort = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .font(.title3).foregroundStyle(AppIdentity.teal)
                    .frame(width: 34, height: 34)
                    .background(AppIdentity.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wi-Fi debugging").font(.headline)
                    Text("Android 11 or later · Same trusted Wi-Fi network")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Picker("Wireless action", selection: $task) {
                Label("Pair this Mac", systemImage: "link").tag(WirelessTask.pair)
                Label("Connect", systemImage: "wifi").tag(WirelessTask.connect)
            }
            .pickerStyle(.segmented)
            .disabled(model.isBusy)
            .accessibilityLabel("Wireless setup action")

            Text(task == .pair
                 ? "First time on this Mac? Pair it with the code shown on your phone."
                 : "Already paired with this Mac? Connect using the current Wireless debugging address and port.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                switch task {
                case .pair: pairingForm
                case .connect: connectionForm
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 13))
            .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(.primary.opacity(0.07)) }

            if feedbackTask == task, let message = model.wirelessSetupMessage {
                Label(message, systemImage: model.wirelessSetupMessageIsError
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(model.wirelessSetupMessageIsError ? AppIdentity.copper : AppIdentity.teal)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((model.wirelessSetupMessageIsError ? AppIdentity.copper : AppIdentity.teal).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
            }

            DisclosureGroup("Trust, privacy, and connection help") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("On your phone, open Settings → System → Developer options → Wireless debugging. Pairing uses the temporary endpoint and six-digit code from Pair device with pairing code. The code expires and Androdo clears it after use.")
                    Text("After pairing, return to the main Wireless debugging screen. Connect uses its current address and a different port. If this Mac is already paired, skip Pair and connect directly.")
                    Text("Pairing trusts this Mac until you forget it under Wireless debugging → Paired devices. Androdo does not scan the network; Connect uses the address you enter. ADB may automatically reconnect to phones already paired with this Mac.")
                    Text("Pairing and connection verify the phone and ADB route only. Androdo does not list folders or read files until you choose a phone action. If macOS asks, allow Androdo under System Settings → Privacy & Security → Local Network.")
                    Text("When USB and Wi-Fi are both connected, Androdo recognizes one phone and prefers USB for transfers. Unplug USB to use Wi-Fi.")
                    Link("Android Wireless debugging guide…",
                         destination: URL(string: "https://developer.android.com/tools/adb#wireless")!)
                    Link("Enable Developer options…",
                         destination: URL(string: "https://developer.android.com/studio/debug/dev-options#enable")!)
                }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
            .font(.callout.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: task) { _, newTask in
            if newTask != .pair { pairingCode = "" }
            feedbackTask = nil
        }
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

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On Android, choose Pair device with pairing code in Wireless debugging settings.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField("IP address", text: $pairingAddress, prompt: Text("192.168.1.25"))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .accessibilityLabel("Pairing IP address")
                    .disabled(model.isBusy)
                TextField("Pairing port", text: $pairingPort, prompt: Text("Port"))
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                    .accessibilityLabel("Pairing port")
                    .disabled(model.isBusy)
            }
            SecureField("Six-digit pairing code", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Six-digit Android pairing code")
                .disabled(model.isBusy)
                .onChange(of: pairingCode) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    if digits != value { pairingCode = digits }
                }
            HStack {
                Spacer()
                if model.isPairingWireless && !model.isCancellingWireless {
                    Button("Cancel") {
                        pairingCode = ""
                        feedbackTask = .pair
                        model.cancelWirelessSetupOperation(ownerID: ownerID)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                }
                Button {
                    let submittedCode = pairingCode
                    pairingCode = ""
                    feedbackTask = .pair
                    model.pairWirelessADB(host: pairingAddress, port: pairingPort, code: submittedCode,
                                          ownerID: ownerID)
                } label: {
                    Label(pairButtonTitle, systemImage: "link")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).controlSize(.large)
                .disabled(model.isBusy || !canPair)
            }
        }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use the current address and connection port from Android’s main Wireless debugging screen. This port is different from the pairing port.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !pairingAddress.isEmpty {
                Toggle("Use the same IP address as pairing", isOn: $usesPairingAddress)
                    .toggleStyle(.checkbox)
                    .disabled(model.isBusy)
            }
            if !usesPairingAddress || pairingAddress.isEmpty {
                TextField("IP address", text: $connectionAddress, prompt: Text("192.168.1.25"))
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .accessibilityLabel("Connection IP address")
                    .disabled(model.isBusy)
            }
            HStack(spacing: 10) {
                TextField("Connection port", text: $connectionPort, prompt: Text("Port"))
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                    .accessibilityLabel("Wireless debugging connection port")
                    .disabled(model.isBusy)
                Spacer(minLength: 0)
                if model.isConnectingWireless && !model.isCancellingWireless {
                    Button("Cancel") {
                        feedbackTask = .connect
                        model.cancelWirelessSetupOperation(ownerID: ownerID)
                    }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                Button {
                    feedbackTask = .connect
                    model.connectWirelessADB(host: connectAddress, port: connectionPort, ownerID: ownerID)
                } label: {
                    Label(connectButtonTitle, systemImage: "wifi")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).controlSize(.large)
                .disabled(model.isBusy || !canConnect)
            }
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

    private enum WirelessTask: Hashable {
        case pair
        case connect
    }
}
