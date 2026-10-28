import Foundation
import Testing
@testable import AgentsKit

@Test func currentProcessIsAlive() {
    #expect(ProcessProbe.isAlive(getpid()))
}

@Test func finishedProcessIsDead() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    #expect(!ProcessProbe.isAlive(process.processIdentifier))
}

@Test func pathsLiveInRealHomeAndFitSocketLimit() {
    #expect(!AgentPaths.home.path.contains("/Library/Containers/"))
    #expect(AgentPaths.socket.path.hasSuffix("/.notch-agents/agents.sock"))
    #expect(AgentPaths.hookScript.lastPathComponent == "notch-agents-hook.sh")
    #expect(AgentPaths.claudeSettings.path.hasSuffix("/.claude/settings.json"))
    #expect(AgentPaths.socket.path.utf8.count < 104)
}
