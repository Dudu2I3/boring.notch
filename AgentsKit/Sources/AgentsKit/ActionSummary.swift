import Foundation

/// Turns a tool call into a short line for the notch: "Bash: npm test", "Edit README.md".
public enum ActionSummary {
    public static func describe(tool: String, input: [String: String], limit: Int = 60) -> String {
        let detail: String?
        var separator = " "
        switch tool {
        case "Bash":
            detail = input["command"]
            separator = ": "
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            detail = (input["file_path"] ?? input["notebook_path"]).map { ($0 as NSString).lastPathComponent }
        case "Grep", "Glob":
            detail = input["pattern"]
        case "WebFetch":
            detail = input["url"].flatMap { URL(string: $0)?.host }
        case "WebSearch":
            detail = input["query"]
        case "Task", "Agent":
            detail = input["description"]
            separator = ": "
        default:
            detail = nil
        }
        let text = detail.map { tool + separator + $0 } ?? tool
        return truncate(collapse(text), to: limit)
    }

    public static func collapse(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func truncate(_ string: String, to limit: Int) -> String {
        string.count <= limit ? string : String(string.prefix(max(0, limit - 1))) + "…"
    }
}
