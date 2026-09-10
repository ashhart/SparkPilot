import Foundation
import SparkTransport
import Testing
@testable import SparkAPI

private struct TerminalInteropFixture: Decodable {
    let route: URL
    let pin: String
    let projectID: String
    let terminalID: String
    let headers: [[String: String]]
}

private struct TerminalInteropSigner: RequestSigning {
    let headers: [String: String]
    func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
        var request = request
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["SPARK_TERMINAL_INTEROP_DIRECTORY"] != nil),
    .timeLimit(.minutes(1))
)
func terminalSocketRuntimeInterop() async throws {
    let directory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["SPARK_TERMINAL_INTEROP_DIRECTORY"]!
    )
    let fixture = try JSONDecoder().decode(
        TerminalInteropFixture.self,
        from: Data(contentsOf: directory.appendingPathComponent("terminal.json"))
    )
    defer { try? Data().write(to: directory.appendingPathComponent("terminal.done")) }
    func makeSocket(_ index: Int, pin: String? = nil) throws -> ProjectTerminalSocket {
        try ProjectTerminalSocket(
            baseURL: fixture.route,
            pin: pin ?? fixture.pin,
            signer: TerminalInteropSigner(headers: fixture.headers[index]),
            projectID: fixture.projectID,
            terminalID: fixture.terminalID
        )
    }
    let first = try makeSocket(0)
    do {
        await first.start()
        try await first.waitUntilConnected()
        try await first.resize(columns: 100, rows: 30)
        try await first.send("terminal-apple-canary\n")
        var output = ""
        while !output.contains("terminal-apple-canary") { output += try await first.receive() }
        #expect(output.contains("\u{1b}[2J\u{1b}[HOMP startup prompt> "))
        await first.cancel()
        let resumed = try makeSocket(1)
        await resumed.start()
        try await resumed.waitUntilConnected()
        var replay = ""
        while !replay.contains("terminal-apple-canary") { replay += try await resumed.receive() }
        #expect(replay.contains("OMP startup prompt> "))
        await resumed.cancel()
        let untrusted = try makeSocket(2, pin: String(repeating: "0", count: 64))
        await untrusted.start()
        await #expect(throws: PinnedTransportError.certificateRejected(host: fixture.route.host!)) {
            try await untrusted.waitUntilConnected()
        }
        await untrusted.cancel()
    } catch {
        await first.cancel()
        throw error
    }
}
