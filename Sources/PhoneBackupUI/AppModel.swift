import Foundation
import Observation
import PhoneBackupCore

public enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case device = "Device"
    case files = "Files"
    case backups = "Backups"

    public var id: String { rawValue }
}

private enum ActiveOperationKind {
    case backup
    case restore
    case copy
}

@MainActor
@Observable
public final class AppModel {
    public var section: AppSection = .device
    public let fileBrowser: RemoteBrowserModel
    public let activityStore: ActivityStore
    public private(set) var devices: [AndroidDevice] = []
    public private(set) var selectedDevice: AndroidDevice?
    public private(set) var backupLocation: URL?
    public private(set) var repositories: [BackupRepositoryInfo] = []
    public private(set) var selectedRepositoryID: RepositoryID?
    public private(set) var restorePoints: [RestorePoint] = []
    public private(set) var deviceBackupSummary: DeviceBackupSummaryState = .noDevice
    public private(set) var selectedRestorePoint: RestorePoint?
    public private(set) var restoreEntries: [BackupEntry] = []
    public private(set) var isLoadingRestorePoint = false
    public private(set) var restorePointError: String?
    public private(set) var selectedRestoreRoots: Set<RemotePath> = []
    public private(set) var backupSelection = BackupSelection()
    public private(set) var backupPlan: BackupPlan?
    public private(set) var restorePlan: RestorePlan?
    public private(set) var copyPlan: CopyPlan?
    public private(set) var copyResult: CopyBatchResult?
    public private(set) var restorePlanTitle = "Review export"
    public private(set) var recoveryAttempt: BackupAttempt?
    public private(set) var pendingAttempts: [BackupAttempt] = []
    public private(set) var recoveryWarnings: [OperationWarning] = []
    public private(set) var operationID: OperationID?
    public private(set) var operationEvent: OperationEvent?
    public private(set) var operationTitle: String?
    public private(set) var operationKind: OperationKind?
    public private(set) var restoreResult: RestoreBatchResult?
    public private(set) var isPlanningBackup = false
    public private(set) var isPlanningExport = false
    public private(set) var restorePlanningProgress: RestorePlanningProgress?
    public private(set) var progressSession: OperationProgressSession?
    public var isShowingPhoneRestoreSetup = false
    public private(set) var isPlanningCopy = false
    public private(set) var isStartingOperation = false
    public private(set) var isLoadingFolder = false
    public private(set) var isRefreshingDevices = false
    public var isShowingBackupReview = false
    public var isShowingExportReview = false
    public var isShowingCopyReview = false
    public private(set) var requiresRepositoryRecoveryConfirmation = false
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?

    @ObservationIgnored private var services: AppServices
    @ObservationIgnored private let adbResolver: (URL?) -> URL?
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let locationAccess: BackupLocationAccess
    @ObservationIgnored private var planningTask: Task<BackupPlan, Error>?
    @ObservationIgnored private var copyPlanningTask: Task<CopyPlan, Error>?
    @ObservationIgnored private var restorePlanningTask: Task<RestorePlan, Error>?
    @ObservationIgnored private var restorePlanningRequest: UUID?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var activeOperationKind: ActiveOperationKind?
    @ObservationIgnored private var activeActivityID: UUID?
    @ObservationIgnored private var copyScopedURLs: [URL] = []
    @ObservationIgnored private var activeCopyRequest: CopyRequest?
    @ObservationIgnored private var activeRestoreRequest: RestoreRequest?
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var overviewRequest = UUID()
    @ObservationIgnored private var restorePointRequest = UUID()
    @ObservationIgnored private var loadedRepositoryLocation: URL?

    public var isOperationRunning: Bool { operationID != nil }
    public var isBusy: Bool { isPlanningBackup || isPlanningExport || isPlanningCopy || isStartingOperation || isOperationRunning || isRefreshingDevices }
    public var backupLocationNeedsAttention: Bool {
        requiresRepositoryRecoveryConfirmation || (backupLocation != nil && loadedRepositoryLocation != backupLocation)
    }
    public var hasADB: Bool { services.deviceTransport != nil }
    public var adbExecutableURL: URL? { services.adbExecutable }
    public var selectedRepository: BackupRepositoryInfo? {
        repositories.first(where: { $0.id == selectedRepositoryID })
    }
    public var restoreTargetIsPhone: Bool {
        guard let target = restorePlan?.request.target else { return false }
        return isPhoneRestoreTarget(target)
    }

    public init(services: AppServices = .live(), preferences: AppPreferences = .standard,
                locationAccess: BackupLocationAccess = BackupLocationAccess(),
                activityStore: ActivityStore = ActivityStore(), loadOnStart: Bool = true,
                adbResolver: @escaping (URL?) -> URL? = { ADBExecutableResolver.resolve(preferredExecutable: $0) }) {
        self.adbResolver = adbResolver
        self.services = services
        self.preferences = preferences
        self.locationAccess = locationAccess
        self.fileBrowser = RemoteBrowserModel(remote: services.remoteAccess)
        self.activityStore = activityStore
        if let executable = services.adbExecutable {
            preferences.adbExecutablePath = executable.path
        }
        if loadOnStart {
            Task {
                await loadSavedDestination()
                await refreshDevices()
            }
        }
    }

    public func refreshDevices() async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        guard let transport = services.deviceTransport else {
            devices = []
            selectedDevice = nil
            fileBrowser.setDevice(nil)
            await refreshDeviceBackupSummary()
            if services.adbExecutable == nil { statusMessage = "Android Debug Bridge was not found." }
            return
        }
        do {
            let found = try await transport.connectedDevices()
            devices = found
            if let current = selectedDevice, let refreshed = found.first(where: { $0.id == current.id }) {
                selectedDevice = refreshed
                fileBrowser.setDevice(refreshed)
            } else {
                selectedDevice = found.first(where: { $0.state == .device }) ?? found.first
                if let selectedDevice { loadSavedSelection(for: selectedDevice.id) }
                fileBrowser.setDevice(selectedDevice)
            }
            statusMessage = found.isEmpty ? "No Android device is connected." : nil
            errorMessage = nil
            await refreshDeviceBackupSummary()
        } catch {
            devices = []
            selectedDevice = nil
            fileBrowser.setDevice(nil)
            await refreshDeviceBackupSummary()
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func selectDevice(_ device: AndroidDevice) {
        guard !isBusy else { return }
        contextGeneration += 1
        selectedDevice = device
        invalidateDeviceBackupSummary()
        fileBrowser.setDevice(device)
        loadSavedSelection(for: device.id)
        backupPlan = nil
        isShowingBackupReview = false
        recoveryAttempt = nil
        recoveryWarnings = []
        pendingAttempts = []
        selectedRepositoryID = nil
        restorePoints = []
        selectedRestorePoint = nil
        restorePointRequest = UUID()
        isLoadingRestorePoint = false
        restorePointError = nil
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
            restorePointRequest = UUID()
            isLoadingRestorePoint = false
            restorePointError = nil
            restoreEntries = []
        }
        Task { await refreshDeviceBackupSummary() }
    }

    public func setBackupSelection(_ selection: BackupSelection) {
        backupSelection = selection
        backupPlan = nil
        isShowingBackupReview = false
        contextGeneration += 1
        if let device = selectedDevice { preferences.save(selection, for: device.id) }
    }

    @discardableResult
    public func applyBackupSelection(_ selection: BackupSelection, for expectedDevice: DeviceID) -> Bool {
        guard !isBusy, selectedDevice?.id == expectedDevice, selectedDevice?.state == .device,
              devices.contains(where: { $0.id == expectedDevice && $0.state == .device }) else { return false }
        setBackupSelection(selection)
        return true
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
        loadedRepositoryLocation = nil
        do {
            try await closeOpenRepositories()
            let bookmark = try locationAccess.select(url)
            preferences.locationBookmark = bookmark
            backupLocation = url.standardizedFileURL
            requiresRepositoryRecoveryConfirmation = false
            repositories = try await services.repositoryStore.openRepositories(in: url)
            loadedRepositoryLocation = url.standardizedFileURL
            selectedRepositoryID = repositories.first(where: { $0.deviceID == selectedDevice?.id })?.id ?? repositories.first?.id
            preferences.knownRepositoryIDs = repositories.map { $0.id.id }
            if let selectedRepositoryID {
                await loadRestorePoints(for: selectedRepositoryID)
                await loadPendingAttempts(for: selectedRepositoryID)
            }
            else { restorePoints = []; selectedRestorePoint = nil; restoreEntries = [] }
            await refreshDeviceBackupSummary()
            errorMessage = nil
        } catch {
            invalidateDeviceBackupSummary()
            deviceBackupSummary = .unavailable
            errorMessage = UserFacingError.message(for: error)
        }
    }

    public func authorizeNewRepositoryAtSelectedLocation() {
        requiresRepositoryRecoveryConfirmation = false
        Task { await refreshDeviceBackupSummary() }
    }

    public func locateADB(at url: URL) {
        guard !isBusy else { return }
        guard ADBExecutableResolver.isExecutableFile(at: url) else {
            errorMessage = "Choose an executable ADB file, then try again."
            return
        }
        configureADB(at: url)
        Task { await refreshDevices() }
    }

    /// Rediscovers tools installed after launch. Device discovery never opens phone folders.
    public func recheckADB() async {
        guard !isBusy else { return }
        let preferred = preferences.adbExecutablePath.map { URL(fileURLWithPath: $0) }
        if let executable = adbResolver(preferred), ADBExecutableResolver.isExecutableFile(at: executable) {
            configureADB(at: executable)
            await refreshDevices()
        } else {
            services = AppServices(repositoryStore: services.repositoryStore)
            fileBrowser.updateRemote(nil)
            await refreshDevices()
            errorMessage = "ADB wasn’t found. Install Platform Tools or locate the adb file, then check again."
        }
    }

    private func configureADB(at url: URL) {
        preferences.adbExecutablePath = url.standardizedFileURL.path
        guard services.adbExecutable?.standardizedFileURL != url.standardizedFileURL || !hasADB else { return }
        services = services.usingADB(at: url)
        fileBrowser.updateRemote(services.remoteAccess, preservingListing: true)
    }

    public func browseFiles() async {
        guard let selectedDevice else {
            errorMessage = "Connect and authorize an Android device before browsing files."
            return
        }
        fileBrowser.setDevice(selectedDevice)
        section = .files
        await fileBrowser.openRoot()
    }

    public func makeRemoteBrowser(for deviceID: DeviceID) -> RemoteBrowserModel? {
        guard let device = devices.first(where: { $0.id == deviceID && $0.state == .device }) else { return nil }
        let browser = RemoteBrowserModel(remote: services.remoteAccess)
        browser.setDevice(device)
        return browser
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
        guard !backupLocationNeedsAttention else {
            errorMessage = "Locate the backup folder before starting a new backup."
            return
        }
        guard !backupSelection.normalizedRoots.isEmpty else {
            errorMessage = "Choose at least one folder or select All shared files."
            return
        }
        let progressID = beginProgress(.backup, stage: .planning)
        isPlanningBackup = true
        errorMessage = nil
        backupPlan = nil
        let generation = contextGeneration
        let selection = backupSelection
        let task = Task {
            let repository = try await self.repository(for: device, createIfMissing: true, at: backupLocation)
            try Task.checkCancellation()
            return try await engine.plan(repository: repository.id, device: device.id, selection: selection)
        }
        planningTask = task
        defer { planningTask = nil; isPlanningBackup = false }
        do {
            let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard progressSession?.id == progressID, progressSession?.cancellationRequested != true,
                  generation == contextGeneration, selectedDevice?.id == device.id,
                  self.backupLocation == backupLocation else {
                finishPreparationProgress(progressID, cancelled: true)
                return
            }
            backupPlan = plan
            finishPreparationProgress(progressID)
            isShowingBackupReview = true
            if plan.omissions.isEmpty { statusMessage = nil }
        } catch is CancellationError {
            finishPreparationProgress(progressID, cancelled: true)
        } catch {
            finishPreparationProgress(progressID, error: error)
        }
    }

    public func cancelPlanning() {
        guard isPlanningBackup else { return }
        progressSession?.cancellationRequested = true
        planningTask?.cancel()
    }

    public func cancelBackupReview() {
        guard !isStartingOperation else { return }
        isShowingBackupReview = false
        backupPlan = nil
    }

    public func startBackup() async {
        guard !isBusy, let plan = backupPlan, let engine = services.backupEngine else { return }
        let progressID = beginProgress(.backup, stage: .starting)
        isShowingBackupReview = false
        backupPlan = nil
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            let operation = try await engine.startBackup(using: plan.id, omissions: .requireComplete)
            isShowingBackupReview = false
            backupPlan = nil
            restoreResult = nil
            copyResult = nil
            statusMessage = nil
            monitorBackup(operation, engine: engine, repository: plan.repository)
        } catch {
            finishPreparationProgress(progressID, error: error)
        }
    }

    public func retryBackup() async {
        await retryBackup(recoveryAttempt)
    }

    public func retryBackup(_ attempt: BackupAttempt?) async {
        guard !isBusy, let attempt, let engine = services.backupEngine else { return }
        let progressID = beginProgress(.backup, stage: .starting)
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            let operation = try await engine.resumeBackup(attempt.id, omissions: .requireComplete)
            recoveryAttempt = nil
            recoveryWarnings = []
            pendingAttempts.removeAll { $0.id == attempt.id }
            monitorBackup(operation, engine: engine, repository: attempt.repository)
        } catch {
            finishPreparationProgress(progressID, error: error)
        }
    }

    public func finishBackupWithOmissions() async {
        await finishBackupWithOmissions(recoveryAttempt)
    }

    public func finishBackupWithOmissions(_ attempt: BackupAttempt?) async {
        guard !isBusy, let attempt, let engine = services.backupEngine else { return }
        let progressID = beginProgress(.backup, stage: .starting)
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            let operation = try await engine.finishWithOmissions(attempt.id)
            recoveryAttempt = nil
            pendingAttempts.removeAll { $0.id == attempt.id }
            monitorBackup(operation, engine: engine, repository: attempt.repository)
        } catch {
            finishPreparationProgress(progressID, error: error)
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
        case .copy: if let copyEngine = services.copyEngine { await copyEngine.cancel(operationID) }
        case nil: break
        }
    }

    public func planPhoneToMacCopy(roots: [RemotePath], destination: URL) async {
        guard !isBusy, let device = selectedDevice, device.state == .device,
              let engine = services.copyEngine else {
            errorMessage = "Connect and authorize an Android device before copying files."
            return
        }
        beginCopyAccess([destination])
        await planCopy(.phoneToMac(device: device.id, roots: roots, destination: destination), using: engine)
    }

    public func planMacToPhoneCopy(sources: [URL], destination: RemotePath,
                                   replacingMissingTargets: Set<RemotePath> = []) async {
        guard !isBusy, let device = selectedDevice, device.state == .device,
              let engine = services.copyEngine else {
            errorMessage = "Connect and authorize an Android device before copying files."
            return
        }
        beginCopyAccess(sources)
        await planCopy(.macToPhone(device: device.id, sources: sources, destination: destination,
                                   replaceMissingTargets: replacingMissingTargets), using: engine)
    }

    private func prepareCopy(_ request: CopyRequest, using engine: any CopyEngine,
                             requiresReview: Bool = true) async throws -> CopyPlan {
        let progressID = beginProgress(.copy, stage: .planning)
        isPlanningCopy = true
        errorMessage = nil
        statusMessage = nil
        let generation = contextGeneration
        let task = Task { try await engine.planCopy(request) }
        copyPlanningTask = task
        defer { isPlanningCopy = false; copyPlanningTask = nil }
        do {
            let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard progressSession?.id == progressID, progressSession?.cancellationRequested != true,
                  generation == contextGeneration else { throw CancellationError() }
            if requiresReview { finishPreparationProgress(progressID) }
            else { progressSession?.stage = .starting }
            return plan
        } catch is CancellationError {
            finishPreparationProgress(progressID, cancelled: true)
            throw CancellationError()
        } catch {
            finishPreparationProgress(progressID, error: error)
            throw error
        }
    }

    private func planCopy(_ request: CopyRequest, using engine: any CopyEngine) async {
        do {
            copyPlan = try await prepareCopy(request, using: engine)
            isShowingCopyReview = true
        } catch {
            endCopyAccess()
        }
    }

    public func startCopy(replacing conflicts: Set<UUID>) async {
        guard !isBusy, let plan = copyPlan, let engine = services.copyEngine else { return }
        let progressID = beginProgress(.copy, stage: .starting)
        isShowingCopyReview = false
        copyPlan = nil
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            activeCopyRequest = plan.request
            let operation = try await engine.startCopy(plan.id, replacing: conflicts)
            isShowingCopyReview = false
            copyPlan = nil
            copyResult = nil
            restoreResult = nil
            statusMessage = nil
            monitorCopy(operation, engine: engine)
        } catch {
            if case EngineError.safeNoOverwriteUnavailable(let path) = error {
                if await replanCopyWithExplicitMissingTarget(plan.request, path: path, engine: engine) {
                    activeCopyRequest = nil
                    return
                } else {
                    endCopyAccess()
                    copyPlan = nil
                    isShowingCopyReview = false
                }
            } else {
                endCopyAccess()
                copyPlan = nil
                isShowingCopyReview = false
                finishPreparationProgress(progressID, error: error)
            }
            activeCopyRequest = nil
        }
    }

    private func replanCopyWithExplicitMissingTarget(_ request: CopyRequest, path: RemotePath,
                                                       engine: any CopyEngine) async -> Bool {
        guard case .macToPhone(let device, let sources, let destination, _) = request else { return false }
        await planCopy(.macToPhone(device: device, sources: sources, destination: destination,
                                   replaceMissingTargets: [path]), using: engine)
        guard isShowingCopyReview else { return false }
        copyResult = nil
        statusMessage = "Android cannot safely create this file without replacement. Review the exact missing path and explicitly approve the replacement before continuing."
        return true
    }

    public func cancelCopyReview() {
        isShowingCopyReview = false
        copyPlan = nil
        endCopyAccess()
    }

    public func writeRemoteFilePromise(_ entry: RemoteEntry, from deviceID: DeviceID, to destination: URL) async throws {
        guard !isBusy else { throw EngineError.transport("Another operation is already running") }
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            throw EngineError.deviceUnavailable(deviceID)
        }
        guard device.state == .device else { throw EngineError.deviceUnavailable(device.id) }
        guard let engine = services.copyEngine else { throw EngineError.adbUnavailable("Copy engine unavailable") }
        let plan = try await prepareCopy(.phoneToMac(device: device.id, roots: [entry.path],
                                                     destination: destination.deletingLastPathComponent()),
                                         using: engine, requiresReview: false)
        guard plan.conflicts.isEmpty,
              plan.mappings.contains(where: { $0.destination == .local(destination) }) else {
            let error = EngineError.destinationConflict(TransferConflict(destination: destination.path, kind: .fileExists))
            if let id = progressSession?.id { finishPreparationProgress(id, error: error) }
            throw error
        }
        isStartingOperation = true
        let operation: OperationID
        do {
            operation = try await engine.startCopy(plan.id, replacing: [])
            isStartingOperation = false
        } catch {
            isStartingOperation = false
            if let id = progressSession?.id { finishPreparationProgress(id, error: error) }
            throw error
        }
        monitorCopy(operation, engine: engine)
        let stream = await engine.events(for: operation)
        var terminal: OperationEvent?
        for await event in stream where event.phase.isTerminal { terminal = event; break }
        guard terminal?.phase == .completed,
              let result = await engine.result(for: operation),
              !result.items.isEmpty,
              result.items.allSatisfy({ $0.state == .publishedAndVerified }) else {
            throw terminal?.failure ?? EngineError.transport("The promised file was not fully verified")
        }
    }

    public func selectRepository(_ id: RepositoryID) async {
        guard !isBusy, repositories.contains(where: { $0.id == id }) else { return }
        contextGeneration += 1
        selectedRepositoryID = id
        restorePoints = []
        recoveryAttempt = nil
        recoveryWarnings = []
        pendingAttempts = []
        selectedRestorePoint = nil
        restorePointRequest = UUID()
        isLoadingRestorePoint = false
        restorePointError = nil
        selectedRestoreRoots = []
        restoreEntries = []
        restorePlan = nil
        isShowingExportReview = false
        await loadPendingAttempts(for: id)
        await loadRestorePoints(for: id)
    }

    public func selectRestorePoint(_ point: RestorePoint) async {
        guard !isBusy, let repository = selectedRepositoryID,
              restorePoints.contains(where: { $0.id == point.id }) else { return }
        contextGeneration += 1
        let request = UUID()
        restorePointRequest = request
        selectedRestorePoint = point
        selectedRestoreRoots = []
        restoreEntries = []
        restorePlan = nil
        isShowingExportReview = false
        isLoadingRestorePoint = true
        restorePointError = nil
        do {
            let entries = try await services.repositoryStore.entries(in: repository, point: point.id, below: nil)
            guard restorePointRequest == request, selectedRepositoryID == repository,
                  selectedRestorePoint?.id == point.id else { return }
            restoreEntries = entries
            isLoadingRestorePoint = false
        } catch {
            guard restorePointRequest == request, selectedRepositoryID == repository,
                  selectedRestorePoint?.id == point.id else { return }
            restoreEntries = []
            isLoadingRestorePoint = false
            restorePointError = UserFacingError.message(for: error)
        }
    }

    public func toggleRestoreRoot(_ path: RemotePath) {
        guard !isBusy, !isLoadingRestorePoint, restoreEntries.contains(where: { $0.path == path }) else { return }
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
        let request = RestoreRequest(repository: repository, point: point.id,
                                     selectedRoots: Array(selectedRestoreRoots),
                                     target: .localFolder(folder, sourceBase: sourceBase))
        await planRestore(request, title: "Review export")
    }

    public func planPhoneRestore(to folder: RemotePath?, policy: PhoneRestoreConflictPolicy) async {
        guard !isBusy, let repositoryInfo = selectedRepository,
              let point = selectedRestorePoint, !selectedRestoreRoots.isEmpty else { return }
        guard devices.contains(where: { $0.id == repositoryInfo.deviceID && $0.state == .device }) else {
            errorMessage = "Connect and authorize the Android device that owns this backup before restoring to it."
            return
        }
        let selectedEntries = selectedRestoreRoots.compactMap { root in restoreEntries.first { $0.path == root } }
        guard selectedEntries.count == selectedRestoreRoots.count,
              let sourceBase = ExportMapping.commonSourceBase(for: selectedEntries) else {
            errorMessage = "Select one or more files or folders to restore."
            return
        }
        let target: RestoreTarget = folder.map { .phoneFolder($0, sourceBase: sourceBase) } ?? .originalPhonePaths
        let request = RestoreRequest(repository: repositoryInfo.id, point: point.id,
                                     selectedRoots: Array(selectedRestoreRoots), target: target, phoneConflictPolicy: policy)
        let title = folder.map { "Review phone restore to \($0.description)" } ?? "Review phone restore"
        await planRestore(request, title: title)
    }

    private func planRestore(_ request: RestoreRequest, title: String) async {
        let progressID = beginProgress(isPhoneRestoreTarget(request.target) ? .restore : .export, stage: .planning)
        isShowingPhoneRestoreSetup = false
        let generation = contextGeneration
        let token = UUID()
        restorePlanningRequest = token
        isPlanningExport = true
        restorePlan = nil
        restorePlanningProgress = RestorePlanningProgress(stage: .verifyingBackup, completedItems: 0, totalItems: 0)
        statusMessage = nil
        errorMessage = nil
        let update: @Sendable (RestorePlanningProgress) async -> Void = { [weak self] progress in
            await self?.updateRestorePlanning(progress, token: token)
        }
        let engine = services.restoreEngine
        let task = Task { try await engine.planRestore(request, progress: update) }
        restorePlanningTask = task
        defer {
            if restorePlanningRequest == token {
                restorePlanningRequest = nil
                restorePlanningTask = nil
                restorePlanningProgress = nil
                isPlanningExport = false
            }
        }
        do {
            let plan = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard restorePlanningRequest == token, progressSession?.id == progressID,
                  progressSession?.cancellationRequested != true, generation == contextGeneration,
                  selectedRepositoryID == request.repository,
                  selectedRestorePoint?.id == request.point,
                  selectedRestoreRoots == Set(request.selectedRoots) else { throw CancellationError() }
            restorePlan = plan
            restorePlanTitle = title
            finishPreparationProgress(progressID)
            isShowingExportReview = true
            errorMessage = nil
        } catch is CancellationError {
            finishPreparationProgress(progressID, cancelled: true)
        } catch {
            guard restorePlanningRequest == token, generation == contextGeneration else { return }
            finishPreparationProgress(progressID, error: error)
        }
    }

    private func updateRestorePlanning(_ progress: RestorePlanningProgress, token: UUID) {
        guard restorePlanningRequest == token else { return }
        restorePlanningProgress = progress
    }

    public func cancelRestorePlanning() {
        guard isPlanningExport else { return }
        progressSession?.cancellationRequested = true
        restorePlanningTask?.cancel()
    }

    public func startLocalExport(replacing conflicts: Set<UUID>) async {
        await startRestore(replacing: conflicts)
    }

    public func startRestore(replacing conflicts: Set<UUID>) async {
        guard !isBusy, let plan = restorePlan else { return }
        let progressID = beginProgress(isPhoneRestoreTarget(plan.request.target) ? .restore : .export, stage: .starting)
        isShowingExportReview = false
        restorePlan = nil
        isStartingOperation = true
        defer { isStartingOperation = false }
        do {
            restoreResult = nil
            activeRestoreRequest = plan.request
            let operation = try await services.restoreEngine.startRestore(plan.id, replacing: conflicts)
            isShowingExportReview = false
            restorePlan = nil
            copyResult = nil
            statusMessage = nil
            monitorRestore(operation, title: restorePlanTitle.replacingOccurrences(of: "Review ", with: ""))
        } catch {
            activeRestoreRequest = nil
            restorePlan = nil
            isShowingExportReview = false
            finishPreparationProgress(progressID, error: error)
        }
    }

    private func isPhoneRestoreTarget(_ target: RestoreTarget) -> Bool {
        switch target {
        case .originalPhonePaths, .phoneFolder: true
        case .localFolder: false
        }
    }

    public func cancelExportReview() {
        isShowingExportReview = false
        restorePlan = nil
    }

    public func clearStatus() {
        statusMessage = nil
        errorMessage = nil
        if !isBusy {
            progressSession = nil
            operationEvent = nil
            operationTitle = nil
            operationKind = nil
            restoreResult = nil
            copyResult = nil
        }
    }

    @discardableResult
    private func beginProgress(_ kind: OperationKind, stage: OperationProgressSession.Stage) -> UUID {
        let session = OperationProgressSession(kind: kind, stage: stage)
        progressSession = session
        return session.id
    }

    private func finishPreparationProgress(_ id: UUID, error: Error? = nil, cancelled: Bool = false) {
        guard progressSession?.id == id else { return }
        if let error {
            progressSession?.stage = .finished
            progressSession?.failure = UserFacingError.message(for: error)
        } else if cancelled || progressSession?.cancellationRequested == true {
            progressSession?.stage = .finished
            progressSession?.wasCancelled = true
        } else {
            // Review remains the only route from preparation to a transfer.
            progressSession = nil
        }
    }

    private func finishOperationProgress(_ id: UUID?) {
        guard let id, progressSession?.id == id else { return }
        progressSession?.stage = .finished
    }

    public func showProgress() {
        if progressSession == nil {
            beginProgress(operationKind ?? .backup, stage: isOperationRunning ? .running : .finished)
        } else { progressSession?.isPresented = true }
    }
    public func backgroundProgress() { progressSession?.isPresented = false }

    public func dismissProgress() {
        guard !isBusy else { backgroundProgress(); return }
        clearStatus()
    }

    public var canCancelProgress: Bool {
        guard let session = progressSession, !session.cancellationRequested else { return false }
        switch session.stage {
        case .planning: return true
        case .running: return isOperationRunning && operationEvent?.phase.isTerminal != true
        case .starting, .finished: return false
        }
    }

    public func cancelProgress() async {
        guard canCancelProgress else { return }
        progressSession?.cancellationRequested = true
        if progressSession?.stage == .planning {
            switch progressSession?.kind {
            case .backup: cancelPlanning()
            case .copy: copyPlanningTask?.cancel()
            case .restore, .export: cancelRestorePlanning()
            case nil: break
            }
        } else { await cancelOperation() }
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    private func beginCopyAccess(_ urls: [URL]) {
        endCopyAccess()
        copyScopedURLs = urls.map(\.standardizedFileURL).filter { $0.startAccessingSecurityScopedResource() }
    }

    private func endCopyAccess() {
        copyScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        copyScopedURLs = []
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
            loadedRepositoryLocation = url.standardizedFileURL
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
        invalidateDeviceBackupSummary()
        selectedRepositoryID = nil
        restorePoints = []
        selectedRestorePoint = nil
        restorePointRequest = UUID()
        isLoadingRestorePoint = false
        restorePointError = nil
        selectedRestoreRoots = []
        restoreEntries = []
        pendingAttempts = []
        recoveryAttempt = nil
        recoveryWarnings = []
        restorePlan = nil
        isShowingExportReview = false
    }

    private func invalidateDeviceBackupSummary() {
        overviewRequest = UUID()
        deviceBackupSummary = selectedDevice == nil ? .noDevice : (backupLocation == nil ? .noLocation : .loading)
    }

    /// Overview facts are independent from library browsing and never enumerate phone files.
    public func refreshDeviceBackupSummary() async {
        let request = UUID()
        overviewRequest = request
        guard let device = selectedDevice else { deviceBackupSummary = .noDevice; return }
        guard let location = backupLocation else { deviceBackupSummary = .noLocation; return }
        guard !backupLocationNeedsAttention else { deviceBackupSummary = .unavailable; return }
        guard let repository = repositories.first(where: { $0.deviceID == device.id }) else {
            deviceBackupSummary = .loaded(DeviceBackupSummary(points: []))
            return
        }
        deviceBackupSummary = .loading
        do {
            let points = try await services.repositoryStore.restorePoints(in: repository.id)
            guard overviewRequest == request, selectedDevice?.id == device.id, backupLocation == location,
                  repositories.first(where: { $0.deviceID == device.id })?.id == repository.id else { return }
            deviceBackupSummary = .loaded(DeviceBackupSummary(points: points))
        } catch {
            guard overviewRequest == request, selectedDevice?.id == device.id, backupLocation == location,
                  repositories.first(where: { $0.deviceID == device.id })?.id == repository.id else { return }
            deviceBackupSummary = .unavailable
        }
    }

    public func retryDeviceBackupSummary() async {
        guard !isBusy else { return }
        guard let location = backupLocation else { await refreshDeviceBackupSummary(); return }
        guard loadedRepositoryLocation != location || requiresRepositoryRecoveryConfirmation else {
            await refreshDeviceBackupSummary()
            return
        }
        let request = UUID()
        overviewRequest = request
        let deviceID = selectedDevice?.id
        let expected = Set(preferences.knownRepositoryIDs)
        deviceBackupSummary = .loading
        do {
            let reopened = try await services.repositoryStore.openRepositories(in: location)
            guard overviewRequest == request, backupLocation == location, selectedDevice?.id == deviceID else { return }
            repositories = reopened
            loadedRepositoryLocation = location
            if requiresRepositoryRecoveryConfirmation && !expected.isSubset(of: Set(reopened.map { $0.id.id })) {
                deviceBackupSummary = .unavailable
                errorMessage = "The saved folder is missing known backup repositories. Locate the original folder or explicitly use this as a new location."
                return
            }
            requiresRepositoryRecoveryConfirmation = false
            preferences.knownRepositoryIDs = reopened.map { $0.id.id }
            errorMessage = nil
            if !reopened.contains(where: { $0.id == selectedRepositoryID }) {
                if let repository = reopened.first(where: { $0.deviceID == deviceID }) ?? reopened.first {
                    await selectRepository(repository.id)
                    guard overviewRequest == request, backupLocation == location, selectedDevice?.id == deviceID else { return }
                } else {
                    resetRepositoryContext()
                }
            }
            await refreshDeviceBackupSummary()
        } catch {
            guard overviewRequest == request, backupLocation == location, selectedDevice?.id == deviceID else { return }
            deviceBackupSummary = .unavailable
        }
    }

    public func browseDeviceBackups() async {
        section = .backups
        if let device = selectedDevice, let repository = repositories.first(where: { $0.deviceID == device.id }) {
            await selectRepository(repository.id)
        }
    }

    private func loadRestorePoints(for repository: RepositoryID) async {
        do {
            let points = try await services.repositoryStore.restorePoints(in: repository)
            guard selectedRepositoryID == repository else { return }
            restorePoints = points
            errorMessage = nil
        } catch {
            guard selectedRepositoryID == repository else { return }
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
            guard selectedRepositoryID == repository else { return }
            pendingAttempts = []
            errorMessage = UserFacingError.message(for: error)
        }
    }

    private func monitorBackup(_ operation: OperationID, engine: any BackupEngine, repository: RepositoryID) {
        operationID = operation
        activeOperationKind = .backup
        operationKind = .backup
        activeActivityID = activityStore.begin(.backup)
        operationTitle = "Backing up"
        operationEvent = nil
        if progressSession?.stage != .starting {
            beginProgress(operationKind ?? .copy, stage: .running)
        } else { progressSession?.stage = .running }
        let progressID = progressSession?.id
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.events(for: operation)
            var terminal: OperationEvent?
            for await event in stream {
                self.operationEvent = event
                if let id = self.activeActivityID { self.activityStore.update(id, event: event) }
                if event.phase.isTerminal { terminal = event; break }
            }
            await self.finishBackupOperation(operation, engine: engine, repository: repository, terminal: terminal, progressID: progressID)
        }
    }

    private func finishBackupOperation(_ operation: OperationID, engine: any BackupEngine,
                                       repository: RepositoryID, terminal: OperationEvent?, progressID: UUID?) async {
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
            statusMessage = terminal?.warnings.isEmpty == false ? "Backup finished with skipped paths." : "Backup completed and verified."
            await loadRestorePoints(for: repository)
        } else if terminal?.phase == .cancelled {
            statusMessage = "Backup cancelled. The previous restore point remains available."
        } else if terminal?.phase == .failed {
            statusMessage = "Backup failed. The previous restore point remains available."
        }
        await loadPendingAttempts(for: repository)
        await refreshDeviceBackupSummary()
        if let id = activeActivityID {
            let verified = terminal?.phase == .completed ? terminal?.progress.completedItems ?? 0 : 0
            activityStore.setVerifiedItems(verified, for: id)
        }
        activeActivityID = nil
        if operationID == operation { operationID = nil; operationTitle = nil; activeOperationKind = nil }
        finishOperationProgress(progressID)
        operationTask = nil
    }

    private func monitorRestore(_ operation: OperationID, title: String = "Exporting restore point") {
        operationID = operation
        activeOperationKind = .restore
        operationKind = activeRestoreRequest.map { isPhoneRestoreTarget($0.target) ? .restore : .export } ?? .restore
        activeActivityID = activityStore.begin(.restore)
        operationTitle = title
        operationEvent = nil
        if progressSession?.stage != .starting {
            beginProgress(operationKind ?? .copy, stage: .running)
        } else { progressSession?.stage = .running }
        let progressID = progressSession?.id
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.services.restoreEngine.events(for: operation)
            var terminal: OperationEvent?
            for await event in stream {
                self.operationEvent = event
                if let id = self.activeActivityID { self.activityStore.update(id, event: event) }
                if event.phase.isTerminal { terminal = event; break }
            }
            self.restoreResult = await self.services.restoreEngine.result(for: operation)
            if let id = self.activeActivityID {
                self.activityStore.setVerifiedItems(self.restoreResult?.items.filter { $0.state == .publishedAndVerified }.count ?? 0, for: id)
            }
            if terminal?.phase == .completed { self.statusMessage = "Restore completed and verified." }
            else if terminal?.phase == .incomplete { self.statusMessage = "Restore finished with items that need attention." }
            if let request = self.activeRestoreRequest, self.isPhoneRestoreTarget(request.target) {
                self.fileBrowser.invalidateVisitedFolders()
            }
            self.activeRestoreRequest = nil
            if self.operationID == operation { self.operationID = nil; self.operationTitle = nil; self.activeOperationKind = nil }
            self.activeActivityID = nil
            self.finishOperationProgress(progressID)
            self.operationTask = nil
        }
    }

    private func monitorCopy(_ operation: OperationID, engine: any CopyEngine) {
        operationID = operation
        activeOperationKind = .copy
        operationKind = .copy
        activeActivityID = activityStore.begin(.copy)
        operationTitle = "Copying files"
        operationEvent = nil
        if progressSession?.stage != .starting {
            beginProgress(operationKind ?? .copy, stage: .running)
        } else { progressSession?.stage = .running }
        let progressID = progressSession?.id
        operationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.events(for: operation)
            var terminal: OperationEvent?
            for await event in stream {
                self.operationEvent = event
                if let id = self.activeActivityID { self.activityStore.update(id, event: event) }
                if event.phase.isTerminal { terminal = event; break }
            }
            self.copyResult = await engine.result(for: operation)
            if let id = self.activeActivityID {
                self.activityStore.setVerifiedItems(self.copyResult?.items.filter { $0.state == .publishedAndVerified }.count ?? 0, for: id)
            }
            if terminal?.phase == .completed { self.statusMessage = "Files copied and verified." }
            else if terminal?.phase == .incomplete { self.statusMessage = "Copy finished with items that need attention." }
            var presentedReplacementReview = false
            if let failure = terminal?.failure, case EngineError.safeNoOverwriteUnavailable(let path) = failure,
               let request = self.activeCopyRequest {
                presentedReplacementReview = await self.replanCopyWithExplicitMissingTarget(request, path: path, engine: engine)
                if presentedReplacementReview { self.copyResult = nil }
            }
            if let request = self.activeCopyRequest, case .macToPhone = request {
                self.fileBrowser.invalidateVisitedFolders()
            }
            self.activeCopyRequest = nil
            if self.operationID == operation { self.operationID = nil; self.operationTitle = nil; self.activeOperationKind = nil }
            if !presentedReplacementReview { self.endCopyAccess() }
            self.activeActivityID = nil
            self.finishOperationProgress(progressID)
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
