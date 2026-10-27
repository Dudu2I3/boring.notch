import Testing
@testable import AgentsKit

@Test func describesCommonTools() {
    #expect(ActionSummary.describe(tool: "Bash", input: ["command": "npm test"]) == "Bash: npm test")
    #expect(ActionSummary.describe(tool: "Edit", input: ["file_path": "/a/b/README.md"]) == "Edit README.md")
    #expect(ActionSummary.describe(tool: "Write", input: ["file_path": "/a/report.docx"]) == "Write report.docx")
    #expect(ActionSummary.describe(tool: "Read", input: ["file_path": "/a/x.swift"]) == "Read x.swift")
    #expect(ActionSummary.describe(tool: "NotebookEdit", input: ["notebook_path": "/a/n.ipynb"]) == "NotebookEdit n.ipynb")
    #expect(ActionSummary.describe(tool: "Grep", input: ["pattern": "TODO"]) == "Grep TODO")
    #expect(ActionSummary.describe(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]) == "WebFetch docs.swift.org")
    #expect(ActionSummary.describe(tool: "Agent", input: ["description": "find usages"]) == "Agent: find usages")
    #expect(ActionSummary.describe(tool: "mcp__x__y", input: [:]) == "mcp__x__y")
    #expect(ActionSummary.describe(tool: "Bash", input: [:]) == "Bash")
}

@Test func collapsesWhitespaceAndTruncates() {
    #expect(ActionSummary.describe(tool: "Bash", input: ["command": "echo a\n  && echo   b"]) == "Bash: echo a && echo b")
    let long = ActionSummary.describe(tool: "Bash", input: ["command": String(repeating: "x", count: 100)], limit: 20)
    #expect(long.count == 20)
    #expect(long.hasSuffix("…"))
    #expect(ActionSummary.truncate("short", to: 20) == "short")
}
