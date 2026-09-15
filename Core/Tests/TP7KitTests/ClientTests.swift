import Foundation
import Testing
@testable import TP7Kit

/// Canned-response transport; optionally fails N times first to exercise retry.
final class MockTransport: TP7Transport, @unchecked Sendable {
    var responses: [String: Data] = [:]
    var failuresBeforeSuccess = 0
    private(set) var calls: [[String]] = []

    func run(_ arguments: [String]) async throws -> Data {
        calls.append(arguments)
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw TP7Error.commandFailed(exitCode: 1, stderr: "MTP operation failed: I/O error")
        }
        let key = arguments.joined(separator: " ")
        for (fragment, data) in responses where key.contains(fragment) {
            return data
        }
        return Data("{}".utf8)
    }
}

private let lsJSON = """
{
  "path": "/recordings",
  "storage_id": 65537,
  "entries": [
    {"id": 42, "parent_id": 10, "storage_id": 65537, "kind": "file",
     "name": "2026-08-29_205704_000.wav", "size": 10618444, "modified": "20260829T205722"},
    {"id": 43, "parent_id": 10, "storage_id": 65537, "kind": "folder",
     "name": "somefolder", "size": 0, "modified": null}
  ]
}
"""

@Test func decodesListing() async throws {
    let mock = MockTransport()
    mock.responses["ls"] = Data(lsJSON.utf8)
    let client = TP7Client(transport: mock, retryDelay: .milliseconds(1))

    let listing = try await client.list("/recordings")
    #expect(listing.entries.count == 2)
    #expect(listing.entries[0].kind == .file)
    #expect(listing.entries[0].size == 10618444)
    #expect(listing.entries[1].kind == .folder)
}

@Test func decodesEmptyDeviceList() async throws {
    let mock = MockTransport()
    mock.responses["devices"] = Data("[]".utf8)
    let client = TP7Client(transport: mock, retryDelay: .milliseconds(1))
    let devices = try await client.devices()
    #expect(devices.isEmpty)
}

@Test func decodesRealDeviceEntry() async throws {
    let json = """
    [{"vendor_id": 9063, "product_id": 32793, "vendor_id_hex": "0x2367",
      "product_id_hex": "0x8019", "manufacturer": "teenage engineering",
      "product": "TP-7", "serial_number": "TP7EXMPL", "mode": "audio-midi",
      "speed": "high", "usb_version": "2.0.0", "device_version": "2.5.7",
      "class": 0, "subclass": 0, "protocol": 0, "bus_id": "02",
      "device_address": 1, "port_chain": [1], "location_id": "0x02100000",
      "registry_entry_id": null, "interfaces": []}]
    """
    let mock = MockTransport()
    mock.responses["devices"] = Data(json.utf8)
    let client = TP7Client(transport: mock, retryDelay: .milliseconds(1))
    let devices = try await client.devices()
    #expect(devices.count == 1)
    #expect(devices[0].serialNumber == "TP7EXMPL")
    #expect(devices[0].productId == 0x8019)
    #expect(devices[0].mode == "audio-midi")
}

@Test func retriesOnceOnTransientFailure() async throws {
    let mock = MockTransport()
    mock.responses["ls"] = Data(lsJSON.utf8)
    mock.failuresBeforeSuccess = 1
    let client = TP7Client(transport: mock, retryDelay: .milliseconds(1))

    let listing = try await client.list("/recordings")
    #expect(listing.entries.count == 2)
    #expect(mock.calls.count == 2)
}

@Test func surfacesErrorAfterRetryExhausted() async throws {
    let mock = MockTransport()
    mock.failuresBeforeSuccess = 5
    let client = TP7Client(transport: mock, retryDelay: .milliseconds(1))
    await #expect(throws: TP7Error.self) {
        _ = try await client.list("/recordings")
    }
    #expect(mock.calls.count == 2)
}
