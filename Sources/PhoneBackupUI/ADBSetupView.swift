import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ADB discovery and installation choices. Installing tools never probes phone folders.
struct ADBSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var showingFilePicker = false
    @State private var copiedCommand = false
    @State private var acceptsGoogleTerms = false

    private let homebrewCommand = "brew install --cask android-platform-tools"
    private let downloadPage = URL(string: "https://developer.android.com/tools/releases/platform-tools")!

    var body: some View {
        ReviewSheetLayout(title: "Connect your Android", subtitle: "Set up this Mac, then prepare and authorize your phone.",
                          minimumWidth: 620, minimumHeight: 580) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cable.connector").font(.title).foregroundStyle(AppIdentity.teal)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Android Debug Bridge (ADB)").font(.headline)
                        Text("ADB is Google’s connection tool. Androdo uses it to transfer the files you choose; Android Studio is not required.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let error = model.errorMessage {
                    MessageBanner(text: error, symbol: "exclamationmark.triangle", isWarning: true)
                }

                if model.hasADB {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(model.isUsingManagedADB ? "Androdo Platform Tools ready" : "ADB found", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(AppIdentity.teal)
                        if let url = model.adbExecutableURL {
                            Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text(model.isUsingManagedADB ? "Installed in Androdo’s private support folder." : "This existing installation will be left in place unless you choose to switch ADB.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppIdentity.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Label("ADB hasn’t been found yet", systemImage: "info.circle")
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                }

                if !model.hasADB {
                    platformToolsSetup
                }

                AndroidConnectionGuide(hasADB: model.hasADB, deviceState: model.selectedDevice?.state)

                if model.hasADB {
                    DisclosureGroup("Install or switch Platform Tools") {
                        platformToolsSetup.padding(.top, 10)
                    }
                    .font(.callout.weight(.medium))
                }

                Text("You can browse saved backups without connecting a phone.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } footer: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(model.hasADB ? "Locate Another ADB…" : "Locate ADB…") { showingFilePicker = true }
                .disabled(model.isBusy)
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

    private var managedInstallPath: String {
        let path = GoogleADBPlatformToolsInstaller.defaultRootDirectory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }

    private var platformToolsSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Install a local copy").font(.headline)
                Spacer()
                Text("RECOMMENDED").font(.caption2.weight(.bold)).tracking(0.5)
                    .foregroundStyle(AppIdentity.copper)
            }
            Text("Androdo downloads the latest macOS Platform Tools directly from Google, verifies the archive and ADB executable, then stores its own copy here:")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(managedInstallPath).font(.caption.monospaced()).textSelection(.enabled)
                .foregroundStyle(.secondary)
            Text("Your Android Studio, Homebrew, or other ADB installation is not changed. Androdo won’t look for your phone until you choose Check Again.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

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
                Label(model.isUsingManagedADB ? "Reinstall Platform Tools" : "Install Platform Tools", systemImage: "arrow.down.to.line.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(AppIdentity.brandBlue).controlSize(.large)
            .disabled(!acceptsGoogleTerms || model.isBusy)
            .accessibilityHint(acceptsGoogleTerms ? "Downloads Platform Tools from Google and shows progress." : "Agree to Google’s SDK terms first to enable the local install.")

            Link("Download and install manually instead…", destination: downloadPage)
                .font(.callout)
            DisclosureGroup("Already use Homebrew?") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Run this command in Terminal, then choose Check Again.").foregroundStyle(.secondary)
                    Text(homebrewCommand).font(.callout.monospaced()).textSelection(.enabled)
                    Button(copiedCommand ? "Command Copied" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        copiedCommand = NSPasteboard.general.setString(homebrewCommand, forType: .string)
                    }
                }.padding(.top, 8)
            }
        }
    }
}
