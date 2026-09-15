import Foundation

public enum Lane: String, Codable, Sendable, CaseIterable {
    case memos
    case recordings
    case library

    public var remoteFolder: String {
        switch self {
        case .memos: "/memo"
        case .recordings: "/recordings"
        case .library: "/library"
        }
    }
}

/// Identity of a device file: lane + filename. MTP object handles are unstable
/// and upload timestamps meaningless on this hardware, so the name (which
/// carries the recording datetime) is the durable key. Size is deliberately
/// NOT identity: cue edits change a file's size without changing what it is.
public struct ManifestKey: Hashable, Codable, Sendable {
    public let lane: Lane
    public let name: String

    public init(lane: Lane, name: String) {
        self.lane = lane
        self.name = name
    }

    var stringKey: String { "\(lane.rawValue)|\(name)" }
}

public struct ManifestEntry: Codable, Sendable, Equatable {
    public var localPath: String
    public var syncedAt: Date
    /// Last-synced size; a device file reporting a different size has been
    /// edited (cues added, etc.) and needs its local copy refreshed.
    public var size: UInt64?
    public var processedAt: Date?
    /// Set only when the memo has been sent to the vault — presence is the
    /// "sent" memory the inbox shows.
    public var notePath: String?
    public var title: String?
    public var transcript: String?
    public var summary: String?

    public init(
        localPath: String,
        syncedAt: Date,
        size: UInt64? = nil,
        processedAt: Date? = nil,
        notePath: String? = nil,
        title: String? = nil,
        transcript: String? = nil,
        summary: String? = nil
    ) {
        self.localPath = localPath
        self.syncedAt = syncedAt
        self.size = size
        self.processedAt = processedAt
        self.notePath = notePath
        self.title = title
        self.transcript = transcript
        self.summary = summary
    }
}

/// JSON-file-backed sync state. Saved after every mutation so an interrupted
/// sync resumes cleanly. // single JSON file is fine at personal scale; move to SQLite if the archive grows past thousands of entries
public struct Manifest: Sendable {
    public private(set) var entries: [String: ManifestEntry]
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: ManifestEntry].self, from: data)
        else {
            self.entries = [:]
            return
        }

        // Migrate legacy "lane|name|size" keys to "lane|name", folding the
        // size into the entry. Same-name duplicates (the bug this migration
        // kills) merge: newest sync wins, non-nil fields are preserved.
        var migrated: [String: ManifestEntry] = [:]
        var didMigrate = false
        for (key, entry) in decoded {
            let parts = key.split(separator: "|")
            guard parts.count == 3, let legacySize = UInt64(parts[2]) else {
                migrated[key] = Self.merge(existing: migrated[key], with: entry)
                continue
            }
            didMigrate = true
            var updated = entry
            if updated.size == nil { updated.size = legacySize }
            let newKey = "\(parts[0])|\(parts[1])"
            migrated[newKey] = Self.merge(existing: migrated[newKey], with: updated)
        }
        self.entries = migrated
        if didMigrate { try? save() }
    }

    public func contains(_ key: ManifestKey) -> Bool {
        entries[key.stringKey] != nil
    }

    /// Newer sync wins as the base; fields the base lacks are taken from the
    /// other so vault/send state survives a merge.
    private static func merge(existing: ManifestEntry?, with candidate: ManifestEntry) -> ManifestEntry {
        guard let existing else { return candidate }
        var base = existing.syncedAt >= candidate.syncedAt ? existing : candidate
        let other = existing.syncedAt >= candidate.syncedAt ? candidate : existing
        base.size = base.size ?? other.size
        base.processedAt = base.processedAt ?? other.processedAt
        base.notePath = base.notePath ?? other.notePath
        base.title = base.title ?? other.title
        base.transcript = base.transcript ?? other.transcript
        base.summary = base.summary ?? other.summary
        return base
    }

    public func entry(for key: ManifestKey) -> ManifestEntry? {
        entries[key.stringKey]
    }

    public mutating func record(_ key: ManifestKey, entry: ManifestEntry) throws {
        entries[key.stringKey] = entry
        try save()
    }

    public mutating func remove(_ key: ManifestKey) throws {
        entries[key.stringKey] = nil
        try save()
    }

    /// Moves an entry to a new key (file renamed on device + locally) so the
    /// next sync doesn't mistake the renamed file for a new one.
    public mutating func rename(_ key: ManifestKey, to newKey: ManifestKey, entry: ManifestEntry) throws {
        entries[key.stringKey] = nil
        entries[newKey.stringKey] = entry
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
