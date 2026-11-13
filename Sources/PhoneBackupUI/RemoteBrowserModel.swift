import Foundation
import Observation
import PhoneBackupCore

public enum RemoteSortColumn: String, CaseIterable, Sendable {
    case name, kind, size, modified
}

@MainActor
@Observable
public final class RemoteBrowserModel {
    public private(set) var device: AndroidDevice?
    public private(set) var currentDirectory: RemotePath = .root
    public private(set) var entries: [RemoteEntry] = []
    public var selection: Set<RemotePath> = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var hasOpenedRoot = false
    public var sortColumn: RemoteSortColumn = .name
    public var sortAscending = true

    @ObservationIgnored private var remote: (any RemoteFileAccess)?
    @ObservationIgnored private var generation = 0

    public init(remote: (any RemoteFileAccess)? = nil) { self.remote = remote }

    /// Transport replacement can retain the last displayed listing for the same device.
    /// In-flight requests are invalidated; a subsequent device change still resets everything.
    public func updateRemote(_ remote: (any RemoteFileAccess)?, preservingListing: Bool = false) {
        self.remote = remote
        if preservingListing {
            generation += 1
            isLoading = false
            errorMessage = nil
        } else {
            reset()
        }
    }

    public func setDevice(_ device: AndroidDevice?) {
        guard self.device?.id != device?.id || self.device?.state != device?.state else { return }
        self.device = device
        reset()
    }

    public func openRoot() async {
        guard !hasOpenedRoot else { return }
        let sharedStorage = try! RemotePath("/sdcard")
        await navigate(to: sharedStorage)
        hasOpenedRoot = currentDirectory == sharedStorage && errorMessage == nil
    }

    public func navigate(to path: RemotePath) async {
        guard let device, device.state == .device else {
            entries = []
            errorMessage = "Connect and authorize an Android device to browse files."
            return
        }
        guard let remote else {
            entries = []
            errorMessage = "ADB is unavailable. Locate adb before browsing files."
            return
        }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        errorMessage = nil
        do {
            let listed = try await remote.children(of: path, on: device.id)
            guard requestGeneration == generation, self.device?.id == device.id else { return }
            currentDirectory = path
            entries = sorted(listed)
            selection = selection.filter { selected in selected.isEqualOrDescendant(of: path) || path.isEqualOrDescendant(of: selected) }
        } catch {
            guard requestGeneration == generation, self.device?.id == device.id else { return }
            errorMessage = UserFacingError.message(for: error)
            currentDirectory = path
            entries = []
        }
        if requestGeneration == generation { isLoading = false }
    }

    public func refresh() async { await navigate(to: currentDirectory) }

    public func goUp() async {
        guard let parent = currentDirectory.parent else { return }
        await navigate(to: parent)
    }

    public func open(_ entry: RemoteEntry) async {
        guard entry.kind == .directory else { return }
        await navigate(to: entry.path)
    }

    public func sort(by column: RemoteSortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        entries = sorted(entries)
    }

    public var breadcrumbs: [RemotePath] {
        var result: [RemotePath] = [.root]
        var partial = RemotePath.root
        for component in currentDirectory.components {
            guard let next = try? partial.appending(component) else { continue }
            partial = next
            result.append(next)
        }
        return result
    }

    private func reset() {
        generation += 1
        currentDirectory = .root
        entries = []
        selection = []
        isLoading = false
        errorMessage = nil
        hasOpenedRoot = false
    }

    private func sorted(_ values: [RemoteEntry]) -> [RemoteEntry] {
        values.sorted { lhs, rhs in
            let ordering: ComparisonResult
            switch sortColumn {
            case .name: ordering = lhs.name.localizedStandardCompare(rhs.name)
            case .kind: ordering = lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue)
            case .size: ordering = (lhs.size ?? -1).compare(rhs.size ?? -1)
            case .modified: ordering = (lhs.modifiedAt ?? .distantPast).compare(rhs.modifiedAt ?? .distantPast)
            }
            if ordering == .orderedSame { return RemotePath.bytewiseLess(lhs.path, rhs.path) }
            return sortAscending ? ordering == .orderedAscending : ordering == .orderedDescending
        }
    }
}

private extension Comparable {
    func compare(_ other: Self) -> ComparisonResult {
        if self < other { .orderedAscending }
        else if self > other { .orderedDescending }
        else { .orderedSame }
    }
}
