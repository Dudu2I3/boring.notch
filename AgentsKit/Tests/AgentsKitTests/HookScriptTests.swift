import Foundation
import Testing
@testable import AgentsKit

private func writeScript(socketPath: String) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/na-hook-\(UUID().uuidString.prefix(8)).sh")
    try HookScript.body(socketPath: socketPath).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// Runs the script like Claude Code does: hook JSON on stdin, environment from the agent.
private func runScript(_ url: URL, stdin: String, env: [String: String]) throws -> (status: Int32, stdout: String, seconds: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [url.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()].merging(env) { $1 }
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let started = Date()
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, out, Date().timeIntervalSince(started))
}

private let hookJSON = """
{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/Users/me/p",
 "tool_name":"Bash","tool_input":{"command":"echo \\"hi\\""}}
"""

@Test func deliversEnvelopeToSocket() throws {
    let socketPath = shortTempSocketPath()
    let inbox = Inbox()
    let server = AgentSocketServer(path: socketPath) { inbox.add($0) }
    try server.start()
    defer { server.stop() }
    let script = try writeScript(socketPath: socketPath)

    let result = try runScript(script, stdin: hookJSON, env: [
        "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:ABC",
        "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_PID": "\(getpid())",
    ])
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.seconds < 0.5)

    #expect(waitUntil { inbox.all.count == 1 })
    let event = try #require(inbox.all.first.flatMap(AgentEvent.parse))
    #expect(event.kind == .preToolUse(tool: "Bash", input: ["command": "echo \"hi\""]))
    #expect(event.origin.source == .iterm)
    #expect(event.origin.pid == getpid())
    #expect(event.origin.itermSessionID == "w0t0p0:ABC")
}

@Test func exitsInstantlyWithoutSocket() throws {
    let script = try writeScript(socketPath: "/tmp/na-missing-\(UUID().uuidString.prefix(8)).sock")
    let result = try runScript(script, stdin: hookJSON, env: [:])
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.seconds < 0.2)
}

@Test func envOverrideWinsOverBakedPath() throws {
    let socketPath = shortTempSocketPath()
    let inbox = Inbox()
    let server = AgentSocketServer(path: socketPath) { inbox.add($0) }
    try server.start()
    defer { server.stop() }
    let script = try writeScript(socketPath: "/tmp/na-wrong.sock")
    _ = try runScript(script, stdin: hookJSON, env: ["NOTCH_AGENTS_SOCKET": socketPath])
    #expect(waitUntil { inbox.all.count == 1 })
}

@Test func scriptCarriesMarker() {
    #expect(HookScript.body(socketPath: "/x").contains(HookInstaller.marker))
}
