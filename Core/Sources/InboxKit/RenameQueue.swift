import Foundation
import TP7Kit

public struct QueuedRename: Codable, Sendable, Equatable {
    public let remotePath: String
    public let newName: String

    public init(remotePath: String, newName: String) {
        self.remotePath = remotePath
        self.newName = newName
    }
}

/// Renames that need the device present. Persisted next to the manifest and
/// applied at the next dock; applying is idempotent (a missing source file
/// means the rename already happened or the file is gone — either way, done).
public struct RenameQueue: Sendable {
    public private(set) var pending: [QueuedRename]
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([QueuedRename].self, from: data) {
            self.pending = decoded
        } else {
            self.pending = []
        }
    }

    public mutating func enqueue(_ rename: QueuedRename) throws {
        guard !pending.contains(rename) else { return }
        pending.append(rename)
        try save()
    }

    /// Drops queued renames for a path — a manual rename supersedes any
    /// pending automatic one.
    public mutating func removePending(remotePath: String) {
        pending.removeAll { $0.remotePath == remotePath }
        try? save()
    }

    /// Proposed device name for a processed memo: keep the datetime prefix
    /// (it is the only reliable date carrier), append the kebab-case title.
    public static func deviceName(originalName: String, title: String) -> String {
        let stem = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        let prefix = stem.split(separator: "_").prefix(2).joined(separator: "_")
        let kebab = title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, ch in
                if ch == "-" && result.hasSuffix("-") { return }
                result.append(ch)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = prefix.isEmpty ? kebab : "\(prefix)_\(kebab)"
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    public mutating func apply(with client: TP7Client) async -> [QueuedRename] {
        var applied: [QueuedRename] = []
        var remaining: [QueuedRename] = []
        for rename in pending {
            do {
                _ = try await client.rename(rename.remotePath, to: rename.newName)
                applied.append(rename)
            } catch {
                remaining.append(rename)
            }
        }
        pending = remaining
        try? save()
        return applied
    }

    private func save() throws {
        let data = try JSONEncoder().encode(pending)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
