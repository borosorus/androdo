import Darwin
import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let data: Data
    public let standardError: Data
    public let exitCode: Int32

    public init(data: Data, standardError: Data = Data(), exitCode: Int32) {
        self.data = data
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

/// Gates file input until the remote command confirms its identity on the same ADB shell stream.
public struct CommandInputGate: Equatable, Sendable {
    public let readyFrame: Data
    public let approvalFrame: Data

    public init(readyFrame: Data, approvalFrame: Data) {
        self.readyFrame = readyFrame
        self.approvalFrame = approvalFrame
    }
}

/// Optional file-backed standard streams for large binary transfers.
public struct CommandFileIO: Equatable, Sendable {
    public let inputFile: URL?
    public let inputData: Data?
    public let outputFile: URL?
    public let inputGate: CommandInputGate?

    public init(inputFile: URL? = nil, inputData: Data? = nil,
                outputFile: URL? = nil, inputGate: CommandInputGate? = nil) {
        self.inputFile = inputFile
        self.inputData = inputData
        self.outputFile = outputFile
        self.inputGate = inputGate
    }

    public static let none = CommandFileIO()
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput
    func run(executable: URL, arguments: [String], timeout: TimeInterval,
             fileIO: CommandFileIO) async throws -> CommandOutput
}

public extension CommandRunning {
    func run(executable: URL, arguments: [String], timeout: TimeInterval,
             fileIO: CommandFileIO) async throws -> CommandOutput {
        guard fileIO == .none else {
            throw EngineError.transport("This ADB command runner does not support file-backed transfers")
        }
        return try await run(executable: executable, arguments: arguments, timeout: timeout)
    }
}

/// Runs local ADB processes off the caller's actor. File transfers stream through private file
/// descriptors; upload bytes are withheld until the remote identity guard sends its readiness frame.
public struct ProcessCommandRunner: CommandRunning {
    private let environment: [String: String]

    public init() {
        environment = ProcessInfo.processInfo.environment
    }

    init(environment: [String: String]) {
        self.environment = environment
    }

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        try await run(executable: executable, arguments: arguments, timeout: timeout, fileIO: .none)
    }

    public func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    fileIO: CommandFileIO) async throws -> CommandOutput {
        let execution = ProcessExecution()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try execution.run(executable: executable, arguments: arguments, timeout: timeout,
                                  fileIO: fileIO, environment: environment)
            }.value
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if runningProcess?.isRunning == true { runningProcess?.terminate() }
    }

    func run(executable: URL, arguments: [String], timeout: TimeInterval,
             fileIO: CommandFileIO, environment: [String: String]) throws -> CommandOutput {
        let hasInputFile = fileIO.inputFile != nil
        let hasInputData = fileIO.inputData != nil
        guard timeout > 0,
              !(hasInputFile && hasInputData),
              fileIO.inputData.map({ $0.count <= 4096 }) ?? true,
              fileIO.inputGate == nil || hasInputFile && !hasInputData && fileIO.outputFile == nil else {
            throw EngineError.transport("Invalid ADB file transfer configuration")
        }

        let inputDescriptor = try Self.openInput(fileIO.inputFile)
        defer { if inputDescriptor >= 0 { _ = Darwin.close(inputDescriptor) } }
        let ownedOutput = try Self.openOutput(fileIO.outputFile)
        let outputDescriptor = ownedOutput?.descriptor ?? -1
        var outputSucceeded = false
        defer {
            if let ownedOutput {
                _ = Darwin.close(ownedOutput.descriptor)
                if !outputSucceeded { Self.removeOwnedOutput(ownedOutput) }
            }
        }

        let inputPipe = inputDescriptor >= 0 || hasInputData ? Pipe() : nil
        let outputPipe = outputDescriptor < 0 ? Pipe() : nil
        let errorPipe = Pipe()
        let subprocess = Process()
        subprocess.executableURL = executable
        subprocess.arguments = arguments
        var subprocessEnvironment = environment
        // ADB_TRACE and Android logging can expose the host:pair service request, which includes
        // the pairing secret. Server overrides could route it to a remote ADB server.
        for key in ["ADB_TRACE", "ANDROID_LOG_TAGS", "ADB_SERVER_SOCKET",
                    "ANDROID_ADB_SERVER_ADDRESS", "ANDROID_ADB_SERVER_PORT"] {
            subprocessEnvironment.removeValue(forKey: key)
        }
        subprocess.environment = subprocessEnvironment
        subprocess.standardInput = inputPipe ?? FileHandle.nullDevice
        subprocess.standardOutput = outputDescriptor >= 0
            ? FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
            : outputPipe!
        subprocess.standardError = errorPipe

        lock.lock()
        let alreadyCancelled = cancelled
        process = subprocess
        lock.unlock()
        if alreadyCancelled { clearProcess(); throw CancellationError() }

        let outputReader = outputPipe.map {
            ProcessOutputReader(handle: $0.fileHandleForReading,
                                maximumBytes: fileIO.inputGate == nil && !hasInputData ? nil : 4096)
        }
        let errorReader = ProcessOutputReader(handle: errorPipe.fileHandleForReading,
                                              maximumBytes: fileIO.inputFile == nil && !hasInputData && fileIO.outputFile == nil
                                                ? nil : 64 * 1024)
        do {
            try subprocess.run()
        } catch {
            _ = outputReader?.finish()
            _ = errorReader.finish()
            closePipeEnds(inputPipe: inputPipe, outputPipe: outputPipe, errorPipe: errorPipe)
            clearProcess()
            throw EngineError.adbUnavailable(error.localizedDescription)
        }

        try? inputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)

        do {
            if let inputData = fileIO.inputData {
                let writer = inputPipe!.fileHandleForWriting
                if !inputData.isEmpty {
                    try Self.write(inputData, to: writer.fileDescriptor, process: subprocess,
                                   deadline: deadline, isCancelled: { self.isCancelled })
                }
                try? writer.close()
            } else if inputDescriptor >= 0 {
                let writer = inputPipe!.fileHandleForWriting
                if let gate = fileIO.inputGate {
                    guard let outputReader,
                          try outputReader.waitForPrefix(gate.readyFrame, process: subprocess,
                                                         deadline: deadline, isCancelled: { self.isCancelled }) else {
                        try waitForExit(subprocess, deadline: deadline)
                        try? writer.close()
                        let result = CommandOutput(data: outputReader?.finish() ?? Data(),
                                                   standardError: errorReader.finish(),
                                                   exitCode: subprocess.terminationStatus)
                        outputSucceeded = result.exitCode == 0
                        clearProcess()
                        return result
                    }
                    try Self.write(gate.approvalFrame, to: writer.fileDescriptor,
                                   process: subprocess, deadline: deadline, isCancelled: { self.isCancelled })
                }
                try streamInput(inputDescriptor, to: writer.fileDescriptor,
                                process: subprocess, deadline: deadline)
                try? writer.close()
            }
            try waitForExit(subprocess, deadline: deadline)
        } catch {
            terminateAndReap(subprocess)
            try? inputPipe?.fileHandleForWriting.close()
            _ = outputReader?.finish()
            _ = errorReader.finish()
            clearProcess()
            if isCancelled { throw CancellationError() }
            if Date() >= deadline { throw EngineError.operationTimedOut }
            throw error
        }

        let standardOutput = outputReader?.finish() ?? Data()
        let standardError = errorReader.finish()
        let exitCode = subprocess.terminationStatus
        outputSucceeded = exitCode == 0
        clearProcess()
        return CommandOutput(data: standardOutput, standardError: standardError, exitCode: exitCode)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func streamInput(_ input: Int32, to output: Int32, process: Process, deadline: Date) throws {
        let originalFlags = Darwin.fcntl(output, F_GETFL)
        guard originalFlags >= 0,
              Darwin.fcntl(output, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw EngineError.transport("Could not prepare the ADB transfer stream")
        }
        defer { _ = Darwin.fcntl(output, F_SETFL, originalFlags) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try checkTransferState(process, deadline: deadline)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                throw EngineError.transport("Could not read the local ADB transfer source")
            }
            try buffer.withUnsafeBytes { bytes in
                try Self.write(bytes.baseAddress!, count: count, to: output,
                               process: process, deadline: deadline, isCancelled: { self.isCancelled })
            }
        }
    }

    private func waitForExit(_ process: Process, deadline: Date) throws {
        var terminationSentAt: Date?
        while process.isRunning {
            if isCancelled { throw CancellationError() }
            if Date() >= deadline {
                if terminationSentAt == nil {
                    terminationSentAt = Date()
                    process.terminate()
                } else if Date().timeIntervalSince(terminationSentAt!) >= 0.25 {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        if isCancelled { throw CancellationError() }
        if Date() >= deadline { throw EngineError.operationTimedOut }
    }

    private func checkTransferState(_ process: Process, deadline: Date) throws {
        if isCancelled { throw CancellationError() }
        if !process.isRunning { throw EngineError.transport("ADB closed the file transfer stream early") }
        if Date() >= deadline { throw EngineError.operationTimedOut }
    }

    private func terminateAndReap(_ process: Process) {
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.25)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func clearProcess() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    private func closePipeEnds(inputPipe: Pipe?, outputPipe: Pipe?, errorPipe: Pipe) {
        try? inputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
    }

    private struct OwnedOutputFile {
        let descriptor: Int32
        let url: URL
        let device: dev_t
        let inode: ino_t
    }

    private static func openInput(_ url: URL?) throws -> Int32 {
        guard let url else { return -1 }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw EngineError.transport("Could not open the local ADB transfer source") }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw EngineError.transport("The local ADB transfer source is not a regular file")
        }
        return descriptor
    }

    private static func openOutput(_ url: URL?) throws -> OwnedOutputFile? {
        guard let url else { return nil }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw EngineError.transport("Could not create the private ADB transfer destination") }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw EngineError.transport("Could not verify the private ADB transfer destination")
        }
        return OwnedOutputFile(descriptor: descriptor, url: url, device: info.st_dev, inode: info.st_ino)
    }

    private static func removeOwnedOutput(_ output: OwnedOutputFile) {
        var info = stat()
        let matchesOwnedFile = output.url.path.withCString { Darwin.lstat($0, &info) == 0 }
            && info.st_dev == output.device && info.st_ino == output.inode
        guard matchesOwnedFile else { return }
        _ = output.url.path.withCString { Darwin.unlink($0) }
    }

    private static func write(_ data: Data, to descriptor: Int32, process: Process,
                              deadline: Date, isCancelled: () -> Bool) throws {
        try data.withUnsafeBytes { bytes in
            try write(bytes.baseAddress!, count: bytes.count, to: descriptor,
                      process: process, deadline: deadline, isCancelled: isCancelled)
        }
    }

    private static func write(_ bytes: UnsafeRawPointer, count: Int, to descriptor: Int32, process: Process,
                              deadline: Date, isCancelled: () -> Bool) throws {
        var offset = 0
        while offset < count {
            if isCancelled() { throw CancellationError() }
            if !process.isRunning { throw EngineError.transport("ADB closed the file transfer stream early") }
            if Date() >= deadline { throw EngineError.operationTimedOut }

            var watched = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&watched, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw EngineError.transport("Could not write the ADB file transfer stream")
            }
            if ready == 0 { continue }
            if watched.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw EngineError.transport("ADB closed the file transfer stream early")
            }
            let written = writeWithoutSIGPIPE(descriptor, bytes.advanced(by: offset), count - offset)
            if written < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw EngineError.transport("Could not write the ADB file transfer stream")
            }
            if written == 0 { continue }
            offset += written
        }
    }

    private static func writeWithoutSIGPIPE(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
        var blocked = sigset_t()
        sigemptyset(&blocked)
        sigaddset(&blocked, SIGPIPE)
        var previous = sigset_t()
        _ = pthread_sigmask(SIG_BLOCK, &blocked, &previous)
        let wasAlreadyBlocked = sigismember(&previous, SIGPIPE) == 1
        let written = Darwin.write(descriptor, bytes, count)
        let writeError = errno
        if written < 0, writeError == EPIPE, !wasAlreadyBlocked {
            var pending = sigset_t()
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 {
                var received: Int32 = 0
                _ = sigwait(&blocked, &received)
            }
        }
        _ = pthread_sigmask(SIG_SETMASK, &previous, nil)
        errno = writeError
        return written
    }
}

private final class ProcessOutputReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Androdo.ProcessOutputReader")
    private let hasData = DispatchSemaphore(value: 0)
    private var data = Data()
    private var reachedEOF = false
    private let maximumBytes: Int?
    private let handle: FileHandle
    private let source: DispatchSourceRead

    init(handle: FileHandle, maximumBytes: Int? = nil) {
        self.handle = handle
        self.maximumBytes = maximumBytes
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drainAvailableData() }
        source.setCancelHandler { [handle] in try? handle.close() }
        source.resume()
    }

    func waitForPrefix(_ expected: Data, process: Process, deadline: Date,
                       isCancelled: () -> Bool) throws -> Bool {
        while true {
            let state = queue.sync { (data.starts(with: expected), reachedEOF) }
            if state.0 { return true }
            if isCancelled() { throw CancellationError() }
            if state.1 || !process.isRunning { return false }
            if Date() >= deadline { return false }
            _ = hasData.wait(timeout: .now() + .milliseconds(25))
        }
    }

    func finish() -> Data {
        queue.sync {
            drainAvailableData()
            source.cancel()
            return data
        }
    }

    deinit { source.cancel() }

    private func drainAvailableData() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let remaining = maximumBytes.map { max(0, $0 - data.count) } ?? count
                if remaining > 0 { data.append(contentsOf: buffer.prefix(min(count, remaining))) }
                hasData.signal()
            } else if count == 0 {
                reachedEOF = true
                hasData.signal()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno == EINTR {
                continue
            } else {
                reachedEOF = true
                hasData.signal()
                return
            }
        }
    }
}
