import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Installation guidance only. Downloads open in the browser; no installer runs in the app.
struct ADBSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingFilePicker = false
    @State private var copiedCommand = false

    private let homebrewCommand = "brew install --cask android-platform-tools"
    private let downloadPage = URL(string: "https://developer.android.com/tools/releases/platform-tools")!

    var body: some View {
        ReviewSheetLayout(title: "Connect your Android", subtitle: "A one-time setup for this Mac and your phone.",
                          minimumWidth: 600, minimumHeight: 570) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "cable.connector").font(.title).foregroundStyle(AppIdentity.teal)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Android Debug Bridge (ADB)").font(.headline)
                        Text("Google’s connection tool lets Androdo copy files over USB. It comes with Platform Tools; Android Studio isn’t required.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let error = model.errorMessage {
                    MessageBanner(text: error, symbol: "exclamationmark.triangle", isWarning: true)
                }
                if model.hasADB {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("ADB configured", systemImage: "checkmark.circle").font(.headline)
                        if let url = model.adbExecutableURL {
                            Text(url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("1. Get Platform Tools").font(.headline)
                    Text("Download the Mac version from Google and unzip it. Keep the platform-tools folder somewhere permanent, then select the adb file inside it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link(destination: downloadPage) {
                        Label("Get Platform Tools…", systemImage: "arrow.up.right.square")
                    }.buttonStyle(.bordered)
                    DisclosureGroup("Already use Homebrew?") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Run this command in Terminal, then choose Check Again.").foregroundStyle(.secondary)
                            Text(homebrewCommand).font(.callout.monospaced()).textSelection(.enabled)
                            Button(copiedCommand ? "Command Copied" : "Copy Command") {
                                NSPasteboard.general.clearContents()
                                copiedCommand = NSPasteboard.general.setString(homebrewCommand, forType: .string)
                            }
                        }.padding(.top, 8)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("2. Authorize your phone").font(.headline)
                    Text("Enable Developer options and USB debugging in your phone’s Settings. Connect by USB, unlock the phone, and accept the “Allow USB debugging?” prompt for this Mac.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("USB debugging help…", destination: URL(string: "https://developer.android.com/studio/debug/dev-options#enable")!)
                }
                Text("You can browse saved backups without connecting a phone.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } footer: {
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(model.hasADB ? "Change ADB…" : "Locate ADB…") { showingFilePicker = true }
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
}
