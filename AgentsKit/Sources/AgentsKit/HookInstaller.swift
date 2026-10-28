import Foundation

/// Adds and removes our entries in ~/.claude/settings.json without touching anything else.
/// Our entries are recognised by `marker` inside the command string.
public enum HookInstaller {
    public enum InstallerError: Error { case settingsNotAnObject }

    public static let marker = "notch-agents-hook"
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Notification", "PermissionRequest", "Stop", "SessionEnd",
    ]

    public static func command(scriptPath: String) -> String { "\"\(scriptPath)\"" }

    public static func installing(into settings: [String: Any], command: String) -> [String: Any] {
        var result = removing(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": 5]]])
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    public static func removing(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned: [[String: Any]] = groups.compactMap { group in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let kept = entries.filter { !isOurs($0) }
                if kept.isEmpty { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains(where: isOurs)
            }
        }
    }

    public static func install(settingsURL: URL, scriptURL: URL, socketPath: String, now: Date) throws {
        let settings = try readSettings(settingsURL)   // fail before touching anything
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try HookScript.body(socketPath: socketPath).write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try writeSettings(installing(into: settings, command: command(scriptPath: scriptURL.path)),
                          to: settingsURL, now: now)
    }

    public static func uninstall(settingsURL: URL, scriptURL: URL, now: Date) throws {
        let settings = try readSettings(settingsURL)
        try writeSettings(removing(from: settings), to: settingsURL, now: now)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    public static func isInstalled(settingsURL: URL) -> Bool {
        (try? readSettings(settingsURL)).map(isInstalled(in:)) ?? false
    }

    public static func backupURL(for url: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".notch-agents-backup-" + formatter.string(from: now))
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) ?? false
    }

    static func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.settingsNotAnObject
        }
        return object
    }

    static func writeSettings(_ settings: [String: Any], to url: URL, now: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.copyItem(at: url, to: backupURL(for: url, now: now))
        }
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
