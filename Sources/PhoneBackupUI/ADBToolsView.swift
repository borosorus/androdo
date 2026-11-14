import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ADB discovery, installation, and manual executable selection.
struct ADBToolsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showingFilePicker = false
    @State private var copiedCommand = false
    @State private var acceptsGoogleTerms = false

    private let homebrewCommand = "brew install --cask android-platform-tools"
    private let downloadPage = URL(string: "https://developer.android.com/tools/releases/platform-tools")!

    var body: some View {
        ReviewSheetLayout(title: "ADB Tools",
                          subtitle: "Install or choose Android Platform Tools for this Mac.",
                          minimumWidth: 600, minimumHeight: 530) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.title2).foregroundStyle(AppIdentity.blue)
                        .frame(width: 40, height: 40)
                        .background(AppIdentity.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Android Platform Tools").font(.headline)
                        Text("ADB connects Androdo to your phone. Android Studio is not required.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error = model.errorMessage {
                    MessageBanner(text: error, symbol: "exclamationmark.triangle", isWarning: true)
                }

                adbStatus
                Divider()
                managedInstall
                Divider()
                existingInstall
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
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.unixExecutable], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { model.locateADB(at: url) }
            case .failure(let error): model.reportError(error.localizedDescription)
            }
        }
    }

    private var adbStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.hasADB ? (model.isUsingManagedADB ? "Androdo Platform Tools ready" : "ADB found") : "ADB hasn’t been found yet",
                  systemImage: model.hasADB ? "checkmark.circle.fill" : "info.circle")
                .font(.headline)
                .foregroundStyle(model.hasADB ? AppIdentity.teal : AppIdentity.copper)
            if let url = model.adbExecutableURL {
                Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(model.hasADB
                 ? (model.isUsingManagedADB ? "Installed in Androdo’s private support folder." : "Your existing installation will stay in place unless you choose to switch ADB.")
                 : "Choose an installation method below. Androdo does not search the whole Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((model.hasADB ? AppIdentity.teal : AppIdentity.copper).opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private var managedInstall: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Install an Androdo-managed copy").font(.headline)
                Spacer()
                Text("RECOMMENDED").font(.caption2.weight(.bold)).tracking(0.5)
                    .foregroundStyle(AppIdentity.copper)
            }
            Text("Androdo downloads the latest macOS Platform Tools directly from Google, verifies them, and keeps its copy separate from other installations.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(managedInstallPath).font(.caption.monospaced()).textSelection(.enabled)
                .foregroundStyle(.secondary)
            Toggle(isOn: $acceptsGoogleTerms) {
                Text("I agree to Google’s Android SDK License Agreement")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Read Google’s terms and Platform Tools details…", destination: downloadPage)
                .font(.callout)
            Button {
                let acceptedTerms = acceptsGoogleTerms
                acceptsGoogleTerms = false
                dismiss()
                if model.beginADBInstallation(acceptingGoogleTerms: acceptedTerms) {
                    openWindow(id: OperationProgressScene.windowID)
                }
            } label: {
                Label(model.isUsingManagedADB ? "Reinstall Platform Tools" : "Install Platform Tools",
                      systemImage: "arrow.down.to.line.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).controlSize(.large)
            .disabled(!acceptsGoogleTerms || model.isBusy)
            .accessibilityHint(acceptsGoogleTerms
                               ? "Downloads Platform Tools from Google and shows progress."
                               : "Agree to Google’s SDK terms first to enable the local install.")
        }
    }

    private var existingInstall: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use an existing installation").font(.headline)
            Text("Choose an ADB executable already on this Mac, or install with Homebrew if you use it.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Locate ADB…") { showingFilePicker = true }
                    .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue)
                    .disabled(model.isBusy)
                Link("Download Platform Tools…", destination: downloadPage)
            }
            DisclosureGroup("Already use Homebrew?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run this command in Terminal, then choose Check Again.")
                        .foregroundStyle(.secondary)
                    Text(homebrewCommand).font(.callout.monospaced()).textSelection(.enabled)
                    Button(copiedCommand ? "Command Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        copiedCommand = NSPasteboard.general.setString(homebrewCommand, forType: .string)
                    }
                }
                .padding(.top, 8)
            }
            .font(.callout.weight(.medium))
        }
    }

    private var managedInstallPath: String {
        let path = GoogleADBPlatformToolsInstaller.defaultRootDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }
}
