import Foundation
import TP7Kit

public struct SyncedFile: Sendable, Equatable {
    public let lane: Lane
    public let name: String
    public let localURL: URL
    /// True when a known file was re-pulled because it changed on the device
    /// (cue edits grow files); refreshed memos must not be re-transcribed.
    public let isRefresh: Bool

    public init(lane: Lane, name: String, localURL: URL, isRefresh: Bool) {
        self.lane = lane
        self.name = name
        self.localURL = localURL
        self.isRefresh = isRefresh
    }
}

public struct SyncSummary: Sendable {
    public var newFiles: [SyncedFile] = []
    public var failures: [String] = []
    public var laneListingsMissing: [Lane] = []
}

/// Pull-new-only sync from the TP-7 into the local archive.
/// Archive layout: <archiveDir>/memos/… and <archiveDir>/recordings/…
/// Originals are immutable once landed; the manifest is the dedupe ledger.
public struct SyncEngine: Sendable {
    public let client: TP7Client
    public let archiveDir: URL
    public let retryPause: Duration
    public let lanes: [Lane]
    /// Remote paths awaiting deletion. Never pulled — a file the user deleted
    /// must not resurrect just because the device removal hasn't landed yet.
    public let excludedRemotePaths: Set<String>

    public init(
        client: TP7Client,
        archiveDir: URL,
        retryPause: Duration = .seconds(3),
        lanes: [Lane] = Lane.allCases,
        excludedRemotePaths: Set<String> = []
    ) {
        self.client = client
        self.archiveDir = archiveDir
        self.retryPause = retryPause
        self.lanes = lanes
        self.excludedRemotePaths = excludedRemotePaths
    }

    public var manifestURL: URL { archiveDir.appendingPathComponent("manifest.json") }

    public func sync(progress: (@Sendable (String) -> Void)? = nil) async throws -> SyncSummary {
        var manifest = Manifest(fileURL: manifestURL)
        var summary = SyncSummary()
        var retryQueue: [(lane: Lane, object: RemoteObject)] = []

        for lane in lanes {
            let listing: RemoteListing
            do {
                listing = try await client.list(lane.remoteFolder)
            } catch let TP7Error.commandFailed(_, stderr) where stderr.contains("not found") {
                // /memo does not exist until the on-device separation setting
                // has produced its first memo — that's expected, not a failure.
                summary.laneListingsMissing.append(lane)
                continue
            } catch {
                // A real error (USB glitch, permissions, device busy) must not
                // be silently swallowed as "lane doesn't exist yet".
                summary.failures.append("\(lane.rawValue): \(error)")
                continue
            }

            try FileManager.default.createDirectory(
                at: archiveDir.appendingPathComponent(lane.rawValue),
                withIntermediateDirectories: true
            )
            let laneDir = archiveDir.appendingPathComponent(lane.rawValue)

            for object in listing.entries where object.kind == .file {
                // The CLI names an in-progress upload "<name>.tp7cli-upload-…tmp"
                // and cleans it up on success; a stray one (interrupted push)
                // must never show up as a real file. Left on the device on
                // purpose — this app doesn't delete files it didn't create.
                guard !isIncompleteTransferArtifact(object.name) else { continue }
                guard !excludedRemotePaths.contains("\(lane.remoteFolder)/\(object.name)") else { continue }
                let key = ManifestKey(lane: lane, name: object.name)
                if let existing = manifest.entry(for: key), existing.size == object.size,
                   FileManager.default.fileExists(atPath: laneDir.appendingPathComponent(object.name).path) {
                    continue   // known, unchanged, and actually still on disk
                }
                progress?("Pulling \(object.name)")
                if await pullOne(lane: lane, object: object, manifest: &manifest, summary: &summary) != nil {
                    retryQueue.append((lane, object))
                }
            }
        }

        // A device file can vanish before the next dock, so a failed pull gets
        // one more chance within the same sync rather than waiting for it.
        for (lane, object) in retryQueue {
            progress?("Retrying \(object.name)")
            try? await Task.sleep(for: retryPause)
            if let failure = await pullOne(lane: lane, object: object, manifest: &manifest, summary: &summary) {
                summary.failures.append(failure)
            }
        }
        return summary
    }

    /// Returns nil on success, or the failure description. Pulls into a fresh
    /// staging directory and verifies before replacing anything, so a bad
    /// transfer can never destroy the last good local copy — `--skip-existing`
    /// in the CLI matches on filename alone (any size), so pulling straight
    /// into laneDir on a refresh could silently no-op against a stale file.
    private func pullOne(
        lane: Lane,
        object: RemoteObject,
        manifest: inout Manifest,
        summary: inout SyncSummary
    ) async -> String? {
        let key = ManifestKey(lane: lane, name: object.name)
        let laneDir = archiveDir.appendingPathComponent(lane.rawValue)
        let remotePath = "\(lane.remoteFolder)/\(object.name)"
        let isRefresh = manifest.entry(for: key) != nil
        let fm = FileManager.default
        let stagingDir = archiveDir
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: stagingDir) }
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try await client.pull(remotePath, to: stagingDir, skipExisting: false)
            let stagedURL = stagingDir.appendingPathComponent(object.name)
            let attrs = try fm.attributesOfItem(atPath: stagedURL.path)
            let stagedSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            guard stagedSize == object.size else {
                return "\(object.name): size mismatch after pull (device reports \(object.size), got \(stagedSize)) — local copy untouched"
            }
            let localURL = laneDir.appendingPathComponent(object.name)
            if fm.fileExists(atPath: localURL.path) {
                _ = try fm.replaceItemAt(localURL, withItemAt: stagedURL)
            } else {
                try fm.moveItem(at: stagedURL, to: localURL)
            }
            // Refreshes keep everything the entry knew (title, transcript,
            // sent state); only the size and sync time move.
            var entry = manifest.entry(for: key)
                ?? ManifestEntry(localPath: localURL.path, syncedAt: Date())
            entry.localPath = localURL.path
            entry.syncedAt = Date()
            entry.size = object.size
            try manifest.record(key, entry: entry)
            summary.newFiles.append(
                SyncedFile(lane: lane, name: object.name, localURL: localURL, isRefresh: isRefresh)
            )
            return nil
        } catch {
            return "\(object.name): \(error)"
        }
    }

    /// Matches the tp7 CLI's own in-flight upload naming:
    /// "<original-name>.tp7cli-<label>-<stamp>-<attempt>.tmp"
    private func isIncompleteTransferArtifact(_ name: String) -> Bool {
        name.hasSuffix(".tmp") && name.contains(".tp7cli-")
    }
}
