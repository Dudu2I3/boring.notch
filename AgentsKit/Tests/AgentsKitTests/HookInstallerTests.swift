import Foundation
import Testing
@testable import AgentsKit

private let ours = HookInstaller.command(scriptPath: "/Users/me/.notch-agents/notch-agents-hook.sh")
private let userStopGroup: [String: Any] = ["hooks": [["type": "command", "command": "terminal-notifier -message done"]]]

private func groups(_ settings: [String: Any], _ event: String) -> [[String: Any]] {
    (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
}
private func commands(_ settings: [String: Any], _ event: String) -> [String] {
    groups(settings, event).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Test func installAddsAllEvents() {
    let result = HookInstaller.installing(into: [:], command: ours)
    for event in HookInstaller.events {
        #expect(commands(result, event) == [ours])
    }
    #expect(HookInstaller.events.count == 8)
    #expect(HookInstaller.isInstalled(in: result))
    #expect(ours.contains(HookInstaller.marker))
}

@Test func installKeepsUserHooksAndIsIdempotent() {
    let settings: [String: Any] = ["model": "opus", "hooks": ["Stop": [userStopGroup]]]
    let once = HookInstaller.installing(into: settings, command: ours)
    let twice = HookInstaller.installing(into: once, command: ours)
    #expect(commands(twice, "Stop") == ["terminal-notifier -message done", ours])
    #expect(twice["model"] as? String == "opus")
}

@Test func uninstallRemovesOnlyOurs() {
    let installed = HookInstaller.installing(into: ["model": "opus", "hooks": ["Stop": [userStopGroup]]], command: ours)
    let removed = HookInstaller.removing(from: installed)
    #expect(commands(removed, "Stop") == ["terminal-notifier -message done"])
    #expect(groups(removed, "PreToolUse").isEmpty)
    #expect(!HookInstaller.isInstalled(in: removed))
    #expect(removed["model"] as? String == "opus")

    let clean = HookInstaller.removing(from: HookInstaller.installing(into: [:], command: ours))
    #expect(clean["hooks"] == nil)
}

@Test func fileInstallBacksUpAndWritesScript() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("na-\(UUID().uuidString)")
    let settingsURL = dir.appendingPathComponent(".claude/settings.json")
    let scriptURL = dir.appendingPathComponent(".notch-agents/notch-agents-hook.sh")
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data(#"{"model":"opus"}"#.utf8)
    try original.write(to: settingsURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    try HookInstaller.install(settingsURL: settingsURL, scriptURL: scriptURL, socketPath: "/x.sock", now: now)

    #expect(try Data(contentsOf: HookInstaller.backupURL(for: settingsURL, now: now)) == original)
    #expect(HookInstaller.isInstalled(settingsURL: settingsURL))
    let perms = try FileManager.default.attributesOfItem(atPath: scriptURL.path)[.posixPermissions] as? NSNumber
    #expect(perms?.intValue == 0o755)
    #expect(try String(contentsOf: scriptURL, encoding: .utf8).contains("/x.sock"))

    try HookInstaller.uninstall(settingsURL: settingsURL, scriptURL: scriptURL, now: now + 1)
    #expect(!HookInstaller.isInstalled(settingsURL: settingsURL))
    #expect(!FileManager.default.fileExists(atPath: scriptURL.path))
}

@Test func refusesToOverwriteBrokenSettings() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("na-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let settingsURL = dir.appendingPathComponent("settings.json")
    try Data("{ broken".utf8).write(to: settingsURL)
    #expect(throws: (any Error).self) {
        try HookInstaller.install(settingsURL: settingsURL, scriptURL: dir.appendingPathComponent("h.sh"),
                                  socketPath: "/x.sock", now: Date())
    }
    #expect(try String(contentsOf: settingsURL, encoding: .utf8) == "{ broken")
}

@Test func backupNameIsStable() {
    let url = URL(fileURLWithPath: "/u/.claude/settings.json")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 21, minute: 5, second: 9))!
    #expect(HookInstaller.backupURL(for: url, now: date).lastPathComponent
        == "settings.json.notch-agents-backup-20261027-210509")
}
