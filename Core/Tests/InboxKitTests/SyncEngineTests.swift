import Foundation
import Testing
import TP7Kit
@testable import InboxKit

/// Transport that simulates the device: answers ls with a listing and writes
/// a local file (matching the advertised size) when asked to pull.
final class FakeDeviceTransport: TP7Transport, @unchecked Sendable {
    var files: [String: [(name: String, size: Int)]]
    var failPullsMatching: String?
    private(set) var pullCount = 0

    init(files: [String: [(name: String, size: Int)]]) {
        self.files = files
    }

    func run(_ arguments: [String]) async throws -> Data {
        if let index = arguments.firstIndex(of: "ls") {
            let path = arguments[index + 1]
            guard let entries = files[path] else {
                throw TP7Error.commandFailed(exitCode: 1, stderr: "error: path not found: \(path)")
            }
            let objects = entries.enumerated().map { i, f in
                """
                {"id": \(i), "parent_id": 0, "storage_id": 65537, "kind": "file",
                 "name": "\(f.name)", "size": \(f.size), "modified": null}
                """
            }.joined(separator: ",")
            return Data("{\"path\": \"\(path)\", \"storage_id\": 65537, \"entries\": [\(objects)]}".utf8)
        }
        if let index = arguments.firstIndex(of: "pull") {
            pullCount += 1
            let remote = arguments[index + 1]
            let localDir = arguments[index + 2]
            if let pattern = failPullsMatching, remote.contains(pattern) {
                throw TP7Error.commandFailed(exitCode: 1, stderr: "MTP operation failed: I/O error")
            }
            let name = (remote as NSString).lastPathComponent
            let folder = (remote as NSString).deletingLastPathComponent
            let size = files[folder]?.first { $0.name == name }?.size ?? 0
            let url = URL(fileURLWithPath: localDir).appendingPathComponent(name)
            try Data(repeating: 0x01, count: size).write(to: url)
            return Data("{\"remote_path\": \"\(remote)\", \"local_path\": \"\(url.path)\", \"dry_run\": false, \"downloaded\": 1, \"skipped\": 0, \"total_bytes\": \(size), \"files\": []}".utf8)
        }
        if arguments.contains("rename") {
            return Data("{\"old_path\": \"a\", \"new_path\": \"b\", \"object\": {\"id\": 1, \"parent_id\": 0, \"storage_id\": 65537, \"kind\": \"file\", \"name\": \"b\", \"size\": 1, \"modified\": null}}".utf8)
        }
        return Data("{}".utf8)
    }
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tp7-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func syncPullsNewFilesOnlyOnce() async throws {
    let transport = FakeDeviceTransport(files: [
        "/memo": [("2026-09-01_101500_000.wav", 500)],
        "/recordings": [("2026-08-29_205704_000.wav", 900)],
    ])
    let archive = tempDir()
    let engine = SyncEngine(client: TP7Client(transport: transport, retryDelay: .milliseconds(1)), archiveDir: archive)

    let first = try await engine.sync()
    #expect(first.newFiles.count == 2)
    #expect(first.failures.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: archive.appendingPathComponent("memos/2026-09-01_101500_000.wav").path))

    let second = try await engine.sync()
    #expect(second.newFiles.isEmpty)   // manifest dedupe
}

@Test func missingMemoFolderIsTolerated() async throws {
    let transport = FakeDeviceTransport(files: [
        "/recordings": [("take.wav", 100)]
    ])
    let engine = SyncEngine(client: TP7Client(transport: transport, retryDelay: .milliseconds(1)), archiveDir: tempDir())
    let summary = try await engine.sync()
    #expect(summary.laneListingsMissing == [.memos, .library])
    #expect(summary.newFiles.count == 1)
}

@Test func failedPullDoesNotPoisonManifestAndResumes() async throws {
    let transport = FakeDeviceTransport(files: [
        "/memo": [("good.wav", 10), ("bad.wav", 20)],
        "/recordings": [],
    ])
    transport.failPullsMatching = "bad"
    let archive = tempDir()
    let engine = SyncEngine(
        client: TP7Client(transport: transport, retryDelay: .milliseconds(1)),
        archiveDir: archive,
        retryPause: .milliseconds(1)
    )

    let first = try await engine.sync()
    #expect(first.newFiles.map(\.name) == ["good.wav"])
    #expect(first.failures.count == 1)

    transport.failPullsMatching = nil
    let second = try await engine.sync()
    #expect(second.newFiles.map(\.name) == ["bad.wav"])   // resumed cleanly
}

@Test func sizeChangeRefreshesInsteadOfDuplicating() async throws {
    let transport = FakeDeviceTransport(files: [
        "/library": [("song.wav", 1000)],
        "/memo": [], "/recordings": [],
    ])
    let archive = tempDir()
    let engine = SyncEngine(client: TP7Client(transport: transport, retryDelay: .milliseconds(1)), archiveDir: archive)

    let first = try await engine.sync()
    #expect(first.newFiles.map(\.isRefresh) == [false])

    // Cue edits grow the file on the device.
    transport.files["/library"] = [("song.wav", 1036)]
    let second = try await engine.sync()
    #expect(second.newFiles.map(\.name) == ["song.wav"])
    #expect(second.newFiles.map(\.isRefresh) == [true])

    // One ledger row, updated size — never a duplicate.
    let manifest = Manifest(fileURL: archive.appendingPathComponent("manifest.json"))
    let rows = manifest.entries.keys.filter { $0.contains("song.wav") }
    #expect(rows == ["library|song.wav"])
    #expect(manifest.entry(for: ManifestKey(lane: .library, name: "song.wav"))?.size == 1036)

    let third = try await engine.sync()
    #expect(third.newFiles.isEmpty)
}

@Test func legacyManifestKeysMigrateAndMergeDuplicates() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("manifest.json")
    let legacy = """
    {
      "library|song.wav|1000": {"localPath": "/a/song.wav", "syncedAt": 700000000},
      "library|song.wav|1036": {"localPath": "/a/song.wav", "syncedAt": 700000500,
                                "title": "kept title"},
      "memos|note.wav|50": {"localPath": "/a/note.wav", "syncedAt": 700000000,
                            "notePath": "/vault/note.md"}
    }
    """
    try Data(legacy.utf8).write(to: url)
    let manifest = Manifest(fileURL: url)
    #expect(manifest.entries.count == 2)
    let song = manifest.entry(for: ManifestKey(lane: .library, name: "song.wav"))
    #expect(song?.size == 1036)
    #expect(song?.title == "kept title")
    let note = manifest.entry(for: ManifestKey(lane: .memos, name: "note.wav"))
    #expect(note?.notePath == "/vault/note.md")
    #expect(note?.size == 50)
}

@Test func tombstonedFilesAreNeverPulled() async throws {
    let transport = FakeDeviceTransport(files: [
        "/memo": [("keep.wav", 10), ("deleted.wav", 20)],
        "/recordings": [], "/library": [],
    ])
    let engine = SyncEngine(
        client: TP7Client(transport: transport, retryDelay: .milliseconds(1)),
        archiveDir: tempDir(),
        excludedRemotePaths: ["/memo/deleted.wav"]
    )
    let summary = try await engine.sync()
    #expect(summary.newFiles.map(\.name) == ["keep.wav"])
    #expect(summary.failures.isEmpty)
}

@Test func incompleteUploadArtifactsAreNeverShown() async throws {
    let transport = FakeDeviceTransport(files: [
        "/library": [
            ("song.wav", 1000),
            ("other.wav.tp7cli-upload-1725000000-1.tmp", 40),
        ],
        "/memo": [], "/recordings": [],
    ])
    let engine = SyncEngine(client: TP7Client(transport: transport, retryDelay: .milliseconds(1)), archiveDir: tempDir())
    let summary = try await engine.sync()
    #expect(summary.newFiles.map(\.name) == ["song.wav"])
    #expect(summary.failures.isEmpty)
}

@Test func laneFilterSkipsExcludedLanes() async throws {
    let transport = FakeDeviceTransport(files: [
        "/memo": [("a.wav", 10)],
        "/recordings": [("b.wav", 20)],
        "/library": [("c.wav", 30)],
    ])
    let engine = SyncEngine(
        client: TP7Client(transport: transport, retryDelay: .milliseconds(1)),
        archiveDir: tempDir(),
        lanes: [.memos, .recordings]
    )
    let summary = try await engine.sync()
    #expect(summary.newFiles.map(\.name).sorted() == ["a.wav", "b.wav"])
    #expect(summary.laneListingsMissing.isEmpty)
}

@Test func renameQueuePersistsAndAppliesIdempotently() async throws {
    let dir = tempDir()
    let queueURL = dir.appendingPathComponent("renames.json")
    var queue = RenameQueue(fileURL: queueURL)
    try queue.enqueue(QueuedRename(remotePath: "/memo/a.wav", newName: "a_thought.wav"))
    try queue.enqueue(QueuedRename(remotePath: "/memo/a.wav", newName: "a_thought.wav"))  // duplicate ignored
    #expect(queue.pending.count == 1)

    var reloaded = RenameQueue(fileURL: queueURL)
    #expect(reloaded.pending.count == 1)

    let transport = FakeDeviceTransport(files: [:])
    let applied = await reloaded.apply(with: TP7Client(transport: transport, retryDelay: .milliseconds(1)))
    #expect(applied.count == 1)
    #expect(reloaded.pending.isEmpty)
}

@Test func deviceNameKeepsDatetimePrefixAndKebabsTitle() {
    let name = RenameQueue.deviceName(
        originalName: "2026-09-01_101500_000.wav",
        title: "Deliberately pointless hobbies!"
    )
    #expect(name == "2026-09-01_101500_deliberately-pointless-hobbies.wav")
}
