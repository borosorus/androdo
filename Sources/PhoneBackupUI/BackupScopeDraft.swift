import PhoneBackupCore

struct BackupScopeDraft: Equatable {
    private(set) var selection: BackupSelection
    private var customRoots: [RemotePath]

    init(_ selection: BackupSelection) {
        self.selection = selection
        if case .selected = selection.scope { customRoots = selection.normalizedRoots } else { customRoots = [] }
    }

    var allSharedFiles: Bool { if case .allSharedStorage = selection.scope { true } else { false } }
    var includedRoots: [RemotePath] { allSharedFiles ? [] : selection.normalizedRoots }

    mutating func setAllSharedFiles(_ enabled: Bool) {
        if !allSharedFiles { customRoots = selection.normalizedRoots }
        selection = BackupSelection(scope: enabled ? .allSharedStorage : .selected(customRoots), excludedRoots: selection.excludedRoots)
    }

    func hasExcludedAncestor(_ path: RemotePath) -> Bool {
        selection.excludedRoots.contains { $0 != path && path.isEqualOrDescendant(of: $0) }
    }

    func canInclude(_ paths: Set<RemotePath>) -> Bool {
        !paths.isEmpty && !paths.contains(where: hasExcludedAncestor) && paths.contains { !selection.includes($0) }
    }

    mutating func include(_ paths: Set<RemotePath>) {
        guard canInclude(paths) else { return }
        for path in paths.sorted(by: RemotePath.bytewiseLess) { selection = BackupSelectionEditing.set(true, path: path, in: selection) }
    }

    mutating func exclude(_ paths: Set<RemotePath>) {
        for path in paths.sorted(by: RemotePath.bytewiseLess) { selection = BackupSelectionEditing.set(false, path: path, in: selection) }
    }

    mutating func removeIncluded(_ path: RemotePath) { exclude([path]) }
    mutating func removeExclusion(_ path: RemotePath) {
        selection = BackupSelection(scope: selection.scope, excludedRoots: selection.excludedRoots.filter { $0 != path })
    }

    func status(for path: RemotePath) -> String {
        if selection.excludedRoots.contains(where: { path.isEqualOrDescendant(of: $0) }) { return "Excluded" }
        if selection.includes(path) {
            return selection.excludedRoots.contains(where: { $0.isEqualOrDescendant(of: path) }) ? "Partly included" : "Included"
        }
        return includedRoots.contains(where: { $0.isEqualOrDescendant(of: path) }) ? "Contains included items" : ""
    }
}

enum BackupSelectionEditing {
    static func set(_ isSelected: Bool, path: RemotePath, in selection: BackupSelection) -> BackupSelection {
        var roots: [RemotePath]
        var exclusions = selection.excludedRoots
        switch selection.scope {
        case .allSharedStorage:
            if isSelected {
                exclusions.removeAll { $0 == path || path.isEqualOrDescendant(of: $0) }
            } else {
                exclusions.removeAll { $0.isEqualOrDescendant(of: path) }
                exclusions.append(path)
            }
            return BackupSelection(scope: .allSharedStorage, excludedRoots: exclusions)
        case .selected(let existing): roots = existing
        }

        if isSelected {
            exclusions.removeAll { $0 == path || path.isEqualOrDescendant(of: $0) }
            if !roots.contains(where: { path.isEqualOrDescendant(of: $0) }) { roots.append(path) }
        } else {
            let coveredBySelectedAncestor = roots.contains { $0 != path && path.isEqualOrDescendant(of: $0) }
            roots.removeAll { $0.isEqualOrDescendant(of: path) }
            if coveredBySelectedAncestor {
                exclusions.removeAll { $0.isEqualOrDescendant(of: path) }
                exclusions.append(path)
            }
        }
        return BackupSelection(scope: .selected(roots), excludedRoots: exclusions)
    }
}

