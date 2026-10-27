import Foundation

public enum AgentPaths {
    /// The user's real home. Inside the App Sandbox NSHomeDirectory() points into the container,
    /// but the hook script runs outside it, so both sides must agree on the real path.
    public static var home: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var supportDirectory: URL { home.appendingPathComponent(".notch-agents", isDirectory: true) }
    public static var socket: URL { supportDirectory.appendingPathComponent("agents.sock") }
    public static var hookScript: URL { supportDirectory.appendingPathComponent("notch-agents-hook.sh") }
    public static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }

    public static func ensureSupportDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }
}
