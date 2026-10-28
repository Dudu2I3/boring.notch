import Foundation

/// Where an agent session runs. Decides how "jump to window" works.
public enum AgentSource: String, Sendable, Equatable {
    case iterm, ghostty, terminal, vscode, desktop, other

    public static func detect(termProgram: String?, entrypoint: String?) -> AgentSource {
        if entrypoint == "claude-desktop" { return .desktop }
        switch termProgram {
        case "iTerm.app": return .iterm
        case "ghostty": return .ghostty
        case "Apple_Terminal": return .terminal
        case "vscode": return .vscode
        default: break
        }
        if let entrypoint, entrypoint.contains("vscode") { return .vscode }
        return .other
    }

    public var label: String {
        switch self {
        case .iterm: "iTerm"
        case .ghostty: "Ghostty"
        case .terminal: "Terminal"
        case .vscode: "VS Code"
        case .desktop: "Claude"
        case .other: "?"
        }
    }
}

public struct AgentOrigin: Sendable, Equatable {
    public var source: AgentSource
    public var pid: Int32?
    public var tty: String?
    public var itermSessionID: String?

    public init(source: AgentSource, pid: Int32? = nil, tty: String? = nil, itermSessionID: String? = nil) {
        self.source = source
        self.pid = pid
        self.tty = tty
        self.itermSessionID = itermSessionID
    }

    /// Newer non-empty values win; unknown values never erase known ones.
    public func merged(with newer: AgentOrigin) -> AgentOrigin {
        AgentOrigin(
            source: newer.source == .other ? source : newer.source,
            pid: newer.pid ?? pid,
            tty: newer.tty ?? tty,
            itermSessionID: newer.itermSessionID ?? itermSessionID
        )
    }
}

/// One hook event as sent by notch-agents-hook.sh: {"hook": {...}, "env": {...}}.
public struct AgentEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sessionStart
        case userPromptSubmit
        case preToolUse(tool: String, input: [String: String])
        case postToolUse
        case permissionRequest(tool: String, input: [String: String])
        case permissionNotification(message: String)
        case stop(lastMessage: String?)
        case sessionEnd
        case ignored
    }

    public let sessionID: String
    public let cwd: String
    public let kind: Kind
    public let origin: AgentOrigin

    public init(sessionID: String, cwd: String, kind: Kind, origin: AgentOrigin) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.kind = kind
        self.origin = origin
    }

    public static func parse(_ data: Data) -> AgentEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hook = root["hook"] as? [String: Any],
              let sessionID = nonEmpty(hook["session_id"]),
              let name = hook["hook_event_name"] as? String
        else { return nil }
        let env = root["env"] as? [String: Any] ?? [:]
        let tool = nonEmpty(hook["tool_name"]) ?? "?"
        let input = stringFields(hook["tool_input"])

        let kind: Kind
        switch name {
        case "SessionStart": kind = .sessionStart
        case "UserPromptSubmit": kind = .userPromptSubmit
        case "PreToolUse": kind = .preToolUse(tool: tool, input: input)
        case "PostToolUse", "PostToolUseFailure": kind = .postToolUse
        case "PermissionRequest": kind = .permissionRequest(tool: tool, input: input)
        case "Notification":
            let message = hook["message"] as? String ?? ""
            let type = hook["notification_type"] as? String
            let isPermission = type == "permission_prompt"
                || (type == nil && message.lowercased().contains("permission"))
            kind = isPermission ? .permissionNotification(message: message) : .ignored
        case "Stop": kind = .stop(lastMessage: nonEmpty(hook["last_assistant_message"]))
        case "SessionEnd": kind = .sessionEnd
        default: kind = .ignored
        }

        let tty = nonEmpty(env["tty"]).flatMap { $0 == "??" ? nil : $0 }
        let origin = AgentOrigin(
            source: .detect(termProgram: nonEmpty(env["term_program"]), entrypoint: nonEmpty(env["entrypoint"])),
            pid: (env["pid"] as? NSNumber)?.int32Value,
            tty: tty,
            itermSessionID: nonEmpty(env["iterm_session_id"])
        )
        return AgentEvent(sessionID: sessionID, cwd: hook["cwd"] as? String ?? "", kind: kind, origin: origin)
    }

    private static func stringFields(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
