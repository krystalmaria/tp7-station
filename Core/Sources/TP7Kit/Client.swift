import Foundation

/// Typed access to the patched `tp7` CLI. Every device operation runs
/// `--json --no-progress` and retries once — transient USB I/O errors are
/// normal on this hardware (~1 in 12 operations) and a single retry has
/// always sufficed in testing.
public struct TP7Client: Sendable {
    public let transport: TP7Transport
    public var retryDelay: Duration

    public init(transport: TP7Transport = CLIProcessTransport(), retryDelay: Duration = .seconds(4)) {
        self.transport = transport
        self.retryDelay = retryDelay
    }

    // MARK: Queries

    /// Enumerates TP-7s over USB. Cheap — no MTP mode switch. Empty when unplugged.
    public func devices() async throws -> [TP7Device] {
        let data = try await run(["-j", "devices"], retries: 0)
        return try decode([TP7Device].self, from: data)
    }

    public func list(_ remotePath: String) async throws -> RemoteListing {
        let data = try await run(["-j", "--no-progress", "-a", "ls", remotePath])
        return try decode(RemoteListing.self, from: data)
    }

    // MARK: Transfers

    @discardableResult
    public func pull(_ remotePath: String, to localDir: URL, skipExisting: Bool = true) async throws -> PullReport {
        var args = ["-j", "--no-progress", "-a", "pull", remotePath, localDir.path]
        if skipExisting { args.append("--skip-existing") }
        let data = try await run(args)
        return try decode(PullReport.self, from: data)
    }

    public func push(_ localFile: URL, to remotePath: String, overwrite: Bool = false) async throws {
        var args = ["-j", "--no-progress", "-a", "push", localFile.path, remotePath]
        if overwrite { args.append("--overwrite") }
        _ = try await run(args)
    }

    // MARK: Mutations

    @discardableResult
    public func rename(_ remotePath: String, to newName: String) async throws -> RenameReport {
        let data = try await run(["-j", "--no-progress", "-a", "rename", remotePath, newName])
        return try decode(RenameReport.self, from: data)
    }

    public func remove(_ remotePath: String) async throws {
        _ = try await run(["-j", "--no-progress", "-a", "rm", remotePath])
    }

    // MARK: Internals

    private func run(_ arguments: [String], retries: Int = 1) async throws -> Data {
        var lastError: Error?
        for attempt in 0...retries {
            if attempt > 0 { try? await Task.sleep(for: retryDelay) }
            do {
                return try await transport.run(arguments)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TP7Error.commandFailed(exitCode: -1, stderr: "unknown")
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            throw TP7Error.decodingFailed("\(error) — output: \(preview)")
        }
    }
}
