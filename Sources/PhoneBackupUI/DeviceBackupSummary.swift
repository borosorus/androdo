import Foundation
import PhoneBackupCore

public struct DeviceBackupSummary: Equatable, Sendable {
    public let points: [RestorePoint]
    public var latestComplete: RestorePoint? {
        points.filter { $0.state == .completed && $0.omissions.isEmpty }.max { $0.createdAt < $1.createdAt }
    }
    public var incompleteCount: Int { points.filter { $0.state == .incomplete || !$0.omissions.isEmpty }.count }
    public var latestIncomplete: RestorePoint? {
        points.filter { $0.state == .incomplete || !$0.omissions.isEmpty }.max { $0.createdAt < $1.createdAt }
    }
}

public enum DeviceBackupSummaryState: Equatable, Sendable {
    case noDevice, noLocation, loading, unavailable
    case loaded(DeviceBackupSummary)
}

enum BackupReadiness: Equatable {
    case connection, location, selection, ready, busy

    static func resolve(hasADB: Bool, device: AndroidDevice?, hasLocation: Bool,
                        needsLocationRecovery: Bool, selection: BackupSelection, isBusy: Bool) -> Self {
        if isBusy { return .busy }
        if !hasADB || device?.state != .device { return .connection }
        if !hasLocation || needsLocationRecovery { return .location }
        if selection.normalizedRoots.isEmpty { return .selection }
        return .ready
    }
}
