import Foundation

public protocol TP7Transport: Sendable {
    func run(_ arguments: [String]) async throws -> Data
}

/// Thread-safe append buffer — Process's readabilityHandler and
/// terminationHandler both fire on background queues, not necessarily the
/// same one, so accumulation needs a lock rather than an actor hop.
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
    }

    var snapshot: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// Guards a `CheckedContinuation` against multiple resumes — termination and
/// the timeout task race to resume it, and only the first should count.
private final class ContinuationGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<Data, Error>

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Data, Error>) {
        lock.lock()
        let already = resumed
        resumed = true
        lock.unlock()
        guard !already else { return }
        switch result {
        case .success(let data): continuation.resume(returning: data)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

public struct CLIProcessTransport: TP7Transport {
    public let executable: URL
    /// A hung child process (stalled USB transfer, device wedged) must not
    /// freeze the app indefinitely — it gets killed and reported instead.
    public let timeout: Duration

    public init(
        executable: URL = CLIProcessTransport.resolveExecutable(),
        timeout: Duration = .seconds(180)
    ) {
        self.executable = executable
        self.timeout = timeout
    }

    /// A signed release bundles its own copy of the CLI in Resources — found
    /// there first, so a downloaded app needs no Homebrew/Rust toolchain at
    /// all. A local `swift build`/dev run (no such resource) falls back to
    /// the Homebrew install, leaving the everyday dev workflow unchanged.
    public static func resolveExecutable() -> URL {
        if let bundled = Bundle.main.url(forResource: "tp7", withExtension: nil) {
            return bundled
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/tp7")
    }

    public func run(_ arguments: [String]) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TP7Error.executableNotFound(executable.path)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain continuously as data arrives, not just at termination — a
        // large `ls` listing or verbose stderr can exceed the pipe's 64KB
        // buffer, and an unread pipe blocks the child writing to it forever.
        let outBuffer = DataAccumulator()
        let errBuffer = DataAccumulator()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBuffer.append(chunk) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBuffer.append(chunk) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let guardian = ContinuationGuard(continuation)

            let timeoutTask = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                if process.isRunning { process.terminate() }
                guardian.resume(with: .failure(TP7Error.commandFailed(
                    exitCode: -1,
                    stderr: "tp7 did not respond within \(timeout) — the process was terminated."
                )))
            }

            process.terminationHandler = { process in
                timeoutTask.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // The readability handler is best-effort and asynchronous —
                // a process that exits fast enough can terminate before it
                // has actually fired, losing output. A final synchronous
                // drain-to-EOF here is safe either way: stream position means
                // it only ever returns whatever the handler hasn't already
                // consumed, never a duplicate.
                let finalOut = stdout.fileHandleForReading.readDataToEndOfFile()
                let finalErr = stderr.fileHandleForReading.readDataToEndOfFile()
                if !finalOut.isEmpty { outBuffer.append(finalOut) }
                if !finalErr.isEmpty { errBuffer.append(finalErr) }
                let outData = outBuffer.snapshot
                let errData = errBuffer.snapshot
                if process.terminationStatus == 0 {
                    guardian.resume(with: .success(outData))
                } else {
                    let message = String(data: errData, encoding: .utf8) ?? ""
                    guardian.resume(with: .failure(TP7Error.commandFailed(
                        exitCode: process.terminationStatus,
                        stderr: message
                    )))
                }
            }
            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guardian.resume(with: .failure(error))
            }
        }
    }
}
