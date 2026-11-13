import Foundation
import PhoneBackupCore

@MainActor
public final class AppPreferences {
    public static let standard = AppPreferences()

    private let defaults: UserDefaults
    private let locationKey = "backupLocationBookmark"
    private let repositoryIDsKey = "knownRepositoryIDs"
    private let adbPathKey = "adbExecutablePath"
    private let selectionPrefix = "backupSelection."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var locationBookmark: Data? {
        get { defaults.data(forKey: locationKey) }
        set { defaults.set(newValue, forKey: locationKey) }
    }

    public var knownRepositoryIDs: [UUID] {
        get { (defaults.stringArray(forKey: repositoryIDsKey) ?? []).compactMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue.map(\.uuidString), forKey: repositoryIDsKey) }
    }

    public var adbExecutablePath: String? {
        get { defaults.string(forKey: adbPathKey) }
        set { defaults.set(newValue, forKey: adbPathKey) }
    }

    public func selection(for device: DeviceID) -> BackupSelection {
        guard let data = defaults.data(forKey: selectionPrefix + device.serial),
              let value = try? JSONDecoder().decode(BackupSelection.self, from: data) else {
            return BackupSelection()
        }
        return value
    }

    public func save(_ selection: BackupSelection, for device: DeviceID) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: selectionPrefix + device.serial)
    }
}

@MainActor
public final class BackupLocationAccess {
    public private(set) var url: URL?
    private var hasSecurityScope = false

    public init() {}

    public func bookmark(for selectedURL: URL) throws -> Data {
        try selectedURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw EngineError.repositoryUnavailable(resolved) }
        beginAccess(to: resolved)
        return resolved.standardizedFileURL
    }

    public func select(_ selectedURL: URL) throws -> Data {
        endAccess()
        beginAccess(to: selectedURL)
        url = selectedURL.standardizedFileURL
        return try bookmark(for: selectedURL)
    }

    public func beginAccess(to selectedURL: URL) {
        if url != nil { endAccess() }
        hasSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        url = selectedURL.standardizedFileURL
    }

    public func endAccess() {
        if hasSecurityScope, let url { url.stopAccessingSecurityScopedResource() }
        hasSecurityScope = false
        url = nil
    }
}
