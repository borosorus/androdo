import Foundation

/// Plans complete batches before mutation, then publishes and verifies each file independently.
public actor DefaultRestoreEngine: RestoreEngine {
    private struct RequestRecord {
        let request: RestoreRequest
        let mappings: [RestoreMapping]
        let conflicts: [RestoreConflict]
        let chosenLocalRoot: URL?
        let resolvedLocalRoot: URL?
        let localRootIdentity: String?
    }

    private struct OperationRecord {
        var latestEvent: OperationEvent
        var subscribers: [UUID: AsyncStream<OperationEvent>.Continuation] = [:]
        var finished = false
    }

    private let repositoryStore: any BackupRepositoryWriting
    private let remote: (any RemoteDestinationAccess)?
    private var requests: [RestorePlanID: RequestRecord] = [:]
    private var operations: [OperationID: OperationRecord] = [:]
    private var tasks: [OperationID: Task<Void, Never>] = [:]
    private var activeRepositories: Set<RepositoryID> = []
    private var results: [OperationID: RestoreBatchResult] = [:]

    public init(repositoryStore: any BackupRepositoryWriting, remote: (any RemoteDestinationAccess)? = nil) {
        self.repositoryStore = repositoryStore
        self.remote = remote
    }

    public func planRestore(_ request: RestoreRequest) async throws -> RestorePlan {
        guard !request.selectedRoots.isEmpty else { throw EngineError.emptySelection }
        let restorePoints = try await repositoryStore.restorePoints(in: request.repository)
        guard let point = restorePoints.first(where: { $0.id == request.point }),
              point.state == .completed else {
            throw EngineError.corruptedRepository("Restore point is unavailable or incomplete")
        }
        let info = try await repositoryInfo(request.repository)
        let allEntries = try await repositoryStore.entries(in: request.repository, point: request.point, below: nil)
        let selected = allEntries.filter { entry in
            request.selectedRoots.contains(where: { entry.path.isEqualOrDescendant(of: $0) })
        }.sorted { RemotePath.bytewiseLess($0.path, $1.path) }
        guard !selected.isEmpty else { throw EngineError.emptySelection }
        try Self.validateEntries(selected)
        for entry in selected where entry.kind == .file {
            guard let hash = entry.contentHash else { throw EngineError.corruptedRepository("File entry has no object hash") }
            try await repositoryStore.verifyObject(ContentObjectReference(sha256: hash, size: entry.size),
                                                   in: request.repository)
        }

        let base: RemotePath
        let chosenLocalRoot: URL?
        let resolvedLocalRoot: URL?
        let localRootIdentity: String?
        switch request.target {
        case .localFolder(let folder, let sourceBase):
            base = sourceBase
            chosenLocalRoot = folder.standardizedFileURL
            let resolvedRoot = folder.standardizedFileURL.resolvingSymlinksInPath()
            resolvedLocalRoot = resolvedRoot
            localRootIdentity = try LocalFilePublication.rootIdentity(resolvedRoot)
            guard selected.allSatisfy({ $0.path.isEqualOrDescendant(of: base) }) else {
                throw EngineError.invalidRemotePath("The chosen source base does not contain all selected paths")
            }
        case .phoneFolder(_, let sourceBase):
            base = sourceBase
            chosenLocalRoot = nil
            resolvedLocalRoot = nil
            localRootIdentity = nil
            guard selected.allSatisfy({ $0.path.isEqualOrDescendant(of: base) }) else {
                throw EngineError.invalidRemotePath("The chosen source base does not contain all selected paths")
            }
        case .originalPhonePaths:
            base = .root
            chosenLocalRoot = nil
            resolvedLocalRoot = nil
            localRootIdentity = nil
        }

        var mappings: [RestoreMapping] = []
        for entry in selected {
            let destination: RestoreDestination
            switch request.target {
            case .localFolder:
                guard let resolvedLocalRoot else { throw EngineError.repositoryIO("Local restore folder was not captured") }
                let relative = Array(entry.path.components.dropFirst(base.components.count))
                let url = relative.reduce(resolvedLocalRoot) { $0.appendingPathComponent($1, isDirectory: entry.kind == .directory) }
                destination = .local(url)
            case .originalPhonePaths:
                destination = .phone(entry.path)
            case .phoneFolder(let folder, _):
                let relative = Array(entry.path.components.dropFirst(base.components.count))
                destination = .phone(try RemotePath(components: folder.components + relative))
            }
            mappings.append(RestoreMapping(source: entry, destination: destination))
        }

        var conflicts: [RestoreConflict] = []
        if case .localFolder = request.target {
            guard let destinationRoot = resolvedLocalRoot, let localRootIdentity else {
                throw EngineError.repositoryIO("Local restore folder was not captured")
            }
            guard request.replaceMissingPhoneTargets.isEmpty else {
                throw EngineError.transport("Missing phone replacement approvals apply only to Android destinations")
            }
            let repositories = try await repositoryStore.repositories()
            try Self.requireOutsideRepository(destinationRoot, repositories: repositories)
            var aliases: [String: (raw: Data, mapping: RestoreMapping)] = [:]
            for mapping in mappings {
                guard case .local(let url) = mapping.destination else { continue }
                try Self.requireOutsideRepository(url.standardizedFileURL.resolvingSymlinksInPath(),
                                                  repositories: repositories)
                let components = Self.components(of: url, relativeTo: destinationRoot)
                var normalizedPrefix: [String] = []
                var rawPrefix = Data()
                for component in components {
                    normalizedPrefix.append(component.precomposedStringWithCanonicalMapping.lowercased())
                    rawPrefix.append(contentsOf: component.utf8)
                    rawPrefix.append(0)
                    let aliasKey = normalizedPrefix.joined(separator: "/")
                    if let previous = aliases[aliasKey], previous.raw != rawPrefix {
                        conflicts.append(RestoreConflict(destination: mapping.destination, kind: .caseOrUnicodeAlias,
                                                         replaceable: false))
                        conflicts.append(RestoreConflict(destination: previous.mapping.destination,
                                                         kind: .caseOrUnicodeAlias, replaceable: false))
                    } else if aliases[aliasKey] == nil {
                        aliases[aliasKey] = (rawPrefix, mapping)
                    }
                }
                let state = try LocalFilePublication.inspect(root: destinationRoot, components: components,
                                                             expectedRootIdentity: localRootIdentity)
                conflicts.append(contentsOf: Self.localConflicts(state, destination: mapping.destination,
                                                                 sourceKind: mapping.source.kind))
            }
        } else {
            guard let remote else { throw EngineError.transport("Android restore is unavailable without a connected-device transport") }
            let fileDestinations = Set(mappings.filter { $0.source.kind == .file }.compactMap { mapping -> RemotePath? in
                if case .phone(let path) = mapping.destination { path } else { nil }
            })
            guard request.replaceMissingPhoneTargets.isSubset(of: fileDestinations) else {
                throw EngineError.transport("Replacement approval names a path outside the selected restore files")
            }
            for mapping in mappings {
                guard case .phone(let destination) = mapping.destination else { continue }
                let itemConflicts = try await phoneConflicts(for: mapping, destination: destination,
                                                             device: info.deviceID, remote: remote)
                conflicts.append(contentsOf: itemConflicts)
                if itemConflicts.isEmpty, mapping.source.kind == .file,
                   request.replaceMissingPhoneTargets.contains(destination) {
                    conflicts.append(RestoreConflict(destination: mapping.destination, kind: .fileExists,
                                                     observedIdentity: RestoreConflict.approvedMissingTargetIdentity,
                                                     replaceable: true))
                }
            }
        }
        let totalBytes = try selected.reduce(Int64(0)) { total, entry in
            guard entry.kind == .file else { return total }
            let (next, overflow) = total.addingReportingOverflow(entry.size)
            guard !overflow else { throw EngineError.corruptedRepository("Restore byte count overflow") }
            return next
        }
        let plan = RestorePlan(request: request, mappings: mappings, conflicts: Self.uniqueConflicts(conflicts),
                               totalBytes: totalBytes, fileCount: selected.filter { $0.kind == .file }.count,
                               directoryCount: selected.filter { $0.kind == .directory }.count,
                               sourceOmissions: point.omissions)
        requests[plan.id] = RequestRecord(request: request, mappings: mappings, conflicts: plan.conflicts,
                                          chosenLocalRoot: chosenLocalRoot, resolvedLocalRoot: resolvedLocalRoot,
                                          localRootIdentity: localRootIdentity)
        return plan
    }

    public func startRestore(_ plan: RestorePlanID, replacing conflictsToReplace: Set<UUID> = []) async throws -> OperationID {
        guard let record = requests.removeValue(forKey: plan) else {
            throw EngineError.transport("Restore plan has expired; create a new plan")
        }
        guard activeRepositories.insert(record.request.repository).inserted else {
            throw EngineError.repositoryBusy(try await repositoryInfo(record.request.repository).location)
        }
        do {
            for conflict in record.conflicts {
                guard conflict.replaceable, conflictsToReplace.contains(conflict.id) else {
                    throw EngineError.destinationConflict(TransferConflict(destination: Self.destinationDescription(conflict.destination),
                                                                             kind: Self.engineConflictKind(conflict.kind)))
                }
            }
            guard conflictsToReplace.isSubset(of: Set(record.conflicts.map(\.id))) else {
                throw EngineError.transport("Replacement approval does not belong to this restore plan")
            }
            try await recheckPlan(record, replacing: conflictsToReplace)
            let operation = OperationID()
            operations[operation] = OperationRecord(latestEvent: OperationEvent(operationID: operation, phase: .transferring))
            tasks[operation] = Task { [weak self] in
                guard let self else { return }
                await self.run(operation: operation, record: record, replacing: conflictsToReplace)
            }
            return operation
        } catch {
            activeRepositories.remove(record.request.repository)
            throw error
        }
    }

    public func events(for operation: OperationID) async -> AsyncStream<OperationEvent> {
        let (stream, continuation) = AsyncStream<OperationEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard var record = operations[operation] else { continuation.finish(); return stream }
        continuation.yield(record.latestEvent)
        if record.finished { continuation.finish() }
        else {
            let id = UUID()
            record.subscribers[id] = continuation
            operations[operation] = record
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id, operation: operation) } }
        }
        return stream
    }

    public func cancel(_ operation: OperationID) async { tasks[operation]?.cancel() }
    public func result(for operation: OperationID) async -> RestoreBatchResult? { results[operation] }

    private func run(operation: OperationID, record: RequestRecord, replacing conflictIDs: Set<UUID>) async {
        var itemResults: [RestoreItemResult] = []
        var completedBytes: Int64 = 0
        let totalItems = record.mappings.count
        let batchTotalBytes = Self.totalBytes(record.mappings)
        let expectedByPath = Dictionary(uniqueKeysWithValues: record.conflicts.map { ($0.destination, $0) })
        let replacementIDs = Set(record.conflicts.filter { conflictIDs.contains($0.id) }.map(\.id))
        let info: BackupRepositoryInfo
        do { info = try await repositoryInfo(record.request.repository) }
        catch let error as EngineError {
            appendUnfinished(.skipped, detail: "Repository became unavailable before restore started",
                             mappings: record.mappings, existing: &itemResults)
            emit(OperationEvent(operationID: operation, phase: .failed, failure: error), for: operation)
            finish(operation, record: record, items: itemResults)
            return
        } catch {
            appendUnfinished(.skipped, detail: "Repository became unavailable before restore started",
                             mappings: record.mappings, existing: &itemResults)
            emit(OperationEvent(operationID: operation, phase: .failed, failure: .transport(error.localizedDescription)), for: operation)
            finish(operation, record: record, items: itemResults)
            return
        }

        do {
            for mapping in record.mappings {
                try Task.checkCancellation()
                if mapping.source.kind == .directory {
                    try await ensureDirectory(for: mapping, record: record, device: info.deviceID)
                    itemResults.append(RestoreItemResult(source: mapping.source.path, destination: mapping.destination,
                                                         state: .publishedAndVerified))
                    emitProgress(operation, items: itemResults.count, totalItems: totalItems,
                                 bytes: completedBytes, totalBytes: batchTotalBytes, phase: .transferring)
                    continue
                }
                guard let hash = mapping.source.contentHash else { throw EngineError.corruptedRepository("File entry has no object hash") }
                let reference = ContentObjectReference(sha256: hash, size: mapping.source.size)
                let staged = try await repositoryStore.stageObject(reference, in: record.request.repository)
                do {
                    try Task.checkCancellation()
                    switch mapping.destination {
                    case .local(let destination):
                        guard let root = record.resolvedLocalRoot, let rootIdentity = record.localRootIdentity else {
                            throw EngineError.transport("Local restore plan has an invalid destination mapping")
                        }
                        let components = Self.components(of: destination, relativeTo: root)
                        let conflict = expectedByPath[mapping.destination]
                        try await LocalFilePublication.publish(source: staged, expected: reference,
                                                               modifiedAt: mapping.source.modifiedAt,
                                                               root: root, components: components,
                                                               expectedRootIdentity: rootIdentity,
                                                               replacing: conflict.flatMap { replacementIDs.contains($0.id) ? $0.observedIdentity : nil })
                    case .phone(let destination):
                        guard let remote = remote else { throw EngineError.transport("Android restore transport is unavailable") }
                        try await ensurePhoneDirectories(for: destination.parent ?? .root, device: info.deviceID, remote: remote)
                        let conflict = expectedByPath[mapping.destination]
                        let identity = conflict.flatMap { replacementIDs.contains($0.id) ? $0.observedIdentity : nil }
                        try await remote.publishStagedFile(from: staged, to: destination, on: info.deviceID,
                                                           expected: reference, replacing: identity)
                    }
                } catch {
                    await repositoryStore.discardStagedObject(at: staged, in: record.request.repository)
                    throw error
                }
                await repositoryStore.discardStagedObject(at: staged, in: record.request.repository)
                itemResults.append(RestoreItemResult(source: mapping.source.path, destination: mapping.destination,
                                                     state: .publishedAndVerified))
                completedBytes = try Self.add(mapping.source.size, to: completedBytes)
                emitProgress(operation, items: itemResults.count, totalItems: totalItems,
                             bytes: completedBytes, totalBytes: batchTotalBytes, phase: .transferring)
            }
            emitProgress(operation, items: itemResults.count, totalItems: totalItems,
                         bytes: completedBytes, totalBytes: batchTotalBytes, phase: .verifying)
            emitProgress(operation, items: itemResults.count, totalItems: totalItems,
                         bytes: completedBytes, totalBytes: batchTotalBytes, phase: .committing)
            emitProgress(operation, items: itemResults.count, totalItems: totalItems,
                         bytes: completedBytes, totalBytes: batchTotalBytes, phase: .completed)
            finish(operation, record: record, items: itemResults)
        } catch is CancellationError {
            appendUnfinished(.cancelled, detail: "Restore cancelled", mappings: record.mappings,
                             existing: &itemResults)
            emit(OperationEvent(operationID: operation, phase: .cancelled,
                                progress: OperationProgress(completedItems: itemResults.filter { $0.state == .publishedAndVerified }.count,
                                                            totalItems: totalItems, completedBytes: completedBytes,
                                                            totalBytes: batchTotalBytes)), for: operation)
            finish(operation, record: record, items: itemResults)
        } catch let error as EngineError {
            let isPublishedUnverified: Bool
            if case .destinationPublishedUnverified = error { isPublishedUnverified = true }
            else { isPublishedUnverified = false }
            if let current = record.mappings.dropFirst(itemResults.count).first {
                itemResults.append(RestoreItemResult(source: current.source.path, destination: current.destination,
                                                     state: isPublishedUnverified ? .publishedUnverified : .failed,
                                                     detail: String(describing: error)))
            }
            appendUnfinished(.skipped, detail: "Not attempted after an earlier failure", mappings: record.mappings,
                             existing: &itemResults)
            let hasPublishedItems = itemResults.contains { $0.state == .publishedAndVerified || $0.state == .publishedUnverified }
            emit(OperationEvent(operationID: operation, phase: hasPublishedItems ? .incomplete : .failed,
                                progress: OperationProgress(completedItems: itemResults.filter { $0.state == .publishedAndVerified || $0.state == .publishedUnverified }.count,
                                                            totalItems: totalItems, completedBytes: completedBytes,
                                                            totalBytes: batchTotalBytes), failure: error), for: operation)
            finish(operation, record: record, items: itemResults)
        } catch {
            let failure = EngineError.transport(error.localizedDescription)
            if let current = record.mappings.dropFirst(itemResults.count).first {
                itemResults.append(RestoreItemResult(source: current.source.path, destination: current.destination,
                                                     state: .failed, detail: failure.localizedDescription))
            }
            appendUnfinished(.skipped, detail: "Not attempted after an earlier failure", mappings: record.mappings,
                             existing: &itemResults)
            emit(OperationEvent(operationID: operation, phase: .incomplete, failure: failure), for: operation)
            finish(operation, record: record, items: itemResults)
        }
    }

    private func ensureDirectory(for mapping: RestoreMapping, record: RequestRecord, device: DeviceID) async throws {
        switch mapping.destination {
        case .local(let destination):
            guard let root = record.resolvedLocalRoot, let rootIdentity = record.localRootIdentity else {
                throw EngineError.transport("Invalid local directory mapping")
            }
            try LocalFilePublication.ensureDirectory(root: root, components: Self.components(of: destination, relativeTo: root),
                                                     expectedRootIdentity: rootIdentity)
        case .phone(let destination):
            guard let remote else { throw EngineError.transport("Android restore transport is unavailable") }
            try await ensurePhoneDirectories(for: destination, device: device, remote: remote)
        }
    }

    private func recheckPlan(_ record: RequestRecord, replacing approved: Set<UUID>) async throws {
        let info = try await repositoryInfo(record.request.repository)
        for mapping in record.mappings {
            switch mapping.destination {
            case .local(let destination):
                guard let chosenRoot = record.chosenLocalRoot, let root = record.resolvedLocalRoot,
                      let rootIdentity = record.localRootIdentity,
                      chosenRoot.resolvingSymlinksInPath() == root,
                      try LocalFilePublication.rootIdentity(root) == rootIdentity else {
                    throw EngineError.destinationConflict(TransferConflict(destination: "chosen local folder", kind: .unsafePath))
                }
                let state = try LocalFilePublication.inspect(root: root, components: Self.components(of: destination, relativeTo: root),
                                                             expectedRootIdentity: rootIdentity)
                try Self.compare(state, destination: mapping.destination, sourceKind: mapping.source.kind,
                                 conflict: record.conflicts.first(where: { $0.destination == mapping.destination }),
                                 approved: approved)
            case .phone(let destination):
                guard let remote else { throw EngineError.transport("Android restore transport is unavailable") }
                try await validatePhoneAncestors(destination, device: info.deviceID, remote: remote)
                let state = try await remote.inspectDestination(destination, on: info.deviceID)
                try Self.compare(state, destination: mapping.destination, sourceKind: mapping.source.kind,
                                 conflict: record.conflicts.first(where: { $0.destination == mapping.destination }),
                                 approved: approved)
            }
        }
    }

    private func phoneConflicts(for mapping: RestoreMapping, destination: RemotePath, device: DeviceID,
                                remote: any RemoteDestinationAccess) async throws -> [RestoreConflict] {
        try await validatePhoneAncestors(destination, device: device, remote: remote)
        let state = try await remote.inspectDestination(destination, on: device)
        return Self.phoneConflicts(state, destination: mapping.destination, sourceKind: mapping.source.kind)
    }

    private func validatePhoneAncestors(_ destination: RemotePath, device: DeviceID,
                                        remote: any RemoteDestinationAccess) async throws {
        var current = RemotePath.root
        for (index, component) in destination.components.enumerated() {
            current = try current.appending(component)
            if index == 0 && component == "sdcard" { continue } // Android's conventional /sdcard alias is intentional.
            if current == destination { break }
            switch try await remote.inspectDestination(current, on: device) {
            case .missing: return
            case .directory: continue
            case .regularFile, .symbolicLink, .other:
                throw EngineError.destinationConflict(TransferConflict(destination: current.description, kind: .unsafePath))
            }
        }
    }

    private func ensurePhoneDirectories(for destination: RemotePath, device: DeviceID,
                                        remote: any RemoteDestinationAccess) async throws {
        var current = RemotePath.root
        for (index, component) in destination.components.enumerated() {
            current = try current.appending(component)
            if index == 0 && component == "sdcard" { continue }
            switch try await remote.inspectDestination(current, on: device) {
            case .directory: continue
            case .missing: try await remote.createDestinationDirectory(current, on: device)
            case .regularFile, .symbolicLink, .other:
                throw EngineError.destinationConflict(TransferConflict(destination: current.description, kind: .unsafePath))
            }
        }
    }

    private static func localConflicts(_ state: LocalFilePublication.LocalDestinationState,
                                      destination: RestoreDestination, sourceKind: RemoteEntryKind) -> [RestoreConflict] {
        switch (state, sourceKind) {
        case (.missing, _), (.directory, .directory): return []
        case (.regularFile(let identity, _), .file):
            return [RestoreConflict(destination: destination, kind: .fileExists, observedIdentity: identity, replaceable: true)]
        case (.directory(let identity), .file):
            return [RestoreConflict(destination: destination, kind: .directoryExists, observedIdentity: identity, replaceable: false)]
        case (.regularFile(let identity, _), .directory):
            return [RestoreConflict(destination: destination, kind: .directoryExists, observedIdentity: identity, replaceable: false)]
        case (.symbolicLink(let identity), _), (.other(let identity), _):
            return [RestoreConflict(destination: destination, kind: .unsafePath, observedIdentity: identity, replaceable: false)]
        case (_, .symbolicLink), (_, .other):
            return [RestoreConflict(destination: destination, kind: .unsafePath, replaceable: false)]
        case (.unsafePath, _):
            return [RestoreConflict(destination: destination, kind: .unsafePath, replaceable: false)]
        }
    }

    private static func phoneConflicts(_ state: RemoteDestinationState, destination: RestoreDestination,
                                       sourceKind: RemoteEntryKind) -> [RestoreConflict] {
        switch (state, sourceKind) {
        case (.missing, _), (.directory, .directory): return []
        case (.regularFile(let identity, _), .file):
            return [RestoreConflict(destination: destination, kind: .fileExists, observedIdentity: identity, replaceable: true)]
        case (.regularFile(let identity, _), .directory), (.directory(let identity), .file):
            return [RestoreConflict(destination: destination, kind: .directoryExists, observedIdentity: identity, replaceable: false)]
        case (.symbolicLink(let identity), _), (.other(let identity), _):
            return [RestoreConflict(destination: destination, kind: .unsafePath, observedIdentity: identity, replaceable: false)]
        case (_, .symbolicLink), (_, .other):
            return [RestoreConflict(destination: destination, kind: .unsafePath, replaceable: false)]
        }
    }

    private static func compare(_ state: LocalFilePublication.LocalDestinationState, destination: RestoreDestination,
                                sourceKind: RemoteEntryKind, conflict: RestoreConflict?, approved: Set<UUID>) throws {
        try compare(state: state, destination: destination, sourceKind: sourceKind,
                    conflict: conflict, approved: approved,
                    identityOf: { state in
                        switch state {
                        case .regularFile(let id, _), .directory(let id), .symbolicLink(let id), .other(let id): id
                        case .missing, .unsafePath: nil
                        }
                    }, isMissing: { if case .missing = $0 { true } else { false } },
                    conflictFor: { localConflicts($0, destination: destination, sourceKind: sourceKind) })
    }

    private static func compare(_ state: RemoteDestinationState, destination: RestoreDestination,
                                sourceKind: RemoteEntryKind, conflict: RestoreConflict?, approved: Set<UUID>) throws {
        try compare(state: state, destination: destination, sourceKind: sourceKind,
                    conflict: conflict, approved: approved,
                    identityOf: { state in
                        switch state {
                        case .regularFile(let id, _), .directory(let id), .symbolicLink(let id), .other(let id): id
                        case .missing: nil
                        }
                    }, isMissing: { if case .missing = $0 { true } else { false } },
                    conflictFor: { phoneConflicts($0, destination: destination, sourceKind: sourceKind) })
    }

    private static func compare<State>(state: State, destination: RestoreDestination, sourceKind: RemoteEntryKind,
                                       conflict: RestoreConflict?, approved: Set<UUID>,
                                       identityOf: (State) -> String?, isMissing: (State) -> Bool,
                                       conflictFor: (State) -> [RestoreConflict]) throws {
        let currentIdentity = identityOf(state)
        if isMissing(state) {
            if let conflict {
                guard conflict.kind == .fileExists,
                      conflict.observedIdentity == RestoreConflict.approvedMissingTargetIdentity,
                      approved.contains(conflict.id) else {
                    throw conflictError(destination, conflict.kind)
                }
            }
            return
        }
        guard let conflict else {
            if conflictFor(state).isEmpty { return }
            throw conflictError(destination, conflictFor(state)[0].kind)
        }
        guard approved.contains(conflict.id), conflict.observedIdentity == currentIdentity else {
            throw conflictError(destination, conflict.kind)
        }
    }

    private static func validateEntries(_ entries: [BackupEntry]) throws {
        guard Set(entries.map(\.path)).count == entries.count else { throw EngineError.corruptedRepository("Duplicate restore source path") }
        for entry in entries {
            guard entry.size >= 0, entry.modifiedAt?.timeIntervalSince1970.isFinite != false else {
                throw EngineError.corruptedRepository("Invalid size or modification date in restore point")
            }
            switch entry.kind {
            case .file:
                guard let hash = entry.contentHash, hash.utf8.count == 64 else {
                    throw EngineError.corruptedRepository("Invalid file entry in restore point")
                }
            case .directory:
                guard entry.contentHash == nil else { throw EngineError.corruptedRepository("Directory has file content") }
            case .symbolicLink, .other:
                throw EngineError.corruptedRepository("Restore point contains an unsupported entry type")
            }
        }
    }

    private static func requireOutsideRepository(_ destination: URL, repositories: [BackupRepositoryInfo]) throws {
        let path = destination.standardizedFileURL.path
        for repository in repositories {
            let repositoryPath = repository.location.standardizedFileURL.resolvingSymlinksInPath().path
            let managedRoot = repository.location.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            if isEqualOrDescendant(path, of: repositoryPath) || isEqualOrDescendant(path, of: managedRoot) {
                throw EngineError.repositoryIO("Restore destination cannot be inside a managed backup repository")
            }
        }
    }

    private static func isEqualOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func components(of url: URL, relativeTo root: URL) -> [String] {
        let relative = url.standardizedFileURL.pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count)
        return Array(relative)
    }

    private static func uniqueConflicts(_ conflicts: [RestoreConflict]) -> [RestoreConflict] {
        struct Identity: Hashable {
            let destination: RestoreDestination
            let kind: RestoreConflictKind
            let observedIdentity: String?
        }
        var seen = Set<Identity>()
        return conflicts.filter { conflict in
            let key = Identity(destination: conflict.destination, kind: conflict.kind, observedIdentity: conflict.observedIdentity)
            return seen.insert(key).inserted
        }
    }

    private static func destinationDescription(_ destination: RestoreDestination) -> String {
        switch destination { case .local(let url): url.path; case .phone(let path): path.description }
    }

    private static func engineConflictKind(_ kind: RestoreConflictKind) -> ConflictKind {
        switch kind {
        case .fileExists: .fileExists
        case .directoryExists: .directoryExists
        case .unsafePath: .unsafePath
        case .caseOrUnicodeAlias: .caseOrUnicodeAlias
        }
    }

    private static func conflictError(_ destination: RestoreDestination, _ kind: RestoreConflictKind) -> EngineError {
        .destinationConflict(TransferConflict(destination: destinationDescription(destination), kind: engineConflictKind(kind)))
    }

    private static func totalBytes(_ mappings: [RestoreMapping]) -> Int64 {
        mappings.filter { $0.source.kind == .file }.reduce(0) { $0 + $1.source.size }
    }

    private static func add(_ value: Int64, to total: Int64) throws -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw EngineError.corruptedRepository("Restore size overflow") }
        return sum
    }

    private func repositoryInfo(_ repository: RepositoryID) async throws -> BackupRepositoryInfo {
        guard let info = try await repositoryStore.repositories().first(where: { $0.id == repository }) else {
            throw EngineError.corruptedRepository("Repository is not open")
        }
        return info
    }

    private func emitProgress(_ operation: OperationID, items: Int, totalItems: Int, bytes: Int64,
                              totalBytes: Int64, phase: OperationPhase) {
        emit(OperationEvent(operationID: operation, phase: phase,
                            progress: OperationProgress(completedItems: items, totalItems: totalItems,
                                                        completedBytes: bytes, totalBytes: totalBytes)), for: operation)
    }

    private func emit(_ event: OperationEvent, for operation: OperationID) {
        guard var record = operations[operation], !record.finished else { return }
        record.latestEvent = event
        for subscriber in record.subscribers.values { subscriber.yield(event) }
        operations[operation] = record
    }

    private func finish(_ operation: OperationID, record: RequestRecord, items: [RestoreItemResult]) {
        results[operation] = RestoreBatchResult(operationID: operation, items: items)
        guard var operationRecord = operations[operation], !operationRecord.finished else { return }
        operationRecord.finished = true
        for subscriber in operationRecord.subscribers.values { subscriber.finish() }
        operationRecord.subscribers.removeAll()
        operations[operation] = operationRecord
        activeRepositories.remove(record.request.repository)
        tasks.removeValue(forKey: operation)
    }

    private func appendUnfinished(_ state: RestoreItemState, detail: String, mappings: [RestoreMapping],
                                  existing: inout [RestoreItemResult]) {
        let completedSources = Set(existing.map(\.source))
        for mapping in mappings where !completedSources.contains(mapping.source.path) {
            existing.append(RestoreItemResult(source: mapping.source.path, destination: mapping.destination,
                                              state: state, detail: detail))
        }
    }

    private func removeSubscriber(_ id: UUID, operation: OperationID) {
        operations[operation]?.subscribers.removeValue(forKey: id)
    }
}
