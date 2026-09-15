import Foundation
import Testing
@testable import TP7Kit

/// Exercises CLIProcessTransport directly (not the mock) against real
/// short-lived processes — this is what actually deadlocked or hung before
/// the timeout + continuous pipe draining fix.
@Test func timesOutAndKillsAHungProcess() async throws {
    let transport = CLIProcessTransport(
        executable: URL(fileURLWithPath: "/bin/sleep"),
        timeout: .milliseconds(200)
    )
    await #expect(throws: TP7Error.self) {
        _ = try await transport.run(["5"])
    }
}

@Test func drainsOutputLargerThanADefaultPipeBuffer() async throws {
    // /bin/dd fed from /dev/zero, base64'd, well past the 64KB pipe buffer —
    // would deadlock a terminationHandler-only drain.
    let transport = CLIProcessTransport(executable: URL(fileURLWithPath: "/bin/sh"))
    let data = try await transport.run([
        "-c", "dd if=/dev/zero bs=1024 count=300 2>/dev/null | base64",
    ])
    #expect(data.count > 65536)
}

@Test func succeedsWellUnderTimeout() async throws {
    let transport = CLIProcessTransport(
        executable: URL(fileURLWithPath: "/bin/echo"),
        timeout: .seconds(5)
    )
    let data = try await transport.run(["hello"])
    #expect(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}
