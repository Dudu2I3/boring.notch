import Foundation
import Testing
@testable import AgentsKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let iterm = AgentOrigin(source: .iterm, pid: 42, tty: "ttys001", itermSessionID: "w0t0p0:A")

private func ev(_ kind: AgentEvent.Kind, _ id: String = "s1", cwd: String = "/Users/me/english-video",
                origin: AgentOrigin = iterm) -> AgentEvent {
    AgentEvent(sessionID: id, cwd: cwd, kind: kind, origin: origin)
}

@Test func freshSessionIsHidden() {
    var store = AgentSessionStore()
    store.apply(ev(.sessionStart), now: t0)
    #expect(store.sessions["s1"]?.status == .idle)
    #expect(store.visible.isEmpty)
}

@Test func runningWithActionThenDone() throws {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit), now: t0)
    store.apply(ev(.preToolUse(tool: "Bash", input: ["command": "npm test"])), now: t0 + 5)
    var s = try #require(store.sessions["s1"])
    #expect(s.status == .running)
    #expect(s.action == "Bash: npm test")
    #expect(s.statusSince == t0)          // still running, timer not reset
    #expect(s.project == "english-video")
    #expect(s.subtitle == "Bash: npm test")

    store.apply(ev(.stop(lastMessage: "Добавил раздел 3\nи таблицу")), now: t0 + 60)
    s = try #require(store.sessions["s1"])
    #expect(s.status == .done)
    #expect(s.statusSince == t0 + 60)
    #expect(s.action == nil)
    #expect(s.lastMessage == "Добавил раздел 3 и таблицу")
    #expect(s.subtitle == "готово: «Добавил раздел 3 и таблицу»")
}

@Test func waitingEmitsBannerOncePerTransition() throws {
    var store = AgentSessionStore()
    store.apply(ev(.preToolUse(tool: "Bash", input: ["command": "rm -rf dist"])), now: t0)
    let first = store.apply(ev(.permissionRequest(tool: "Bash", input: ["command": "rm -rf dist"])), now: t0 + 1)
    #expect(first == [.waitingBanner(project: "english-video")])
    let second = store.apply(ev(.permissionNotification(message: "Claude needs your permission to use Bash")), now: t0 + 2)
    #expect(second.isEmpty)
    let s = try #require(store.sessions["s1"])
    #expect(s.status == .waiting)
    #expect(s.action == "ждёт разрешения: Bash: rm -rf dist")
    #expect(store.hasWaiting)

    store.apply(ev(.postToolUse), now: t0 + 10)
    #expect(store.sessions["s1"]?.status == .running)
    let again = store.apply(ev(.permissionNotification(message: "Claude needs your permission to use WebFetch")), now: t0 + 20)
    #expect(again == [.waitingBanner(project: "english-video")])
    #expect(store.sessions["s1"]?.action == "ждёт разрешения: Claude needs your permission to use Web…")
}

@Test func newPromptClearsDone() throws {
    var store = AgentSessionStore()
    store.apply(ev(.stop(lastMessage: "ok")), now: t0)
    store.apply(ev(.userPromptSubmit), now: t0 + 30)
    let s = try #require(store.sessions["s1"])
    #expect(s.status == .running)
    #expect(s.lastMessage == nil)
    #expect(s.subtitle == "думает…")
}

@Test func sessionEndRemovesAndIgnoredDoesNothing() {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit), now: t0)
    store.apply(ev(.ignored, "s2"), now: t0)
    #expect(store.sessions["s2"] == nil)
    store.apply(ev(.sessionEnd), now: t0 + 1)
    #expect(store.sessions.isEmpty)
}

@Test func visibleOrderWaitingRunningDone() {
    var store = AgentSessionStore()
    store.apply(ev(.stop(lastMessage: nil), "done", cwd: "/d"), now: t0)
    store.apply(ev(.userPromptSubmit, "run-late", cwd: "/r2"), now: t0 + 20)
    store.apply(ev(.userPromptSubmit, "run-early", cwd: "/r1"), now: t0 + 10)
    store.apply(ev(.permissionRequest(tool: "Bash", input: [:]), "wait", cwd: "/w"), now: t0 + 30)
    store.apply(ev(.sessionStart, "idle", cwd: "/i"), now: t0)
    #expect(store.visible.map(\.id) == ["wait", "run-early", "run-late", "done"])
}

@Test func originIsMergedAndCwdUpdated() throws {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit), now: t0)
    store.apply(ev(.postToolUse, cwd: "", origin: AgentOrigin(source: .other)), now: t0 + 1)
    let s = try #require(store.sessions["s1"])
    #expect(s.origin == iterm)
    #expect(s.cwd == "/Users/me/english-video")
}

@Test func projectFallsBackForEmptyCwd() throws {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit, cwd: ""), now: t0)
    #expect(try #require(store.sessions["s1"]).project == "?")
}

@Test func pruneRemovesDeadAndStale() {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit, "alive", origin: AgentOrigin(source: .iterm, pid: 1)), now: t0)
    store.apply(ev(.userPromptSubmit, "dead", origin: AgentOrigin(source: .iterm, pid: 2)), now: t0)
    store.apply(ev(.userPromptSubmit, "stale", origin: AgentOrigin(source: .iterm, pid: 1)), now: t0 - 7 * 3600)
    store.apply(ev(.userPromptSubmit, "nopid", origin: AgentOrigin(source: .other)), now: t0)
    store.prune(now: t0 + 60, isAlive: { $0 == 1 })
    #expect(Set(store.sessions.keys) == ["alive", "nopid"])
}
