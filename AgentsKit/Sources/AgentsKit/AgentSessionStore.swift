import Foundation

/// Raw value is the display order: waiting first, then running, then done. Idle is never shown.
public enum AgentStatus: Int, Sendable, Comparable {
    case waiting = 0, running, done, idle

    public static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    public let id: String
    public var cwd: String
    public var origin: AgentOrigin
    public var status: AgentStatus
    public var statusSince: Date
    public var lastEventAt: Date
    public var action: String?
    public var lastMessage: String?

    public var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "?" : name
    }

    /// Second column of the agents tab.
    public var subtitle: String {
        switch status {
        case .done: lastMessage.map { "готово: «\($0)»" } ?? "готово"
        case .waiting, .running, .idle: action ?? "думает…"
        }
    }
}

public enum AgentEffect: Sendable, Equatable {
    case waitingBanner(project: String)
}

/// Pure state machine over hook events. No timers, no I/O: the app feeds it events and the clock.
public struct AgentSessionStore: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]

    public init() {}

    @discardableResult
    public mutating func apply(_ event: AgentEvent, now: Date) -> [AgentEffect] {
        switch event.kind {
        case .sessionEnd:
            sessions[event.sessionID] = nil
            return []
        case .ignored:
            return []
        default:
            break
        }

        var session = sessions[event.sessionID] ?? AgentSession(
            id: event.sessionID, cwd: event.cwd, origin: event.origin,
            status: .idle, statusSince: now, lastEventAt: now)
        if !event.cwd.isEmpty { session.cwd = event.cwd }
        session.origin = session.origin.merged(with: event.origin)
        session.lastEventAt = now

        var effects: [AgentEffect] = []
        switch event.kind {
        case .sessionStart:
            break
        case .userPromptSubmit:
            Self.set(&session, .running, now)
            session.action = nil
            session.lastMessage = nil
        case let .preToolUse(tool, input):
            Self.set(&session, .running, now)
            session.action = ActionSummary.describe(tool: tool, input: input)
        case .postToolUse:
            Self.set(&session, .running, now)
        case let .permissionRequest(tool, input):
            if session.status != .waiting { effects.append(.waitingBanner(project: session.project)) }
            Self.set(&session, .waiting, now)
            session.action = "ждёт разрешения: " + ActionSummary.describe(tool: tool, input: input, limit: 40)
        case let .permissionNotification(message):
            if session.status != .waiting {
                effects.append(.waitingBanner(project: session.project))
                session.action = "ждёт разрешения: "
                    + ActionSummary.truncate(ActionSummary.collapse(message), to: 40)
            }
            Self.set(&session, .waiting, now)
        case let .stop(lastMessage):
            Self.set(&session, .done, now)
            session.action = nil
            session.lastMessage = lastMessage.map { ActionSummary.truncate(ActionSummary.collapse($0), to: 80) }
        case .sessionEnd, .ignored:
            break
        }
        sessions[session.id] = session
        return effects
    }

    /// Drops sessions whose agent process is gone, and sessions silent for longer than `maxIdle`.
    public mutating func prune(now: Date, maxIdle: TimeInterval = 6 * 3600, isAlive: (Int32) -> Bool) {
        sessions = sessions.filter { _, session in
            if let pid = session.origin.pid, !isAlive(pid) { return false }
            return now.timeIntervalSince(session.lastEventAt) < maxIdle
        }
    }

    public var visible: [AgentSession] {
        sessions.values
            .filter { $0.status != .idle }
            .sorted { ($0.status, $0.statusSince, $0.id) < ($1.status, $1.statusSince, $1.id) }
    }

    public var hasWaiting: Bool { sessions.values.contains { $0.status == .waiting } }

    private static func set(_ session: inout AgentSession, _ status: AgentStatus, _ now: Date) {
        guard session.status != status else { return }
        session.status = status
        session.statusSince = now
    }
}
