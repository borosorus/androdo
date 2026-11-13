import PhoneBackupCore

public enum ExportMapping {
    public static func commonSourceBase(for roots: [BackupEntry]) -> RemotePath? {
        guard !roots.isEmpty else { return nil }
        if roots.count == 1, roots[0].kind == .file { return roots[0].path.parent }
        return commonSourceBase(for: roots.map(\.path))
    }

    public static func commonSourceBase(for paths: [RemotePath]) -> RemotePath? {
        guard let first = paths.first, !paths.isEmpty else { return nil }
        let commonCount = paths.dropFirst().reduce(first.components.count) { current, path in
            var count = 0
            for (left, right) in zip(first.components.prefix(current), path.components) {
                guard left.utf8.elementsEqual(right.utf8) else { break }
                count += 1
            }
            return count
        }
        guard commonCount > 0 else { return .root }
        return try? RemotePath(components: Array(first.components.prefix(commonCount)))
    }
}
