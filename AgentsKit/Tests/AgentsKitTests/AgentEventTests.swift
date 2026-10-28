import Foundation
import Testing
@testable import AgentsKit

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func parsesPreToolUseWithOrigin() throws {
    let data = line("""
    {"hook":{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/Users/me/english-video",
    "tool_name":"Bash","tool_input":{"command":"npm test","timeout":5}},
    "env":{"term_program":"iTerm.app","iterm_session_id":"w0t1p0:ABC-123","entrypoint":"cli","tty":"ttys003","pid":4242}}
    """)
    let event = try #require(AgentEvent.parse(data))
    #expect(event.sessionID == "s1")
    #expect(event.cwd == "/Users/me/english-video")
    #expect(event.kind == .preToolUse(tool: "Bash", input: ["command": "npm test"]))
    #expect(event.origin == AgentOrigin(source: .iterm, pid: 4242, tty: "ttys003", itermSessionID: "w0t1p0:ABC-123"))
}

@Test func mapsEveryHookName() throws {
    func kind(_ name: String, _ extra: String = "") -> AgentEvent.Kind? {
        AgentEvent.parse(line(#"{"hook":{"session_id":"s","hook_event_name":"\#(name)","cwd":"/x"\#(extra)},"env":{}}"#))?.kind
    }
    #expect(kind("SessionStart") == .sessionStart)
    #expect(kind("UserPromptSubmit") == .userPromptSubmit)
    #expect(kind("PostToolUse") == .postToolUse)
    #expect(kind("PostToolUseFailure") == .postToolUse)
    #expect(kind("PermissionRequest", #","tool_name":"Bash","tool_input":{"command":"rm -rf dist"}"#)
        == .permissionRequest(tool: "Bash", input: ["command": "rm -rf dist"]))
    #expect(kind("Notification", #","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)
        == .permissionNotification(message: "Claude needs your permission to use Bash"))
    #expect(kind("Notification", #","notification_type":"idle_prompt","message":"Claude is waiting for your input""#) == .ignored)
    #expect(kind("Notification", #","message":"Claude needs your permission to use Edit""#)
        == .permissionNotification(message: "Claude needs your permission to use Edit"))
    #expect(kind("Stop", #","last_assistant_message":"Готово""#) == .stop(lastMessage: "Готово"))
    #expect(kind("Stop") == .stop(lastMessage: nil))
    #expect(kind("SessionEnd") == .sessionEnd)
    #expect(kind("SubagentStop") == .ignored)
}

@Test func rejectsGarbage() {
    #expect(AgentEvent.parse(line("not json")) == nil)
    #expect(AgentEvent.parse(line(#"{"hook":{"hook_event_name":"Stop"},"env":{}}"#)) == nil)
    #expect(AgentEvent.parse(line(#"{"hook":{"session_id":"","hook_event_name":"Stop"},"env":{}}"#)) == nil)
    #expect(AgentEvent.parse(line(#"{"env":{}}"#)) == nil)
}

@Test func treatsMissingTtyMarkersAsNil() throws {
    let event = try #require(AgentEvent.parse(line(#"{"hook":{"session_id":"s","hook_event_name":"Stop","cwd":"/x"},"env":{"tty":"??","term_program":""}}"#)))
    #expect(event.origin.tty == nil)
    #expect(event.origin.source == .other)
}

@Test func detectsSource() {
    #expect(AgentSource.detect(termProgram: nil, entrypoint: "claude-desktop") == .desktop)
    #expect(AgentSource.detect(termProgram: "iTerm.app", entrypoint: "cli") == .iterm)
    #expect(AgentSource.detect(termProgram: "ghostty", entrypoint: "cli") == .ghostty)
    #expect(AgentSource.detect(termProgram: "Apple_Terminal", entrypoint: "cli") == .terminal)
    #expect(AgentSource.detect(termProgram: "vscode", entrypoint: "cli") == .vscode)
    #expect(AgentSource.detect(termProgram: nil, entrypoint: "claude-vscode") == .vscode)
    #expect(AgentSource.detect(termProgram: "WarpTerminal", entrypoint: "cli") == .other)
}

@Test func mergeKeepsKnownFields() {
    let old = AgentOrigin(source: .iterm, pid: 10, tty: "ttys001", itermSessionID: "w0t0p0:A")
    let newer = AgentOrigin(source: .other, pid: nil, tty: nil, itermSessionID: nil)
    #expect(old.merged(with: newer) == old)
    let moved = AgentOrigin(source: .iterm, pid: 11, tty: "ttys002", itermSessionID: "w0t0p0:B")
    #expect(old.merged(with: moved) == moved)
}
