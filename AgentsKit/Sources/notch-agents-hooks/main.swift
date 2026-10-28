import AgentsKit
import Foundation

let usage = "usage: notch-agents-hooks install|uninstall|status"

do {
    switch CommandLine.arguments.dropFirst().first {
    case "install":
        try HookInstaller.install(
            settingsURL: AgentPaths.claudeSettings, scriptURL: AgentPaths.hookScript,
            socketPath: AgentPaths.socket.path, now: Date())
        print("Hooks установлены. Они заработают в новых сессиях Claude Code.")
        print("Копия прежних настроек лежит рядом с \(AgentPaths.claudeSettings.path).")
    case "uninstall":
        try HookInstaller.uninstall(
            settingsURL: AgentPaths.claudeSettings, scriptURL: AgentPaths.hookScript, now: Date())
        print("Hooks удалены.")
    case "status":
        print(HookInstaller.isInstalled(settingsURL: AgentPaths.claudeSettings) ? "установлены" : "не установлены")
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
    exit(1)
}
