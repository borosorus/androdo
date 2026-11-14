import PhoneBackupCore
import SwiftUI

/// Focused, reusable instructions for preparing and authorizing an Android phone over ADB.
struct AndroidConnectionGuide: View {
    let hasADB: Bool
    let deviceState: DeviceState?
    let discoveryIssue: DeviceDiscoveryIssueKind?

    private let developerOptionsURL = URL(string: "https://developer.android.com/studio/debug/dev-options#enable")!
    private let usbDebuggingURL = URL(string: "https://developer.android.com/studio/debug/dev-options#debugging")!
    private let adbAuthorizationURL = URL(string: "https://developer.android.com/tools/adb#Enabling")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cable.connector")
                    .font(.title2)
                    .foregroundStyle(AppIdentity.teal)
                    .frame(width: 42, height: 42)
                    .background(AppIdentity.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prepare your phone").font(.headline)
                    Text("Android hides this connection behind Developer options and a trust prompt.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Label(connectionStatus, systemImage: statusSymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                AndroidConnectionStep(number: 1, title: "Turn on Developer options",
                                      detail: "On your phone, open Settings → About phone → Build number and tap Build number seven times. Enter your screen lock if asked. On Samsung phones, Build number is under Software information. Names and locations vary by manufacturer.")
                AndroidConnectionStep(number: 2, title: "Enable USB debugging",
                                      detail: "Return to Settings → System → Developer options and turn on USB debugging. Some phones place Developer options elsewhere or use a slightly different label.")
                AndroidConnectionStep(number: 3, title: "Connect and unlock the phone",
                                      detail: "Use a USB cable that supports data, then keep the phone unlocked while connecting it to this Mac.")
                AndroidConnectionStep(number: 4, title: "Authorize this Mac",
                                      detail: "If Android shows “Allow USB debugging?”, approve it only if you trust this Mac. A Mac you authorized before may not prompt again. Then choose Check Again in Androdo.")
            }

            VStack(alignment: .leading, spacing: 7) {
                Label("Why Androdo needs this", systemImage: "questionmark.circle")
                    .font(.callout.weight(.semibold)).foregroundStyle(AppIdentity.blue)
                Text("USB debugging gives an authorized computer an ADB command connection to Android. Androdo uses that connection for the file actions you start. Check Again checks connected devices. Connecting a phone never opens its folders; in File Explorer, choose Open Shared Storage when you’re ready to browse. Androdo lists only the current folder’s immediate entries and doesn’t scan deeper folders.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Authorize only a Mac you trust. You can turn USB debugging off in Android Settings when you’re done using Androdo.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppIdentity.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 7) {
                Link("Developer options guide…", destination: developerOptionsURL)
                Link("USB debugging settings…", destination: usbDebuggingURL)
                Link("ADB authorization and trust…", destination: adbAuthorizationURL)
            }
            .font(.callout)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07)) }
    }

    private var connectionStatus: String {
        guard hasADB else { return "Set up ADB on this Mac first; then Androdo can check for your phone." }
        if discoveryIssue == .identityUnavailable {
            return "ADB sees a connected phone, but Androdo couldn’t verify its identity. Refresh the device list or check the phone’s ADB connection. File operations stay disabled until identity can be verified."
        }
        if discoveryIssue == .unsupportedConnection {
            return "ADB listed a phone without a usable connection ID. Update Android Platform Tools, then choose Check Again."
        }
        if discoveryIssue == .transferProtocolUnavailable {
            return "This connection does not support Androdo’s guarded file-transfer protocol. Update Android Platform Tools, then choose Check Again."
        }
        guard let deviceState else { return "No phone is listed yet. Connect it by USB, unlock it, then choose Check Again." }
        return switch deviceState {
        case .device: "This phone is connected and authorized."
        case .unauthorized: "Android sees this phone, but it has not authorized this Mac yet. Unlock the phone and approve its prompt."
        case .offline: "Android lists this phone as offline. Reconnect the cable and unlock the phone."
        case .bootloader, .recovery, .sideload: "The phone is in a maintenance mode. Restart Android normally to browse shared files."
        case .unknown(let state): "Android reported an unrecognized connection state: \(state)."
        }
    }

    private var statusSymbol: String {
        guard hasADB else { return "info.circle" }
        if discoveryIssue != nil { return "exclamationmark.triangle" }
        guard let deviceState else { return "cable.connector" }
        return switch deviceState {
        case .device: "checkmark.circle.fill"
        case .unauthorized: "lock.open"
        case .offline, .bootloader, .recovery, .sideload, .unknown: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        if discoveryIssue != nil { return AppIdentity.copper }
        if deviceState == .device { return AppIdentity.teal }
        if deviceState == .unauthorized { return AppIdentity.copper }
        return .secondary
    }
}

private struct AndroidConnectionStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number.formatted())
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AppIdentity.blue)
                .frame(width: 25, height: 25)
                .background(AppIdentity.blue.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
