import CryptoKit
import Darwin
import Foundation

/// Copies selected shared files directly between Android and a chosen Mac folder.
/// It has no repository dependency and never creates restore points.
public actor DefaultCopyEngine: CopyEngine {
    private struct SourceSnapshot: Sendable {
        let kind: RemoteEntryKind
        let size: Int64
        let modifiedAt: Date?
        let identity: String
        let localRoot: URL?
        let localComponents: [String]
        let localRootIdentity: String?
    }

    private struct RequestRecord: Sendable {
        let request: CopyRequest
        let mappings: [CopyMapping]
        let snapshots: [String: SourceSnapshot]
        let conflicts: [RestoreConflict]
        let totalBytes: Int64
        let localRoot: URL?
        let localRootIdentity: String?
    }

    private struct OperationRecord {
        var latestEvent: OperationEvent
        var continuations: [UUID: AsyncStream<OperationEvent>.Continuation] = [:]
        var finished = false
    }

    private let remote: any RemoteDestinationAccess
    private let repositories: any BackupRepositoryStore
    private var plans: [CopyPlanID: RequestRecord] = [:]
    private var operations: [OperationID: OperationRecord] = [:]
    private var tasks: [OperationID: Task<Void, Never>] = [:]
    private var activeDevices: Set<DeviceID> = []
    private var results: [OperationID: CopyBatchResult] = [:]

    public init(remote: any RemoteDestinationAccess, repositories: any BackupRepositoryStore) {
        self.remote = remote
        self.repositories = repositories
    }

    public func planCopy(_ request: CopyRequest) async throws -> CopyPlan {
        let sourceRecords: [(RemoteEntry, CopySource, SourceSnapshot)]
        let destinationRoot: URL?
        let rootIdentity: String?
        let canonicalLocalRoots: [URL]?
        switch request {
        case .phoneToMac(let session, let roots, let destination):
            guard !roots.isEmpty else { throw EngineError.emptySelection }
            let root = destination.standardizedFileURL.resolvingSymlinksInPath()
            let identity = try LocalFilePublication.rootIdentity(root)
            var entries: [RemoteEntry] = []
            for selectedRoot in Self.prune(roots) {
                guard let name = selectedRoot.name else { throw EngineError.invalidRemotePath(selectedRoot.description) }
                try await scanRemote(selectedRoot, session: session, into: &entries, visited: [])
                // Keep the selected folder name beneath the chosen destination.
                _ = name
            }
            var scanned: [(RemoteEntry, CopySource, SourceSnapshot)] = []
            for entry in entries {
                let state = try await remote.inspectDestination(entry.path, on: session)
                guard let snapshot = Self.remoteSnapshot(entry, state: state) else {
                    throw EngineError.sourceChanged(entry.path)
                }
                scanned.append((entry, .phone(entry), snapshot))
            }
            sourceRecords = scanned
            destinationRoot = root
            rootIdentity = identity
            canonicalLocalRoots = nil
        case .macToPhone(_, let sources, _, _):
            guard !sources.isEmpty else { throw EngineError.emptySelection }
            let selected = Self.pruneLocal(try sources.map(Self.canonicalLocalSelection))
            var collected: [(URL, RemoteEntry, SourceSnapshot)] = []
            for source in selected {
                try Self.scanLocalSelection(source, into: &collected)
            }
            sourceRecords = collected.map { ($0.1, .local($0.0), $0.2) }
            destinationRoot = nil
            rootIdentity = nil
            canonicalLocalRoots = selected
        }

        guard !sourceRecords.isEmpty else { throw EngineError.emptySelection }
        let mappings = try Self.makeMappings(request: request, records: sourceRecords,
                                             localRoots: canonicalLocalRoots, destinationRoot: destinationRoot)
        guard mappings.count == sourceRecords.count else {
            throw EngineError.transport("Copy source tree changed while its plan was being built")
        }
        let snapshotByID = Dictionary(uniqueKeysWithValues: sourceRecords.map { record in
            let id: String
            switch record.1 { case .phone(let entry): id = entry.path.description; case .local(let url): id = url.standardizedFileURL.path }
            return (id, record.2)
        })
        let conflicts: [RestoreConflict]
        switch request {
        case .phoneToMac(_, _, _):
            guard let destinationRoot, let rootIdentity else { throw EngineError.repositoryIO("Missing Mac destination root") }
            let managedRepositories = try await repositories.repositories()
            var found: [RestoreConflict] = []
            for mapping in mappings {
                guard case .local(let url) = mapping.destination else { continue }
                try Self.requireOutsideRepositories(url, repositories: managedRepositories)
                let components = Self.components(of: url, relativeTo: destinationRoot)
                let state = try LocalFilePublication.inspect(root: destinationRoot, components: components,
                                                             expectedRootIdentity: rootIdentity)
                found.append(contentsOf: Self.localConflicts(state, mapping: mapping))
            }
            found.append(contentsOf: Self.localAliases(mappings, root: destinationRoot))
            conflicts = Self.uniqueConflicts(found)
        case .macToPhone(let session, _, _, let replaceMissingTargets):
            var found: [RestoreConflict] = []
            let fileDestinations = Set(mappings.compactMap { mapping -> RemotePath? in
                guard case .phone(let path) = mapping.destination, Self.sourceKind(mapping) == .file else { return nil }
                return path
            })
            guard replaceMissingTargets.isSubset(of: fileDestinations) else {
                throw EngineError.transport("Missing-target replacement names a path outside the selected copy files")
            }
            for mapping in mappings {
                guard case .phone(let path) = mapping.destination else { continue }
                try await validateRemoteAncestors(path.parent ?? .root, session: session)
                let state = try await remote.inspectDestination(path, on: session)
                found.append(contentsOf: Self.remoteConflicts(state, mapping: mapping))
                if case .missing = state, Self.sourceKind(mapping) == .file, replaceMissingTargets.contains(path) {
                    found.append(RestoreConflict(destination: mapping.destination, kind: .fileExists,
                                                 observedIdentity: RestoreConflict.approvedMissingTargetIdentity,
                                                 replaceable: true))
                }
            }
            conflicts = Self.uniqueConflicts(found)
        }

        let byteCount = try sourceRecords.reduce(Int64(0)) { total, record in
            guard record.0.kind == .file else { return total }
            let (value, overflow) = total.addingReportingOverflow(record.0.size ?? 0)
            guard !overflow else { throw EngineError.transport("Copy size overflow") }
            return value
        }
        let plan = CopyPlan(request: request, mappings: mappings, conflicts: conflicts, totalBytes: byteCount,
                            fileCount: sourceRecords.filter { $0.0.kind == .file }.count,
                            directoryCount: sourceRecords.filter { $0.0.kind == .directory }.count)
        plans[plan.id] = RequestRecord(request: request, mappings: mappings, snapshots: snapshotByID,
                                       conflicts: conflicts, totalBytes: byteCount, localRoot: destinationRoot,
                                       localRootIdentity: rootIdentity)
        return plan
    }

    public func startCopy(_ plan: CopyPlanID, replacing conflictIDs: Set<UUID> = []) async throws -> OperationID {
        guard let record = plans.removeValue(forKey: plan) else {
            throw EngineError.transport("Copy plan expired; create a new plan")
        }
        let session: DeviceSession
        switch record.request {
        case .phoneToMac(let value, _, _), .macToPhone(let value, _, _, _): session = value
        }
        guard activeDevices.insert(session.deviceID).inserted else { throw EngineError.deviceUnavailable(session.deviceID) }
        do {
            guard conflictIDs.isSubset(of: Set(record.conflicts.map(\.id))) else {
                throw EngineError.transport("Replacement approval does not belong to this copy plan")
            }
            for conflict in record.conflicts where !conflict.replaceable || !conflictIDs.contains(conflict.id) {
                throw EngineError.destinationConflict(TransferConflict(destination: Self.destinationText(conflict.destination),
                                                                         kind: Self.engineConflictKind(conflict.kind)))
            }
            try await recheckDestinations(record, session: session, replacing: conflictIDs)
            let operation = OperationID()
            operations[operation] = OperationRecord(latestEvent: OperationEvent(operationID: operation, phase: .transferring))
            tasks[operation] = Task { [weak self] in
                guard let self else { return }
                await self.run(operation, record: record, session: session, replacing: conflictIDs)
            }
            return operation
        } catch {
            activeDevices.remove(session.deviceID)
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
            record.continuations[id] = continuation
            operations[operation] = record
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id, operation: operation) } }
        }
        return stream
    }

    public func cancel(_ operation: OperationID) async { tasks[operation]?.cancel() }
    public func result(for operation: OperationID) async -> CopyBatchResult? { results[operation] }

    private func run(_ operation: OperationID, record: RequestRecord, session: DeviceSession, replacing approved: Set<UUID>) async {
        var resultsForItems: [CopyItemResult] = []
        var completedBytes: Int64 = 0
        let totalBytes = record.totalBytes
        let conflictsByDestination = Dictionary(uniqueKeysWithValues: record.conflicts.map { ($0.destination, $0) })
        defer { activeDevices.remove(session.deviceID); tasks.removeValue(forKey: operation) }
        do {
            for mapping in record.mappings {
                try Task.checkCancellation()
                guard let snapshot = record.snapshots[mapping.id] else { throw EngineError.transport("Copy plan lost a source snapshot") }
                if snapshot.kind == .directory {
                    try await verifyDirectorySource(mapping, snapshot: snapshot, session: session)
                }
                switch mapping.destination {
                case .local(let destination):
                    guard let root = record.localRoot, let rootIdentity = record.localRootIdentity else {
                        throw EngineError.repositoryIO("Copy destination root is unavailable")
                    }
                    let components = Self.components(of: destination, relativeTo: root)
                    if snapshot.kind == .directory {
                        try LocalFilePublication.ensureDirectory(root: root, components: components,
                                                                expectedRootIdentity: rootIdentity)
                    } else {
                        let staged = try await stageSource(mapping, snapshot: snapshot, session: session)
                        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }
                        let conflict = conflictsByDestination[mapping.destination]
                        let replaceIdentity = conflict.flatMap { approved.contains($0.id) ? $0.observedIdentity : nil }
                        try await LocalFilePublication.publish(source: staged.url, expected: staged.reference,
                                                               modifiedAt: snapshot.modifiedAt, root: root,
                                                               components: components, expectedRootIdentity: rootIdentity,
                                                               replacing: replaceIdentity)
                        completedBytes += snapshot.size
                    }
                case .phone(let destination):
                    if snapshot.kind == .directory {
                        try await ensureRemoteDirectories(destination, on: session)
                    } else {
                        try await ensureRemoteDirectories(destination.parent ?? .root, on: session)
                        let staged = try await stageSource(mapping, snapshot: snapshot, session: session)
                        defer { try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent()) }
                        let conflict = conflictsByDestination[mapping.destination]
                        let replaceIdentity = conflict.flatMap { approved.contains($0.id) ? $0.observedIdentity : nil }
                        try await remote.publishStagedFile(from: staged.url, to: destination, on: session,
                                                           expected: staged.reference, replacing: replaceIdentity)
                        completedBytes += snapshot.size
                    }
                }
                resultsForItems.append(CopyItemResult(source: Self.sourceText(mapping.source),
                                                      destination: Self.destinationText(mapping.destination),
                                                      state: .publishedAndVerified))
                emitProgress(operation, items: resultsForItems.count, totalItems: record.mappings.count,
                             bytes: completedBytes, totalBytes: totalBytes, phase: .transferring)
            }
            emitProgress(operation, items: resultsForItems.count, totalItems: record.mappings.count,
                         bytes: completedBytes, totalBytes: totalBytes, phase: .verifying)
            emitProgress(operation, items: resultsForItems.count, totalItems: record.mappings.count,
                         bytes: completedBytes, totalBytes: totalBytes, phase: .committing)
            emitProgress(operation, items: resultsForItems.count, totalItems: record.mappings.count,
                         bytes: completedBytes, totalBytes: totalBytes, phase: .completed)
            finish(operation, results: resultsForItems)
        } catch is CancellationError {
            appendUnfinished(.cancelled, mappings: record.mappings, existing: &resultsForItems)
            emit(OperationEvent(operationID: operation, phase: .cancelled,
                                progress: OperationProgress(completedItems: resultsForItems.filter { $0.state == .publishedAndVerified }.count,
                                                            totalItems: record.mappings.count, completedBytes: completedBytes,
                                                            totalBytes: totalBytes)), for: operation)
            finish(operation, results: resultsForItems)
        } catch let error as EngineError {
            fail(operation, record: record, error: error, completedBytes: completedBytes,
                 totalBytes: totalBytes, items: &resultsForItems)
        } catch {
            let failure = EngineError.transport(error.localizedDescription)
            fail(operation, record: record, error: failure, completedBytes: completedBytes,
                 totalBytes: totalBytes, items: &resultsForItems)
        }
    }

    private func fail(_ operation: OperationID, record: RequestRecord, error: EngineError,
                      completedBytes: Int64, totalBytes: Int64, items: inout [CopyItemResult]) {
        if let current = record.mappings.dropFirst(items.count).first {
            let state: CopyItemState
            if case .destinationPublishedUnverified = error { state = .publishedUnverified }
            else { state = .failed }
            items.append(CopyItemResult(source: Self.sourceText(current.source),
                                        destination: Self.destinationText(current.destination),
                                        state: state, detail: String(describing: error)))
        }
        appendUnfinished(.skipped, mappings: record.mappings, existing: &items)
        let partial = items.contains { $0.state == .publishedAndVerified || $0.state == .publishedUnverified }
        emit(OperationEvent(operationID: operation, phase: partial ? .incomplete : .failed,
                            progress: OperationProgress(completedItems: items.count,
                                                        totalItems: record.mappings.count, completedBytes: completedBytes,
                                                        totalBytes: totalBytes), failure: error), for: operation)
        finish(operation, results: items)
    }

    private func stageSource(_ mapping: CopyMapping, snapshot: SourceSnapshot, session: DeviceSession) async throws -> (url: URL, reference: ContentObjectReference) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneBackup-Copy-\(UUID().uuidString)", isDirectory: true)
        guard directory.path.withCString({ Darwin.mkdir($0, S_IRWXU) }) == 0 else {
            throw EngineError.repositoryIO("Could not create private copy staging folder")
        }
        let staged = directory.appendingPathComponent("payload")
        do {
            switch mapping.source {
            case .phone(let entry):
                try await validateRemoteSourceAncestors(entry.path, session: session)
                var transferred = false
                for attempt in 0..<3 {
                    try Task.checkCancellation()
                    guard case .regularFile = try await remote.inspectDestination(entry.path, on: session) else {
                        throw EngineError.sourceChanged(entry.path)
                    }
                    let before = try await remote.metadata(of: entry.path, on: session)
                    guard before.kind == .file, Self.identity(of: before) == snapshot.identity else {
                        throw EngineError.sourceChanged(entry.path)
                    }
                    try await remote.pull(from: entry.path, on: session, to: staged)
                    let after = try await remote.metadata(of: entry.path, on: session)
                    if after == before {
                        transferred = true
                        break
                    }
                    try? FileManager.default.removeItem(at: staged)
                    if attempt == 2 { throw EngineError.sourceChanged(entry.path) }
                }
                guard transferred else { throw EngineError.sourceChanged(entry.path) }
            case .local:
                try await Self.copyLocalSource(snapshot, to: staged)
            }
            let reference = try await Self.hashFile(staged, expectedSize: snapshot.size)
            return (staged, reference)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func scanRemote(_ path: RemotePath, session: DeviceSession, into entries: inout [RemoteEntry], visited: Set<RemotePath>) async throws {
        var visited = visited
        guard visited.insert(path).inserted else { throw EngineError.transport("Remote directory cycle detected") }
        try await validateRemoteSourceAncestors(path, session: session)
        var state = try await remote.inspectDestination(path, on: session)
        let sdcardAlias = try RemotePath("/sdcard")
        if path == sdcardAlias, case .symbolicLink = state {
            state = .directory(identity: "android-shared-storage-alias")
        }
        switch state {
        case .symbolicLink, .other:
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
        default: break
        }
        let entry = try await remote.metadata(of: path, on: session)
        switch (state, entry.kind) {
        case (.regularFile, .file): entries.append(entry)
        case (.directory, .directory):
            entries.append(entry)
            let children = try await remote.children(of: path, on: session)
            for child in children.sorted(by: { RemotePath.bytewiseLess($0.path, $1.path) }) {
                try await scanRemote(child.path, session: session, into: &entries, visited: visited)
            }
        case (.symbolicLink, _), (_, .symbolicLink), (.other, _), (_, .other):
            throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
        default: throw EngineError.sourceChanged(path)
        }
    }

    private func recheckDestinations(_ record: RequestRecord, session: DeviceSession, replacing approved: Set<UUID>) async throws {
        for mapping in record.mappings {
            let conflict = record.conflicts.first(where: { $0.destination == mapping.destination })
            switch mapping.destination {
            case .local(let destination):
                guard let root = record.localRoot, let identity = record.localRootIdentity,
                      try LocalFilePublication.rootIdentity(root) == identity else {
                    throw EngineError.destinationConflict(TransferConflict(destination: "chosen copy folder", kind: .unsafePath))
                }
                let state = try LocalFilePublication.inspect(root: root, components: Self.components(of: destination, relativeTo: root),
                                                             expectedRootIdentity: identity)
                try Self.checkLocal(state, mapping: mapping, conflict: conflict,
                                    replacing: conflict.map { approved.contains($0.id) } ?? false)
            case .phone(let destination):
                try await validateRemoteAncestors(destination.parent ?? .root, session: session)
                let state = try await remote.inspectDestination(destination, on: session)
                try Self.checkRemote(state, mapping: mapping, conflict: conflict,
                                     replacing: conflict.map { approved.contains($0.id) } ?? false)
            }
        }
    }

    private func verifyDirectorySource(_ mapping: CopyMapping, snapshot: SourceSnapshot, session: DeviceSession) async throws {
        switch mapping.source {
        case .local:
            let descriptor = try Self.openLocalSource(snapshot)
            defer { _ = Darwin.close(descriptor) }
            var current = stat()
            guard Darwin.fstat(descriptor, &current) == 0, Self.identity(current) == snapshot.identity,
                  current.st_mode & S_IFMT == S_IFDIR else {
                throw EngineError.repositoryIO("Local copy source directory changed after planning")
            }
        case .phone(let entry):
            try await validateRemoteSourceAncestors(entry.path, session: session)
            guard case .directory = try await remote.inspectDestination(entry.path, on: session) else {
                throw EngineError.sourceChanged(entry.path)
            }
            let current = try await remote.metadata(of: entry.path, on: session)
            guard current.kind == .directory, Self.identity(of: current) == snapshot.identity else {
                throw EngineError.sourceChanged(entry.path)
            }
        }
    }

    private func validateRemoteAncestors(_ parent: RemotePath, session: DeviceSession) async throws {
        var path = RemotePath.root
        for (index, component) in parent.components.enumerated() {
            path = try path.appending(component)
            if index == 0 && component == "sdcard" { continue }
            switch try await remote.inspectDestination(path, on: session) {
            case .missing: return
            case .directory: continue
            case .regularFile, .symbolicLink, .other:
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
            }
        }
    }

    private func validateRemoteSourceAncestors(_ source: RemotePath, session: DeviceSession) async throws {
        var path = RemotePath.root
        for (index, component) in source.components.dropLast().enumerated() {
            path = try path.appending(component)
            if index == 0 && component == "sdcard" { continue }
            switch try await remote.inspectDestination(path, on: session) {
            case .directory: continue
            case .missing: throw EngineError.missingPath(path)
            case .regularFile, .symbolicLink, .other:
                throw EngineError.destinationConflict(TransferConflict(destination: path.description, kind: .unsafePath))
            }
        }
    }

    private func ensureRemoteDirectories(_ path: RemotePath, on session: DeviceSession) async throws {
        var current = RemotePath.root
        for (index, component) in path.components.enumerated() {
            current = try current.appending(component)
            if index == 0 && component == "sdcard" { continue }
            switch try await remote.inspectDestination(current, on: session) {
            case .directory: continue
            case .missing: try await remote.createDestinationDirectory(current, on: session)
            case .regularFile, .symbolicLink, .other:
                throw EngineError.destinationConflict(TransferConflict(destination: current.description, kind: .unsafePath))
            }
        }
    }

    private func removeSubscriber(_ id: UUID, operation: OperationID) {
        guard var record = operations[operation] else { return }
        record.continuations.removeValue(forKey: id)
        operations[operation] = record
    }

    private func emitProgress(_ operation: OperationID, items: Int, totalItems: Int, bytes: Int64,
                              totalBytes: Int64, phase: OperationPhase) {
        emit(OperationEvent(operationID: operation, phase: phase,
                            progress: OperationProgress(completedItems: items, totalItems: totalItems,
                                                        completedBytes: bytes, totalBytes: totalBytes)), for: operation)
    }

    private func emit(_ event: OperationEvent, for operation: OperationID) {
        guard var record = operations[operation] else { return }
        record.latestEvent = event
        for continuation in record.continuations.values { continuation.yield(event) }
        operations[operation] = record
    }

    private func finish(_ operation: OperationID, results: [CopyItemResult]) {
        self.results[operation] = CopyBatchResult(operationID: operation, items: results)
        guard var record = operations[operation] else { return }
        record.finished = true
        for continuation in record.continuations.values { continuation.finish() }
        record.continuations.removeAll()
        operations[operation] = record
    }

    private func appendUnfinished(_ state: CopyItemState, mappings: [CopyMapping], existing: inout [CopyItemResult]) {
        for mapping in mappings.dropFirst(existing.count) {
            existing.append(CopyItemResult(source: Self.sourceText(mapping.source),
                                           destination: Self.destinationText(mapping.destination), state: state))
        }
    }

    private static func makeMappings(request: CopyRequest, records: [(RemoteEntry, CopySource, SourceSnapshot)],
                                     localRoots: [URL]?, destinationRoot: URL?) throws -> [CopyMapping] {
        var result: [CopyMapping] = []
        switch request {
        case .phoneToMac(_, let roots, _):
            guard let root = destinationRoot else { throw EngineError.repositoryIO("Mac destination root was not captured") }
            for selected in prune(roots) {
                guard let name = selected.name else { throw EngineError.invalidRemotePath(selected.description) }
                for (entry, source, _) in records where entry.path.isEqualOrDescendant(of: selected) {
                    let relative = Array(entry.path.components.dropFirst(selected.components.count))
                    var url = root.appendingPathComponent(name, isDirectory: entry.kind == .directory)
                    for component in relative { url.appendPathComponent(component, isDirectory: entry.kind == .directory) }
                    result.append(CopyMapping(source: source, destination: .local(url), kind: entry.kind))
                }
            }
            guard result.allSatisfy({ mapping in
                if case .local(let url) = mapping.destination { return Self.url(url, isEqualOrDescendantOf: root) }
                return false
            }) else { throw EngineError.repositoryIO("Copy mapping escaped the reviewed Mac destination folder") }
        case .macToPhone(_, _, let destination, _):
            guard let roots = localRoots else { throw EngineError.transport("Mac source roots were not captured") }
            for selected in roots {
                let name = selected.lastPathComponent
                guard !name.isEmpty && name != "/" else { throw EngineError.transport("Cannot copy a filesystem root") }
                for (entry, source, _) in records {
                    let sourceURL: URL
                    if case .local(let value) = source { sourceURL = value } else { continue }
                    guard Self.url(sourceURL, isEqualOrDescendantOf: selected) else { continue }
                    let relative = Self.relativeComponents(sourceURL, under: selected)
                    var remotePath = try destination.appending(name)
                    for component in relative { remotePath = try remotePath.appending(component) }
                    result.append(CopyMapping(source: source, destination: .phone(remotePath), kind: entry.kind))
                }
            }
        }
        result.sort { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
        let destinations = result.map { destinationText($0.destination) }
        guard Set(destinations).count == destinations.count else {
            throw EngineError.destinationConflict(TransferConflict(destination: "duplicate copy target", kind: .caseOrUnicodeAlias))
        }
        return result
    }

    private static func scanLocalSelection(_ selection: URL,
                                           into records: inout [(URL, RemoteEntry, SourceSnapshot)]) throws {
        guard selection.path != "/", !selection.lastPathComponent.isEmpty else {
            throw EngineError.transport("Cannot copy a filesystem root")
        }
        let parentURL = try canonicalDirectory(selection.deletingLastPathComponent())
        let parent = parentURL.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard parent >= 0 else { throw EngineError.repositoryIO("Could not open selected source parent") }
        defer { _ = Darwin.close(parent) }
        let name = selection.lastPathComponent
        var info = stat()
        guard name.withCString({ Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw EngineError.repositoryIO("Could not inspect selected local source")
        }
        let kind = try localKind(info, path: selection.path)
        var parentInfo = stat()
        guard Darwin.fstat(parent, &parentInfo) == 0 else { throw EngineError.repositoryIO("Could not identify source parent") }
        let parentIdentity = identity(parentInfo)
        let canonicalSelection = parentURL.appendingPathComponent(name, isDirectory: kind == .directory)
        let path = try RemotePath(components: ["local", name])
        if kind == .file {
            let snapshot = SourceSnapshot(kind: .file, size: Int64(info.st_size), modifiedAt: modifiedAt(info),
                                          identity: identity(info), localRoot: parentURL, localComponents: [name],
                                          localRootIdentity: parentIdentity)
            records.append((canonicalSelection, RemoteEntry(path: path, kind: .file, size: snapshot.size,
                                                            modifiedAt: snapshot.modifiedAt), snapshot))
            return
        }
        let directory = name.withCString { Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard directory >= 0 else { throw EngineError.destinationConflict(TransferConflict(destination: selection.path, kind: .unsafePath)) }
        defer { _ = Darwin.close(directory) }
        var openedInfo = stat()
        guard Darwin.fstat(directory, &openedInfo) == 0, identity(openedInfo) == identity(info) else {
            throw EngineError.sourceChanged(try remotePathForError(selection))
        }
        let rootIdentity = identity(openedInfo)
        let snapshot = SourceSnapshot(kind: .directory, size: 0, modifiedAt: modifiedAt(openedInfo),
                                      identity: rootIdentity, localRoot: canonicalSelection,
                                      localComponents: [], localRootIdentity: rootIdentity)
        records.append((canonicalSelection, RemoteEntry(path: path, kind: .directory, size: 0,
                                                        modifiedAt: snapshot.modifiedAt), snapshot))
        try scanLocalDirectory(directory, rootURL: canonicalSelection, relative: [], rootIdentity: rootIdentity,
                               records: &records)
    }

    private static func scanLocalDirectory(_ directory: Int32, rootURL: URL, relative: [String], rootIdentity: String,
                                           records: inout [(URL, RemoteEntry, SourceSnapshot)]) throws {
        let listingFD = Darwin.dup(directory)
        guard listingFD >= 0, let listing = fdopendir(listingFD) else {
            if listingFD >= 0 { _ = Darwin.close(listingFD) }
            throw EngineError.repositoryIO("Could not enumerate selected local directory")
        }
        defer { _ = closedir(listing) }
        var names: [String] = []
        while true {
            errno = 0
            guard let item = readdir(listing) else {
                guard errno == 0 else { throw EngineError.repositoryIO("Could not finish enumerating local copy source") }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: item.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { throw EngineError.transport("Local filename is not valid UTF-8") }
            if name != "." && name != ".." { names.append(name) }
        }
        names.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        for name in names {
            try Task.checkCancellation()
            var info = stat()
            guard name.withCString({ Darwin.fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw EngineError.repositoryIO("Local source changed while it was being scanned")
            }
            let childRelative = relative + [name]
            let childURL = childRelative.reduce(rootURL) { $0.appendingPathComponent($1) }
            let path = try RemotePath(components: ["local"] + childRelative)
            let kind = try localKind(info, path: childURL.path)
            if kind == .directory {
                let child = name.withCString { Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
                guard child >= 0 else { throw EngineError.destinationConflict(TransferConflict(destination: childURL.path, kind: .unsafePath)) }
                do {
                    defer { _ = Darwin.close(child) }
                    var opened = stat()
                    guard Darwin.fstat(child, &opened) == 0, identity(opened) == identity(info) else {
                        throw EngineError.sourceChanged(try remotePathForError(childURL))
                    }
                    let snapshot = SourceSnapshot(kind: .directory, size: 0, modifiedAt: modifiedAt(opened),
                                                  identity: identity(opened), localRoot: rootURL,
                                                  localComponents: childRelative, localRootIdentity: rootIdentity)
                    records.append((childURL, RemoteEntry(path: path, kind: .directory, size: 0,
                                                          modifiedAt: snapshot.modifiedAt), snapshot))
                    try scanLocalDirectory(child, rootURL: rootURL, relative: childRelative,
                                           rootIdentity: rootIdentity, records: &records)
                }
            } else {
                let snapshot = SourceSnapshot(kind: .file, size: Int64(info.st_size), modifiedAt: modifiedAt(info),
                                              identity: identity(info), localRoot: rootURL,
                                              localComponents: childRelative, localRootIdentity: rootIdentity)
                records.append((childURL, RemoteEntry(path: path, kind: .file, size: snapshot.size,
                                                      modifiedAt: snapshot.modifiedAt), snapshot))
            }
        }
    }

    private static func copyLocalSource(_ snapshot: SourceSnapshot, to destination: URL) async throws {
        let input = try openLocalSource(snapshot)
        defer { _ = Darwin.close(input) }
        var before = stat()
        guard Darwin.fstat(input, &before) == 0 else { throw EngineError.repositoryIO("Could not inspect opened source") }
        guard identity(before) == snapshot.identity else { throw EngineError.transport("Local copy source changed after planning") }
        let output = destination.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
        guard output >= 0 else { throw EngineError.repositoryIO("Could not create private copy staging file") }
        defer { _ = Darwin.close(output) }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            await Task.yield()
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                Darwin.read(input, pointer.baseAddress!, pointer.count)
            }
            guard count >= 0 else { throw EngineError.repositoryIO("Could not read local copy source") }
            if count == 0 { break }
            var written = 0
            while written < count {
                let n = buffer.withUnsafeBufferPointer { pointer in
                    Darwin.write(output, pointer.baseAddress!.advanced(by: written), count - written)
                }
                guard n > 0 else { throw EngineError.repositoryIO("Could not stage local copy source") }
                written += n
            }
        }
        var after = stat()
        guard Darwin.fstat(input, &after) == 0, identity(after) == snapshot.identity else {
            throw EngineError.transport("Local copy source changed during staging")
        }
        guard Darwin.fsync(output) == 0 else { throw EngineError.repositoryIO("Could not synchronize copy staging file") }
    }

    private static func hashFile(_ url: URL, expectedSize: Int64) async throws -> ContentObjectReference {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            await Task.yield()
            size += Int64(data.count)
            hasher.update(data: data)
        }
        guard size == expectedSize else { throw EngineError.sourceChanged(try remotePathForError(url)) }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ContentObjectReference(sha256: hash, size: size)
    }

    private static func canonicalDirectory(_ url: URL) throws -> URL {
        let path = url.standardizedFileURL.path
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else {
            throw EngineError.repositoryIO("Could not resolve local source directory")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func canonicalLocalSelection(_ url: URL) throws -> URL {
        let parent = try canonicalDirectory(url.deletingLastPathComponent())
        return parent.appendingPathComponent(url.lastPathComponent)
    }

    private static func openLocalSource(_ snapshot: SourceSnapshot) throws -> Int32 {
        guard let root = snapshot.localRoot, let expectedRoot = snapshot.localRootIdentity else {
            throw EngineError.repositoryIO("Local copy source has no pinned root")
        }
        var current = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard current >= 0 else { throw EngineError.repositoryIO("Pinned local copy source root is unavailable") }
        var rootInfo = stat()
        guard Darwin.fstat(current, &rootInfo) == 0, identity(rootInfo) == expectedRoot else {
            _ = Darwin.close(current)
            throw EngineError.repositoryIO("Local copy source root changed after planning")
        }
        for (index, component) in snapshot.localComponents.enumerated() {
            let final = index == snapshot.localComponents.count - 1
            var flags = O_RDONLY | O_NOFOLLOW
            if !final || snapshot.kind == .directory { flags |= O_DIRECTORY }
            let next = component.withCString { Darwin.openat(current, $0, flags) }
            guard next >= 0 else {
                _ = Darwin.close(current)
                throw EngineError.repositoryIO("Local copy source path changed after planning")
            }
            _ = Darwin.close(current)
            current = next
        }
        return current
    }

    private static func localKind(_ info: stat, path: String) throws -> RemoteEntryKind {
        switch info.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: throw EngineError.destinationConflict(TransferConflict(destination: path, kind: .unsafePath))
        default: throw EngineError.destinationConflict(TransferConflict(destination: path, kind: .unsafePath))
        }
    }

    private static func modifiedAt(_ info: stat) -> Date {
        Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func remoteSnapshot(_ entry: RemoteEntry, state: RemoteDestinationState) -> SourceSnapshot? {
        switch (state, entry.kind) {
        case (.regularFile(_, let size), .file):
            return SourceSnapshot(kind: .file, size: size, modifiedAt: entry.modifiedAt,
                                  identity: identity(of: entry), localRoot: nil, localComponents: [], localRootIdentity: nil)
        case (.directory, .directory):
            return SourceSnapshot(kind: .directory, size: 0, modifiedAt: entry.modifiedAt,
                                  identity: identity(of: entry), localRoot: nil, localComponents: [], localRootIdentity: nil)
        default: return nil
        }
    }

    private static func identity(of entry: RemoteEntry) -> String {
        "\(entry.kind.rawValue):\(entry.size ?? -1):\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private static func identity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mode & S_IFMT):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }

    private static func checkLocal(_ state: LocalFilePublication.LocalDestinationState, mapping: CopyMapping,
                                   conflict: RestoreConflict?, replacing: Bool) throws {
        switch state {
        case .missing: guard conflict == nil else { throw destinationConflict(mapping, .fileExists) }
        case .regularFile(let identity, _):
            guard conflict?.kind == .fileExists, conflict?.observedIdentity == identity, replacing else {
                throw destinationConflict(mapping, .fileExists)
            }
        case .directory: if sourceKind(mapping) != .directory { throw destinationConflict(mapping, .directoryExists) }
        case .symbolicLink, .other, .unsafePath: throw destinationConflict(mapping, .unsafePath)
        }
    }

    private static func checkRemote(_ state: RemoteDestinationState, mapping: CopyMapping,
                                    conflict: RestoreConflict?, replacing: Bool) throws {
        switch state {
        case .missing:
            guard conflict == nil || (conflict?.observedIdentity == RestoreConflict.approvedMissingTargetIdentity && replacing) else {
                throw destinationConflict(mapping, .fileExists)
            }
        case .regularFile(let identity, _):
            guard conflict?.kind == .fileExists, conflict?.observedIdentity == identity, replacing else {
                throw destinationConflict(mapping, .fileExists)
            }
        case .directory: if sourceKind(mapping) != .directory { throw destinationConflict(mapping, .directoryExists) }
        case .symbolicLink, .other: throw destinationConflict(mapping, .unsafePath)
        }
    }

    private static func localConflicts(_ state: LocalFilePublication.LocalDestinationState, mapping: CopyMapping) -> [RestoreConflict] {
        switch state {
        case .missing: []
        case .regularFile(let identity, _):
            sourceKind(mapping) == .file ? [RestoreConflict(destination: mapping.destination, kind: .fileExists,
                                                            observedIdentity: identity, replaceable: true)] :
                [RestoreConflict(destination: mapping.destination, kind: .directoryExists, observedIdentity: identity, replaceable: false)]
        case .directory(let identity):
            sourceKind(mapping) == .directory ? [] : [RestoreConflict(destination: mapping.destination, kind: .directoryExists,
                                                                       observedIdentity: identity, replaceable: false)]
        case .symbolicLink, .other, .unsafePath:
            [RestoreConflict(destination: mapping.destination, kind: .unsafePath, replaceable: false)]
        }
    }

    private static func remoteConflicts(_ state: RemoteDestinationState, mapping: CopyMapping) -> [RestoreConflict] {
        switch state {
        case .missing: []
        case .regularFile(let identity, _):
            sourceKind(mapping) == .file ? [RestoreConflict(destination: mapping.destination, kind: .fileExists,
                                                            observedIdentity: identity, replaceable: true)] :
                [RestoreConflict(destination: mapping.destination, kind: .directoryExists, observedIdentity: identity, replaceable: false)]
        case .directory(let identity):
            sourceKind(mapping) == .directory ? [] : [RestoreConflict(destination: mapping.destination, kind: .directoryExists,
                                                                       observedIdentity: identity, replaceable: false)]
        case .symbolicLink, .other:
            [RestoreConflict(destination: mapping.destination, kind: .unsafePath, replaceable: false)]
        }
    }

    private static func sourceKind(_ mapping: CopyMapping) -> RemoteEntryKind {
        mapping.kind
    }


    private static func destinationConflict(_ mapping: CopyMapping, _ kind: ConflictKind) -> EngineError {
        EngineError.destinationConflict(TransferConflict(destination: destinationText(mapping.destination), kind: kind))
    }

    private static func requireOutsideRepositories(_ destination: URL, repositories: [BackupRepositoryInfo]) throws {
        let path = destination.standardizedFileURL.resolvingSymlinksInPath().path
        for repository in repositories {
            let managedRoot = repository.location.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = managedRoot.hasSuffix("/") ? managedRoot : managedRoot + "/"
            if path == managedRoot || path.hasPrefix(prefix) {
                throw EngineError.repositoryIO("Copy destination is inside a managed backup repository")
            }
        }
    }

    private static func localAliases(_ mappings: [CopyMapping], root: URL) -> [RestoreConflict] {
        var known: [String: (Data, CopyMapping)] = [:]
        var conflicts: [RestoreConflict] = []
        for mapping in mappings {
            guard case .local(let url) = mapping.destination else { continue }
            var bytes = Data()
            let components = components(of: url, relativeTo: root)
            for component in components {
                bytes.append(contentsOf: component.utf8); bytes.append(0)
                let key = String(decoding: bytes, as: UTF8.self).precomposedStringWithCanonicalMapping.lowercased()
                if let previous = known[key], previous.0 != bytes {
                    conflicts.append(RestoreConflict(destination: mapping.destination, kind: .caseOrUnicodeAlias, replaceable: false))
                    conflicts.append(RestoreConflict(destination: previous.1.destination, kind: .caseOrUnicodeAlias, replaceable: false))
                } else { known[key] = (bytes, mapping) }
            }
        }
        return conflicts
    }

    private static func uniqueConflicts(_ conflicts: [RestoreConflict]) -> [RestoreConflict] {
        var unique: [RestoreDestination: RestoreConflict] = [:]
        for conflict in conflicts { unique[conflict.destination] = conflict }
        return unique.values.sorted { destinationText($0.destination) < destinationText($1.destination) }
    }

    private static func prune(_ roots: [RemotePath]) -> [RemotePath] {
        let sorted = Array(Set(roots)).sorted(by: RemotePath.bytewiseLess)
        return sorted.filter { path in !sorted.contains(where: { $0 != path && path.isEqualOrDescendant(of: $0) }) }
    }

    private static func pruneLocal(_ urls: [URL]) -> [URL] {
        let sorted = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        return sorted.filter { url in !sorted.contains(where: { $0 != url && Self.url(url, isEqualOrDescendantOf: $0) }) }
    }

    private static func url(_ url: URL, isEqualOrDescendantOf ancestor: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = ancestor.standardizedFileURL.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func relativeComponents(_ url: URL, under root: URL) -> [String] {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return [] }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    private static func components(of url: URL, relativeTo root: URL) -> [String] {
        relativeComponents(url, under: root)
    }

    private static func sourceText(_ source: CopySource) -> String {
        switch source { case .phone(let entry): entry.path.description; case .local(let url): url.path }
    }

    private static func destinationText(_ destination: RestoreDestination) -> String {
        switch destination { case .local(let url): url.path; case .phone(let path): path.description }
    }

    private static func engineConflictKind(_ kind: RestoreConflictKind) -> ConflictKind {
        switch kind {
        case .fileExists: .fileExists
        case .directoryExists: .directoryExists
        case .unsafePath, .caseOrUnicodeAlias: .unsafePath
        }
    }

    private static func remotePathForError(_ url: URL) throws -> RemotePath {
        // EngineError.sourceChanged carries a RemotePath for Android sources; local paths are rendered safely here.
        try RemotePath("/local-copy-source-" + String(SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)))
    }

}
