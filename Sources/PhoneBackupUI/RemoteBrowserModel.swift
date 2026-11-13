import Foundation
import Observation
import PhoneBackupCore

public enum RemoteSortColumn: String, CaseIterable, Sendable {
    case name, kind, size, modified
}

@MainActor
@Observable
public final class RemoteBrowserModel {
    public static let sharedStorage = try! RemotePath("/sdcard")
    public private(set) var device: AndroidDevice?
    public private(set) var currentDirectory = sharedStorage
    public private(set) var pendingDirectory: RemotePath?
    public private(set) var entries: [RemoteEntry] = []
    public var selection: Set<RemotePath> = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var hasOpenedRoot = false
    public private(set) var isShowingCachedContents = false
    public var sortColumn: RemoteSortColumn = .name
    public var sortAscending = true
    public private(set) var history: [RemotePath] = []
    public private(set) var historyIndex = -1

    @ObservationIgnored private var remote: (any RemoteFileAccess)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suspendedEntries: [RemoteEntry]?
    @ObservationIgnored private var listingTask: Task<[RemoteEntry], Error>?
    @ObservationIgnored private var cache: [RemotePath: [RemoteEntry]] = [:]
    @ObservationIgnored private var recency: [RemotePath] = []
    private let cachedFolderLimit = 16
    private let cachedEntryLimit = 20_000

    public init(remote: (any RemoteFileAccess)? = nil) { self.remote = remote }

    public var displayedDirectory: RemotePath { pendingDirectory ?? currentDirectory }
    public var canGoBack: Bool { isLoading ? !history.isEmpty : historyIndex > 0 }
    public var canGoForward: Bool { !isLoading && historyIndex >= 0 && historyIndex < history.count - 1 }
    public var parentDirectory: RemotePath? {
        displayedDirectory == Self.sharedStorage ? nil : displayedDirectory.parent
    }
    public var visibleSelection: Set<RemotePath> { selection.intersection(Set(entries.map(\.path))) }

    /// Replaces transport without issuing a listing. Cached directory metadata never crosses transports.
    public func updateRemote(_ remote: (any RemoteFileAccess)?, preservingListing: Bool = false) {
        cancelRequest()
        self.remote = remote
        invalidateVisitedFolders()
        if preservingListing {
            isLoading = false
            pendingDirectory = nil
            errorMessage = nil
        } else { reset() }
    }

    public func setDevice(_ device: AndroidDevice?) {
        guard self.device?.id != device?.id || self.device?.state != device?.state else { return }
        self.device = device
        reset()
    }

    public func openRoot() async {
        guard !hasOpenedRoot else { return }
        await navigate(to: Self.sharedStorage)
    }

    public func navigate(to path: RemotePath) async { await load(path, force: false, historyTarget: nil) }
    public func refresh() async { await load(displayedDirectory, force: true, historyTarget: nil) }
    public func goUp() async { if let parentDirectory { await navigate(to: parentDirectory) } }
    public func goBack() async {
        if isLoading { cancelNavigation(); return }
        guard canGoBack else { return }
        let target = historyIndex - 1
        await load(history[target], force: false, historyTarget: target)
    }
    public func goForward() async {
        guard canGoForward else { return }
        let target = historyIndex + 1
        await load(history[target], force: false, historyTarget: target)
    }

    public func open(_ entry: RemoteEntry) async {
        guard !isLoading, entry.kind == .directory, entries.contains(where: { $0.path == entry.path }) else { return }
        await navigate(to: entry.path)
    }

    public func cancelNavigation() {
        guard isLoading else { return }
        cancelRequest()
        pendingDirectory = nil
        isLoading = false
        errorMessage = nil
        entries = Self.sorted(suspendedEntries ?? cache[currentDirectory] ?? entries, column: sortColumn, ascending: sortAscending)
        suspendedEntries = nil
        selection = []
    }

    /// Called after phone writes, including partial outcomes. Refresh remains an explicit user action.
    public func invalidateVisitedFolders() {
        if isLoading { cancelNavigation() }
        cache.removeAll()
        recency.removeAll()
        if !entries.isEmpty { isShowingCachedContents = true }
    }

    public func sort(by column: RemoteSortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        entries = Self.sorted(entries, column: column, ascending: ascending)
    }

    public var breadcrumbs: [RemotePath] {
        let path = displayedDirectory
        let shared = path.isEqualOrDescendant(of: Self.sharedStorage)
        var result: [RemotePath] = shared ? [Self.sharedStorage] : [.root]
        var partial = shared ? Self.sharedStorage : .root
        for component in path.components.dropFirst(shared ? 1 : 0) {
            guard let next = try? partial.appending(component) else { continue }
            partial = next
            result.append(next)
        }
        return result
    }

    private func load(_ path: RemotePath, force: Bool, historyTarget: Int?) async {
        guard let device, device.state == .device, let remote else {
            cancelNavigation()
            entries = []
            errorMessage = "Connect and authorize an Android device to browse files."
            return
        }
        if pendingDirectory == path, let listingTask {
            _ = await listingTask.result // One owner commits the result; duplicate opens share its work.
            return
        }
        if !force, !isLoading, currentDirectory == path, errorMessage == nil, hasOpenedRoot { return }
        let previousSelection = currentDirectory == path ? visibleSelection : []
        cancelRequest()
        let request = generation
        selection = []
        errorMessage = nil
        if !force, let cached = cache[path] {
            commitLocation(path, historyTarget: historyTarget)
            entries = Self.sorted(cached, column: sortColumn, ascending: sortAscending)
            selection = previousSelection.intersection(Set(entries.map(\.path)))
            pendingDirectory = nil
            suspendedEntries = nil
            isLoading = false
            isShowingCachedContents = true
            touch(path)
            return
        }
        suspendedEntries = suspendedEntries ?? entries
        pendingDirectory = path
        entries = []
        isLoading = true
        isShowingCachedContents = false
        let task = Task {
            let values = try await remote.children(of: path, on: device.id)
            try Task.checkCancellation()
            return values
        }
        listingTask = task
        do {
            let listed = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == request, self.device?.id == device.id else { return }
            let column = sortColumn
            let ascending = sortAscending
            let sorted = await Task.detached(priority: .userInitiated) { Self.sorted(listed, column: column, ascending: ascending) }.value
            guard generation == request, self.device?.id == device.id else { return }
            commitLocation(path, historyTarget: historyTarget)
            entries = column == sortColumn && ascending == sortAscending ? sorted : Self.sorted(listed, column: sortColumn, ascending: sortAscending)
            selection = previousSelection.intersection(Set(entries.map(\.path)))
            store(listed, at: path)
        } catch is CancellationError {
            guard generation == request else { return }
            entries = Self.sorted(suspendedEntries ?? cache[currentDirectory] ?? [], column: sortColumn, ascending: sortAscending)
        } catch {
            guard generation == request, self.device?.id == device.id else { return }
            commitLocation(path, historyTarget: historyTarget, markOpened: false)
            errorMessage = UserFacingError.message(for: error)
            cache.removeValue(forKey: path)
            recency.removeAll { $0 == path }
            entries = []
        }
        if generation == request {
            listingTask = nil
            suspendedEntries = nil
            isLoading = false
            pendingDirectory = nil
        }
    }

    private func commitLocation(_ path: RemotePath, historyTarget: Int?, markOpened: Bool = true) {
        currentDirectory = path
        if markOpened && path == Self.sharedStorage { hasOpenedRoot = true }
        if let historyTarget { historyIndex = historyTarget }
        else if historyIndex < 0 || history[historyIndex] != path {
            history = Array(history.prefix(historyIndex + 1))
            history.append(path)
            historyIndex = history.count - 1
        }
    }

    private func store(_ entries: [RemoteEntry], at path: RemotePath) {
        cache.removeValue(forKey: path)
        recency.removeAll { $0 == path }
        guard entries.count <= cachedEntryLimit else { return }
        cache[path] = entries
        touch(path)
        while recency.count > cachedFolderLimit || cache.values.reduce(0, { $0 + $1.count }) > cachedEntryLimit {
            guard let oldest = recency.first else { break }
            recency.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func touch(_ path: RemotePath) { recency.removeAll { $0 == path }; recency.append(path) }
    private func cancelRequest() { generation += 1; listingTask?.cancel(); listingTask = nil }
    private func reset() {
        cancelRequest()
        currentDirectory = Self.sharedStorage
        suspendedEntries = nil
        pendingDirectory = nil
        entries = []
        selection = []
        isLoading = false
        errorMessage = nil
        hasOpenedRoot = false
        isShowingCachedContents = false
        history = []
        historyIndex = -1
        cache.removeAll()
        recency.removeAll()
    }

    nonisolated private static func sorted(_ values: [RemoteEntry], column: RemoteSortColumn, ascending: Bool) -> [RemoteEntry] {
        values.sorted { lhs, rhs in
            let ordering: ComparisonResult
            switch column {
            case .name: ordering = lhs.name.localizedStandardCompare(rhs.name)
            case .kind: ordering = lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue)
            case .size: ordering = (lhs.size ?? -1).compare(rhs.size ?? -1)
            case .modified: ordering = (lhs.modifiedAt ?? .distantPast).compare(rhs.modifiedAt ?? .distantPast)
            }
            if ordering == .orderedSame { return RemotePath.bytewiseLess(lhs.path, rhs.path) }
            return ascending ? ordering == .orderedAscending : ordering == .orderedDescending
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
