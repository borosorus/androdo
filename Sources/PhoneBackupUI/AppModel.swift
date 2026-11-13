import Foundation
import Observation
import PhoneBackupCore

public enum AppSection: String, CaseIterable, Identifiable {
    case device = "Device"
    case backups = "Backups"

    public var id: String { rawValue }
}

private enum ActiveOperationKind {
    case backup
    case restore
}

@MainActor
@Observable
public final class AppModel {
    public var section: AppSection = .device
    public private(set) var devices: [AndroidDevice] = []
    public private(set) var selectedDevice: AndroidDevice?
    public private(set) var backupLocation: URL?
    public private(set) var repositories: [BackupRepositoryInfo] = []
    public private(set) var selectedRepositoryID: RepositoryID?
    public private(set) var restorePoints: [RestorePoint] = []
    public private(set) var selectedRestorePoint: RestorePoint?
    public private(set) var restoreEntries: [BackupEntry] = []
    public private(set) var selectedRestoreRoots: Set<RemotePath> = []
    public private(set) var backupSelection = BackupSelection()
    public private(set) var backupPlan: BackupPlan?
    public private(set) var restorePlan: RestorePlan?
    public private(set) var recoveryAttempt: BackupAttempt?
    public private(set) var pendingAttempts: [BackupAttempt] = []
    public private(set) var recoveryWarnings: [OperationWarning] = []
    public private(set) var operationID: OperationID?
    public private(set) var operationEvent: OperationEvent?
    public private(set) var operationTitle: String?
    public private(set) var restoreResult: RestoreBatchResult?
    public private(set) var isPlanningBackup = false
    public private(set) var isPlanningExport = false
    public private(set) var isStartingOperation = false
    public private(set) var isLoadingFolder = false
    public var isShowingBackupReview = false
    public var isShowingExportReview = false
    public private(set) var requiresRepositoryRecoveryConfirmation = false
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?

    @ObservationIgnored private var services: AppServices
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let locationAccess: BackupLocationAccess
    @ObservationIgnored private var planningTask: Task<BackupPlan, Error>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var activeOperationKind: ActiveOperationKind?
    @ObservationIgnored private var contextGeneration = 0

    public var isOperationRunning: Bool { operationID != nil }
    public var isBusy: Bool { isPlanningBackup || isPlanningExport || isStartingOperation || isOperationRunning }
    public var hasADB: Bool { services.deviceTransport != nil }
    public var selectedRepository: BackupRepositoryInfo? {
        repositories.first(where: { $0.id == selectedRepositoryID })
    }

    public init(services: AppServices = .live(), preferences: AppPreferences = .standard,
                locationAccess: BackupLocationAccess = BackupLocationAccess(), loadOnStart: Bool = true) {
        self.services = services
        self.preferences = preferences
        self.locationAccess = locationAccess
        if loadOnStart {
            Task {
                await loadSavedDestination()
                await refreshDevices()
            }
        }
    }

    public func refreshDevices() async {
        guard let transport = services.deviceTransport else {
            devices = []
            if services.adbExecutable == nil { statusMessage = "Android Debug Bridge was not found." }
            return
        }
        do {
            let found = try await transport.connectedDevices()
            devices = found
            if let current = selectedDevice, let refreshed = found.first(where: { $0.id == current.id }) {
                selectedDevice = refreshed
            } else {
                selectedDevice = found.first(where: { $0.state == .device }) ?? found.first
                if let selectedDevice { loadSavedSelection(for: selectedDevice.id) }
            }
            statusMessage = found.isEmpty ? "No Android device is connected." : nil
            errorMessage = nil
        } catch {
            devices = []
            selectedDevice = nil
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func selectDevice(_ device: AndroidDevice) {
        guard !isBusy else { return }
        contextGeneration += 1
        selectedDevice = device
        loadSavedSelection(for: device.id)
        backupPlan = nil
        isShowingBackupReview = false
        recoveryAttempt = nil
        recoveryWarnings = []
        pendingAttempts = []
        selectedRepositoryID = nil
        restorePoints = []
        selectedRestorePoint = nil
        selectedRestoreRoots = []
        restoreEntries = []
        restorePlan = nil
        isShowingExportReview = false
        if let repository = repositories.first(where: { $0.deviceID == device.id }) {
            selectedRepositoryID = repository.id
            Task {
                await loadRestorePoints(for: repository.id)
                await loadPendingAttempts(for: repository.id)
            }
        } else {
            selectedRepositoryID = nil
            restorePoints = []
            selectedRestorePoint = nil
            restoreEntries = []
        }
    }

    public func setBackupSelection(_ selection: BackupSelection) {
        backupSelection = selection
        backupPlan = nil
        isShowingBackupReview = false
        contextGeneration += 1
        if let device = selectedDevice { preferences.save(selection, for: device.id) }
    }

    public func listRemoteChildren(of path: RemotePath) async -> [RemoteEntry] {
        guard let device = selectedDevice, device.state == .device,
              let remote = services.remoteAccess else {
            errorMessage = services.remoteAccess == nil ? "ADB is unavailable. Locate adb to browse this device." :
                "Connect and authorize an Android device before browsing folders."
            return []
        }
        isLoadingFolder = true
        defer { isLoadingFolder = false }
        do {
            let entries = try await remote.children(of: path, on: device.id)
            errorMessage = nil
            return entries
        } catch {
            errorMessage = UserFacingError.message(for: error)
            return []
        }
    }

    public func chooseBackupLocation(_ url: URL) async {
        guard !isBusy else { return }
        contextGeneration += 1
        resetRepositoryContext()
        do {
            try await closeOpenRepositories()
            let bookmark = try locationAccess.select(url)
            preferences.locationBookmark = bookmark
            backupLocation = url.standardizedFileURL
            requiresRepositoryRecoveryConfirmation = false
            repositories = try await services.repositoryStore.openRepositories(in: url)
            selectedRepositoryID = repositories.first(where: { $0.deviceID == selectedDevice?.id })?.id ?? repositories.first?.id
            preferences.knownRepositoryIDs = repositories.map { $0.id.id }
            if let selectedRepositoryID {
                await loadRestorePoints(for: selectedRepositoryID)
                await loadPendingAttempts(for: selectedRepositoryID)
            }
            else { restorePoints = []; selectedRestorePoint = nil; restoreEntries = [] }
            errorMessage = nil
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func authorizeNewRepositoryAtSelectedLocation() {
        requiresRepositoryRecoveryConfirmation = false
    }

    public func locateADB(at url: URL) {
        guard !isBusy else { return }
        preferences.adbExecutablePath = url.standardizedFileURL.path
        services = services.usingADB(at: url)
        Task { await refreshDevices() }
    }

    public func reviewBackup() async {
        guard !isBusy else { return }
        guard let device = selectedDevice, device.state == .device else {
            errorMessage = "Connect and authorize an Android device before planning a backup."
            return
        }
        guard let engine = services.backupEngine else {
            errorMessage = "ADB is unavailable. Locate adb before planning a backup."
            return
        }
        guard let backupLocation else {
            errorMessage = "Choose where to store this backup first."
            return
        }
        guard !backupSelection.normalizedRoots.isEmpty else {
            errorMessage = "Choose at least one folder or select All shared files."
            return
        }
        isPlanningBackup = true
        errorMessage = nil
        backupPlan = nil
        let generation = contextGeneration
        do {
            let repository = try await repository(for: device, createIfMissing: true, at: backupLocation)
            let selection = backupSelection
            let task = Task { try await engine.plan(repository: repository.id, device: device.id, selection: selection) }
            planningTask = task
            let plan = try await task.value
            guard generation == contextGeneration, selectedDevice?.id == device.id,
                  self.backupLocation == backupLocation else {
                planningTask = nil
                isPlanningBackup = false
                return
            }
            backupPlan = plan
            isShowingBackupReview = true
            if plan.omissions.isEmpty { statusMessage = nil }
        } catch is CancellationError {
            statusMessage = "Backup planning cancelled."
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
        planningTask = nil
        isPlanningBackup = false
    }

    public func cancelPlanning() {
        planningTask?.cancel()
    }

    public func startBackup() async {
        guard !isBusy, let plan = backupPlan, let engine = services.backupEngine else { return }
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            let operation = try await engine.startBackup(using: plan.id, omissions: .requireComplete)
            isShowingBackupReview = false
            backupPlan = nil
            monitorBackup(operation, engine: engine, repository: plan.repository)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func retryBackup() async {
        await retryBackup(recoveryAttempt)
    }

    public func retryBackup(_ attempt: BackupAttempt?) async {
        guard !isBusy, let attempt, let engine = services.backupEngine else { return }
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            let operation = try await engine.resumeBackup(attempt.id, omissions: .requireComplete)
            recoveryAttempt = nil
            recoveryWarnings = []
            pendingAttempts.removeAll { $0.id == attempt.id }
            monitorBackup(operation, engine: engine, repository: attempt.repository)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func finishBackupWithOmissions() async {
        await finishBackupWithOmissions(recoveryAttempt)
    }

    public func finishBackupWithOmissions(_ attempt: BackupAttempt?) async {
        guard !isBusy, let attempt, let engine = services.backupEngine else { return }
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            let operation = try await engine.finishWithOmissions(attempt.id)
            recoveryAttempt = nil
            pendingAttempts.removeAll { $0.id == attempt.id }
            monitorBackup(operation, engine: engine, repository: attempt.repository)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func prepareToFinishBackup(_ attempt: BackupAttempt) {
        guard !isBusy else { return }
        recoveryAttempt = attempt
        recoveryWarnings = attempt.omissions
    }

    public func cancelOperation() async {
        guard let operationID else { return }
        switch activeOperationKind {
        case .backup: if let backupEngine = services.backupEngine { await backupEngine.cancel(operationID) }
        case .restore: await services.restoreEngine.cancel(operationID)
        case nil: break
        }
    }

    public func selectRepository(_ id: RepositoryID) async {
        guard !isBusy, repositories.contains(where: { $0.id == id }) else { return }
        contextGeneration += 1
        selectedRepositoryID = id
        recoveryAttempt = nil
        recoveryWarnings = []
        pendingAttempts = []
        selectedRestorePoint = nil
        selectedRestoreRoots = []
        restoreEntries = []
        restorePlan = nil
        isShowingExportReview = false
        await loadPendingAttempts(for: id)
        await loadRestorePoints(for: id)
    }

    public func selectRestorePoint(_ point: RestorePoint) async {
        guard !isBusy, let repository = selectedRepositoryID else { return }
        contextGeneration += 1
        let generation = contextGeneration
        do {
            selectedRestorePoint = point
            selectedRestoreRoots = []
            restoreEntries = []
            restorePlan = nil
            isShowingExportReview = false
            let entries = try await services.repositoryStore.entries(in: repository, point: point.id, below: nil)
            guard generation == contextGeneration, selectedRepositoryID == repository,
                  selectedRestorePoint?.id == point.id else { return }
            restoreEntries = entries
            errorMessage = nil
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func toggleRestoreRoot(_ path: RemotePath) {
        contextGeneration += 1
        if selectedRestoreRoots.contains(path) { selectedRestoreRoots.remove(path) }
        else { selectedRestoreRoots.insert(path) }
        restorePlan = nil
        isShowingExportReview = false
    }

    public func planLocalExport(to folder: URL) async {
        guard !isBusy, let repository = selectedRepositoryID, let point = selectedRestorePoint,
              !selectedRestoreRoots.isEmpty else { return }
        let selectedEntries = selectedRestoreRoots.compactMap { root in restoreEntries.first { $0.path == root } }
        guard selectedEntries.count == selectedRestoreRoots.count,
              let sourceBase = ExportMapping.commonSourceBase(for: selectedEntries) else {
            errorMessage = "Select one or more files or folders to export."
            return
        }
        do {
            isPlanningExport = true
            defer { isPlanningExport = false }
            let request = RestoreRequest(repository: repository, point: point.id,
                                         selectedRoots: Array(selectedRestoreRoots),
                                         target: .localFolder(folder, sourceBase: sourceBase))
            let generation = contextGeneration
            let plan = try await services.restoreEngine.planRestore(request)
            guard generation == contextGeneration,
                  selectedRepositoryID == repository,
                  selectedRestorePoint?.id == point.id,
                  selectedRestoreRoots == Set(request.selectedRoots) else { return }
            restorePlan = plan
            isShowingExportReview = true
            errorMessage = nil
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func startLocalExport(replacing conflicts: Set<UUID>) async {
        guard !isBusy, let plan = restorePlan else { return }
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            isShowingExportReview = false
            restoreResult = nil
            let operation = try await services.restoreEngine.startRestore(plan.id, replacing: conflicts)
            monitorRestore(operation)
        } catch {
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func cancelExportReview() {
        isShowingExportReview = false
        restorePlan = nil
    }

    public func clearStatus() {
        statusMessage = nil
        errorMessage = nil
        operationEvent = nil
        restoreResult = nil
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    private func loadSavedDestination() async {
        guard let bookmark = preferences.locationBookmark else {
            requiresRepositoryRecoveryConfirmation = !preferences.knownRepositoryIDs.isEmpty
            return
        }
        do {
            let url = try locationAccess.resolve(bookmark)
            backupLocation = url
            repositories = try await services.repositoryStore.openRepositories(in: url)
            let expected = Set(preferences.knownRepositoryIDs)
            let opened = Set(repositories.map { $0.id.id })
            requiresRepositoryRecoveryConfirmation = !expected.isEmpty && !expected.isSubset(of: opened)
            if !requiresRepositoryRecoveryConfirmation {
                preferences.knownRepositoryIDs = repositories.map { $0.id.id }
                selectedRepositoryID = repositories.first?.id
                if let selectedRepositoryID {
                    await loadRestorePoints(for: selectedRepositoryID)
                    await loadPendingAttempts(for: selectedRepositoryID)
                }
            } else {
                errorMessage = "The saved backup folder no longer contains the repositories this app knew. Locate the original folder or explicitly choose a new backup location."
            }
        } catch {
            requiresRepositoryRecoveryConfirmation = !preferences.knownRepositoryIDs.isEmpty
            errorMessage = "The saved backup folder is unavailable. Locate it again before starting a new backup."
        }
    }

    private func loadSavedSelection(for device: DeviceID) {
        backupSelection = preferences.selection(for: device)
        backupPlan = nil
        contextGeneration += 1
    }

    private func repository(for device: AndroidDevice, createIfMissing: Bool, at location: URL) async throws -> BackupRepositoryInfo {
        if let repository = repositories.first(where: { $0.deviceID == device.id }) { return repository }
        guard createIfMissing else { throw EngineError.repositoryUnavailable(location) }
        guard !requiresRepositoryRecoveryConfirmation else {
            throw EngineError.repositoryUnavailable(location)
        }
        let repository = try await services.repositoryStore.openOrCreateRepository(in: location, for: device)
        if !repositories.contains(where: { $0.id == repository.id }) { repositories.append(repository) }
        selectedRepositoryID = repository.id
        preferences.knownRepositoryIDs = repositories.map { $0.id.id }
        return repository
    }

    private func closeOpenRepositories() async throws {
        for repository in repositories {
            try await services.repositoryStore.closeRepository(repository.id)
        }
        repositories = []
        resetRepositoryContext()
    }

    private func resetRepositoryContext() {
        selectedRepositoryID = nil
        restorePoints = []
        selectedRestorePoint = nil
        selectedRestoreRoots = []
        restoreEntries = []
        pendingAttempts = []
        recoveryAttempt = nil
        recoveryWarnings = []
        restorePlan = nil
        isShowingExportReview = false
    }

    private func loadRestorePoints(for repository: RepositoryID) async {
        do {
            let points = try await services.repositoryStore.restorePoints(in: repository)
            guard selectedRepositoryID == repository else { return }
            restorePoints = points
            errorMessage = nil
        } catch {
            restorePoints = []
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func loadPendingAttempts(for repository: RepositoryID) async {
        do {
            let attempts = try await services.repositoryStore.backupAttempts(in: repository)
                .filter { $0.state != .running }
                .sorted { $0.startedAt > $1.startedAt }
            guard selectedRepositoryID == repository else { return }
            pendingAttempts = attempts
        } catch {
            pendingAttempts = []
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func monitorBackup(_ operation: OperationID, engine: any BackupEngine, repository: RepositoryID) {
        operationID = operation
        activeOperationKind = .backup
        operationTitle = "Backing up"
        operationEvent = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.events(for: operation)
            var terminal: OperationEvent?
            for await event in stream {
                self.operationEvent = event
                if event.phase.isTerminal { terminal = event; break }
            }
            await self.finishBackupOperation(operation, engine: engine, repository: repository, terminal: terminal)
        }
    }

    private func finishBackupOperation(_ operation: OperationID, engine: any BackupEngine,
                                       repository: RepositoryID, terminal: OperationEvent?) async {
        let attemptID = await engine.attemptID(for: operation)
        if let attemptID, let attempt = try? await services.repositoryStore.backupAttempt(attemptID, in: repository),
           attempt.state != .running {
            recoveryAttempt = attempt
            recoveryWarnings = terminal?.warnings ?? attempt.omissions
        } else {
            recoveryAttempt = nil
            recoveryWarnings = []
        }
        if terminal?.phase == .completed {
            statusMessage = "Backup completed and verified."
            await loadRestorePoints(for: repository)
        } else if terminal?.phase == .cancelled {
            statusMessage = "Backup cancelled. The previous restore point remains available."
        } else if terminal?.phase == .failed {
            statusMessage = "Backup failed. The previous restore point remains available."
        }
        await loadPendingAttempts(for: repository)
        if operationID == operation { operationID = nil; operationTitle = nil; activeOperationKind = nil }
        operationTask = nil
    }

    private func monitorRestore(_ operation: OperationID) {
        operationID = operation
        activeOperationKind = .restore
        operationTitle = "Exporting restore point"
        operationEvent = nil
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.services.restoreEngine.events(for: operation)
            var terminal: OperationEvent?
            for await event in stream {
                self.operationEvent = event
                if event.phase.isTerminal { terminal = event; break }
            }
            self.restoreResult = await self.services.restoreEngine.result(for: operation)
            if terminal?.phase == .completed { self.statusMessage = "Export completed and verified." }
            if self.operationID == operation { self.operationID = nil; self.operationTitle = nil; self.activeOperationKind = nil }
            self.operationTask = nil
        }
    }
}

public enum UserFacingError {
    public static func message(for error: Error) -> String {
        guard let error = error as? EngineError else { return error.localizedDescription }
        return switch error {
        case .adbUnavailable: "ADB could not be started. Check its location and permissions."
        case .operationTimedOut: "The device did not respond in time. Reconnect it and try again."
        case .deviceUnavailable: "The selected Android device disconnected. Reconnect it to continue."
        case .missingPath(let path): "The selected path is no longer available: \(path.description)"
        case .inaccessiblePath(let path): "Android denied access to \(path.description). Choose another folder or continue with skipped paths."
        case .notDirectory(let path): "This item is not a folder: \(path.description)"
        case .unsupportedDirectoryListing: "This device does not support safe folder browsing over ADB."
        case .destinationConflict(let conflict): "The destination needs attention: \(conflict.destination). Review the conflict before continuing."
        case .unsupportedFilename(let path): "This filename cannot be represented safely: \(path.description)"
        case .sourceChanged(let path): "The source changed during the operation: \(path.description). Review it and try again."
        case .insufficientSpace: "There is not enough free space to finish this operation."
        case .safeNoOverwriteUnavailable(let path): "This device cannot safely create \(path.description) without overwriting. Review an explicit replacement plan or choose another folder."
        case .destinationPublishedUnverified(let path, _): "The item may have been written to \(path), but its final verification could not be confirmed. Check the destination before retrying."
        case .corruptedRepository(let detail): "The backup repository could not be read safely: \(detail)"
        case .repositoryBusy: "This backup repository is already in use. Close the other app window and try again."
        case .repositoryDeviceMismatch: "This backup belongs to a different Android device."
        case .repositoryUnavailable: "The backup folder is unavailable. Reconnect the disk or choose the folder again."
        case .repositoryFormatUnsupported: "This backup repository uses an unsupported format."
        case .repositoryIO(let detail): "The backup folder could not be used: \(detail)"
        case .emptySelection: "Select at least one file or folder to continue."
        case .transport(let detail): detail
        case .invalidIdentifier, .invalidRemotePath: "The selected device path is invalid. Choose a folder again."
        }
    }
}
