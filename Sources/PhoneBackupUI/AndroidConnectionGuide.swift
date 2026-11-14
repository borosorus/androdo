import PhoneBackupCore
import SwiftUI

/// Compact USB instructions with optional manufacturer and trust details.
struct AndroidConnectionGuide: View {
    let hasADB: Bool
    let deviceState: DeviceState?
    let discoveryIssue: DeviceDiscoveryIssueKind?

    private let developerOptionsURL = URL(string: "https://developer.android.com/studio/debug/dev-options#enable")!
    private let usbDebuggingURL = URL(string: "https://developer.android.com/studio/debug/dev-options#debugging")!
    private let adbAuthorizationURL = URL(string: "https://developer.android.com/tools/adb#Enabling")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(connectionStatus, systemImage: statusSymbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 9) {
                AndroidConnectionStep(number: 1, title: "Enable Developer options",
                                      detail: "On Android, open Settings → About phone and tap Build number seven times.")
                Divider().padding(.leading, 35)
                AndroidConnectionStep(number: 2, title: "Turn on USB debugging",
                                      detail: "Find Developer options in Settings and enable USB debugging.")
                Divider().padding(.leading, 35)
                AndroidConnectionStep(number: 3, title: "Connect and unlock your phone",
                                      detail: "Use a data-capable USB cable and keep Android unlocked.")
                Divider().padding(.leading, 35)
                AndroidConnectionStep(number: 4, title: "Authorize this Mac",
                                      detail: "Approve “Allow USB debugging?” on Android, then choose Check Again.")
            }
            .padding(.vertical, 3)

            DisclosureGroup("Connection help and privacy") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Settings names vary by manufacturer. On Samsung, Build number is under Software information. Enter your screen lock if Android asks.")
                    Text("USB debugging gives an authorized computer an ADB command connection. Authorize only a Mac you trust; you can turn debugging off in Android Settings when you’re done.")
                    Text("Device checks verify connection and identity. They don’t list folders or read files. In File Explorer, choose Open Shared Storage to browse.")
                    Link("Developer options guide…", destination: developerOptionsURL)
                    Link("USB debugging settings…", destination: usbDebuggingURL)
                    Link("ADB authorization and trust…", destination: adbAuthorizationURL)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
            }
            .font(.callout.weight(.medium))
        }
    }

    private var connectionStatus: String {
        guard hasADB else { return "Set up ADB on this Mac first; then Androdo can check for your phone." }
        if discoveryIssue == .identityUnavailable {
            return "ADB sees a phone, but Androdo couldn’t verify its identity. Refresh the device list or check the phone’s connection. File actions stay disabled until identity is verified."
        }
        if discoveryIssue == .unsupportedConnection {
            return "ADB listed a phone without a usable connection ID. Update Android Platform Tools, then choose Check Again."
        }
        if discoveryIssue == .transferProtocolUnavailable {
            return "This connection doesn’t support Androdo’s guarded file transfer. Update Android Platform Tools, then choose Check Again."
        }
        guard let deviceState else { return "No phone is listed yet. Connect it by USB, unlock it, then choose Check Again." }
        return switch deviceState {
        case .device: "This phone is connected and authorized."
        case .unauthorized: "Android sees this phone, but it hasn’t authorized this Mac. Unlock it and approve the prompt."
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
        return AppIdentity.blue
    }
}

private struct AndroidConnectionStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number.formatted())
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(AppIdentity.blue)
                .frame(width: 23, height: 23)
                .background(AppIdentity.blue.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
