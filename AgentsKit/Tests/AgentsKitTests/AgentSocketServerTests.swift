import Foundation
import Testing
@testable import AgentsKit

@Test func receivesLinesAndClosesQuickly() throws {
    let path = shortTempSocketPath()
    let inbox = Inbox()
    let server = AgentSocketServer(path: path) { inbox.add($0) }
    try server.start()
    defer { server.stop() }

    let started = Date()
    try sendLine(#"{"a":1}"#, to: path)
    #expect(Date().timeIntervalSince(started) < 0.5)   // server closes, nc does not wait for -w
    try sendLine(#"{"b":2}"#, to: path)

    #expect(waitUntil { inbox.all.count == 2 })
    #expect(inbox.all.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#])
}

@Test func socketIsPrivateAndRemovedOnStop() throws {
    let path = shortTempSocketPath()
    let server = AgentSocketServer(path: path) { _ in }
    try server.start()
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func replacesStaleSocketFile() throws {
    let path = shortTempSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
    let server = AgentSocketServer(path: path) { _ in }
    try server.start()
    server.stop()
}

@Test func rejectsTooLongPath() {
    let server = AgentSocketServer(path: "/tmp/" + String(repeating: "x", count: 120)) { _ in }
    #expect(throws: AgentSocketServer.ServerError.pathTooLong) { try server.start() }
}
