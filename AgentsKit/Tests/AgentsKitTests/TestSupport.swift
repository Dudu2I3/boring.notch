import Foundation

final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []

    func add(_ data: Data) { lock.lock(); items.append(data); lock.unlock() }
    var all: [Data] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Polls `condition` until it is true or `timeout` passes.
func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

/// Sends one line the same way the hook does: through /usr/bin/nc.
func sendLine(_ line: String, to path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
    process.arguments = ["-U", "-w", "1", path]
    let pipe = Pipe()
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    pipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    try pipe.fileHandleForWriting.close()
    process.waitUntilExit()
}

/// Unix socket paths must stay under 104 bytes; the default temp dir is too deep.
func shortTempSocketPath() -> String {
    "/tmp/na-\(UUID().uuidString.prefix(8)).sock"
}
