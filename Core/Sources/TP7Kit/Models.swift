import Foundation

public struct TP7Device: Codable, Sendable, Equatable {
    public let vendorId: UInt16
    public let productId: UInt16
    public let product: String?
    public let serialNumber: String?
    public let mode: String
    public let deviceVersion: String?

    enum CodingKeys: String, CodingKey {
        case vendorId = "vendor_id"
        case productId = "product_id"
        case product
        case serialNumber = "serial_number"
        case mode
        case deviceVersion = "device_version"
    }
}

public enum RemoteKind: String, Codable, Sendable {
    case file
    case folder
}

public struct RemoteObject: Codable, Sendable, Equatable {
    public let id: UInt32
    public let kind: RemoteKind
    public let name: String
    public let size: UInt64
    public let modified: String?

    public init(id: UInt32, kind: RemoteKind, name: String, size: UInt64, modified: String?) {
        self.id = id
        self.kind = kind
        self.name = name
        self.size = size
        self.modified = modified
    }
}

public struct RemoteListing: Codable, Sendable {
    public let path: String
    public let entries: [RemoteObject]
}

public struct PullFileReport: Codable, Sendable {
    public let remotePath: String
    public let localPath: String
    public let size: UInt64
    public let status: String

    enum CodingKeys: String, CodingKey {
        case remotePath = "remote_path"
        case localPath = "local_path"
        case size
        case status
    }
}

public struct PullReport: Codable, Sendable {
    public let remotePath: String
    public let localPath: String
    public let downloaded: Int
    public let skipped: Int
    public let totalBytes: UInt64
    public let files: [PullFileReport]

    enum CodingKeys: String, CodingKey {
        case remotePath = "remote_path"
        case localPath = "local_path"
        case downloaded
        case skipped
        case totalBytes = "total_bytes"
        case files
    }
}

public struct RenameReport: Codable, Sendable {
    public let oldPath: String
    public let newPath: String

    enum CodingKeys: String, CodingKey {
        case oldPath = "old_path"
        case newPath = "new_path"
    }
}

public enum TP7Error: Error, Sendable {
    case commandFailed(exitCode: Int32, stderr: String)
    case decodingFailed(String)
    case executableNotFound(String)
}
