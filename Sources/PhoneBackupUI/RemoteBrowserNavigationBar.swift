import PhoneBackupCore
import SwiftUI

struct RemoteBrowserNavigationBar: View {
    let browser: RemoteBrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await browser.goBack() } } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoBack).help("Back").accessibilityLabel("Back")
            Button { Task { await browser.goForward() } } label: { Image(systemName: "chevron.right") }
                .disabled(!browser.canGoForward).help("Forward").accessibilityLabel("Forward")
            Button { Task { await browser.goUp() } } label: { Image(systemName: "arrow.up") }
                .disabled(browser.parentDirectory == nil).help("Enclosing folder").accessibilityLabel("Enclosing folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(browser.breadcrumbs, id: \.self) { path in
                        if path != browser.breadcrumbs.first { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        Button(path == RemoteBrowserModel.sharedStorage ? "Shared storage" : path.name ?? "/") {
                            Task { await browser.navigate(to: path) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(path == browser.displayedDirectory)
                    }
                }.padding(.horizontal, 5)
            }
            .accessibilityLabel("Phone folder path")
            if browser.isLoading {
                Button("Cancel") { browser.cancelNavigation() }
            } else {
                Button { Task { await browser.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(browser.device?.state != .device).help("Refresh folder").accessibilityLabel("Refresh folder")
            }
            Menu {
                ForEach(RemoteSortColumn.allCases, id: \.self) { column in
                    Button(column.rawValue.capitalized) { browser.sort(by: column, ascending: browser.sortAscending) }
                }
                Divider()
                Button(browser.sortAscending ? "Sort Descending" : "Sort Ascending") {
                    browser.sort(by: browser.sortColumn, ascending: !browser.sortAscending)
                }
            } label: { Image(systemName: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("Sort files")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
