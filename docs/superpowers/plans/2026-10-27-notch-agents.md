# Notch Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Форк Boring Notch, который в челке показывает статус агентов Claude Code (работает / ждёт / закончил) рядом с музыкой и по клику переводит в окно агента.

**Architecture:** Вся логика без UI живёт в локальном Swift-пакете `AgentsKit` в корне репозитория: разбор событий, хранилище сессий, сервер Unix-сокета, hook-скрипт, установщик hooks и консольная команда `notch-agents-hooks`. Пакет тестируется командой `swift test` без Xcode-проекта. Приложение подключает пакет и добавляет тонкий слой `boringNotch/Features/Agents/` (сервис, виды, переход в окна) плюс несколько точечных правок upstream-файлов.

**Tech Stack:** Swift 6 toolchain (language mode 5), SwiftUI, AppKit, Swift Testing, POSIX-сокеты, bash + `/usr/bin/nc`, Xcode 16+.

**Spec:** `docs/superpowers/specs/2026-10-27-notch-agents-design.md`

## Global Constraints

- Целевая машина: MacBook Air M2, macOS 15.8.1. `MACOSX_DEPLOYMENT_TARGET` upstream = 14.0, пакет `AgentsKit` тоже `.macOS(.v14)`.
- Основа: Boring Notch, коммит `23e7705a4ffcb5d97a54fb1d4135e180084a566d` (2026-10-18).
- Bundle ID приложения: `dev.daniyar.boringnotch`, XPC-хелпера: `dev.daniyar.boringnotch.BoringNotchXPCHelper`.
- Приложение остаётся в песочнице. Никаких сетевых запросов, чтения Связки ключей и транскриптов в коде агентов.
- Папка модуля: `~/.notch-agents/` (права `0700`); сокет `~/.notch-agents/agents.sock` (права `0600`); hook-скрипт `~/.notch-agents/notch-agents-hook.sh` (права `0755`).
- Маркер наших записей в `~/.claude/settings.json`: `notch-agents-hook`. Перед каждой записью в `settings.json` — копия `settings.json.notch-agents-backup-yyyyMMdd-HHmmss`.
- Hook никогда ничего не печатает в stdout, всегда выходит с кодом 0, ждёт сокет не дольше 1 секунды (`nc -U -w 1`).
- События hooks: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `PermissionRequest`, `Stop`, `SessionEnd`.
- Цвета статусов: работает — синий, ждёт — жёлтый, закончил — зелёный. Плашка ожидания — 5 секунд. Точек в свёрнутой челке не больше 4, дальше `+N`.
- Тексты интерфейса на русском.
- Весь свой код приложения — в `boringNotch/Features/Agents/`. Правки upstream-файлов — только перечисленные в задачах.

## File Structure

```
<repo>/
├── AgentsKit/                              # новый локальный пакет
│   ├── Package.swift
│   ├── Sources/AgentsKit/
│   │   ├── AgentEvent.swift                # разбор строки из сокета → AgentEvent, AgentSource, AgentOrigin
│   │   ├── ActionSummary.swift             # «Bash: npm test», «Edit README.md», обрезка текста
│   │   ├── AgentSessionStore.swift         # AgentStatus, AgentSession, AgentEffect, хранилище и переходы
│   │   ├── AgentFormat.swift               # «2 мин», «1 ч»
│   │   ├── ProcessProbe.swift              # жив ли процесс (sysctl)
│   │   ├── AgentPaths.swift                # реальная домашняя папка, пути модуля
│   │   ├── AgentSocketServer.swift         # слушает Unix-сокет, отдаёт строки
│   │   ├── HookScript.swift                # текст bash-hook
│   │   └── HookInstaller.swift             # правка ~/.claude/settings.json
│   ├── Sources/notch-agents-hooks/main.swift   # CLI: install | uninstall | status
│   └── Tests/AgentsKitTests/
│       ├── TestSupport.swift
│       ├── AgentEventTests.swift
│       ├── ActionSummaryTests.swift
│       ├── AgentSessionStoreTests.swift
│       ├── AgentFormatTests.swift
│       ├── ProcessProbeTests.swift
│       ├── AgentSocketServerTests.swift
│       ├── HookScriptTests.swift
│       └── HookInstallerTests.swift
├── scripts/agents/fake-events.sh           # демо-сценарий для ручной проверки
└── boringNotch/
    ├── Features/Agents/                    # новый код приложения
    │   ├── AgentsService.swift
    │   ├── AgentStatus+Color.swift
    │   ├── AgentsTabView.swift
    │   ├── AgentClosedWing.swift
    │   └── AgentWindowJumper.swift
    ├── enums/generic.swift                 # + case agents
    ├── ContentView.swift                   # вкладка, крыло, ширина, автопереход
    ├── components/Tabs/TabSelectionView.swift  # + вкладка, жёлтая точка
    ├── components/Notch/BoringHeader.swift # вкладки видны, если есть агенты
    ├── boringNotchApp.swift                # старт сервиса, выкл. автообновления
    ├── boringNotch.entitlements            # папка ~/.notch-agents, Apple Events для iTerm/Terminal
    └── Info.plist                          # SUEnableAutomaticChecks = NO
```

Xcode-проект использует синхронизируемые папки (`PBXFileSystemSynchronizedRootGroup`): новые файлы внутри `boringNotch/` попадают в цель автоматически, править `project.pbxproj` для них не нужно.

---

### Task 0: Окружение, форк и сборка без изменений

Ручная задача: её делает человек, агент только подсказывает и проверяет.

**Files:**
- Modify: `boringNotch.xcodeproj/project.pbxproj` (bundle ID)
- Modify: `boringNotch/XPCHelperClient/XPCHelperClient.swift:8`
- Modify: `BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift:28`
- Modify: `boringNotch/boringNotchApp.swift:24-25`
- Modify: `boringNotch/Info.plist`
- Create: `docs/superpowers/specs/2026-10-27-notch-agents-design.md`, `docs/superpowers/plans/2026-10-27-notch-agents.md` (копии)

**Interfaces:**
- Consumes: —
- Produces: собираемое приложение `boringNotch.app` с bundle ID `dev.daniyar.boringnotch`, подписанное Personal Team, без автообновления.

- [ ] **Step 1: Установить Xcode**

Сейчас на маке только Command Line Tools (`xcodebuild` не работает). Установить Xcode из App Store (~15 ГБ), один раз открыть его и согласиться с лицензией, затем в терминале (нужен пароль, делает человек):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Проверка:

```bash
xcodebuild -version
```

Expected: `Xcode 16.x` или новее.

- [ ] **Step 2: Форк и клон**

На GitHub нажать Fork у `TheBoredTeam/boring.notch`. Затем:

```bash
mkdir -p ~/code && cd ~/code
git clone https://github.com/<твой-логин>/boring.notch boring-notch-agents
cd boring-notch-agents
git remote add upstream https://github.com/TheBoredTeam/boring.notch
git checkout -b agents 23e7705a4ffcb5d97a54fb1d4135e180084a566d
```

Expected: `Switched to a new branch 'agents'`.

- [ ] **Step 3: Скопировать спецификацию и план в репозиторий**

Скопировать оба файла в `docs/superpowers/specs/` и `docs/superpowers/plans/` репозитория.

- [ ] **Step 4: Сменить bundle ID**

Чужой bundle ID нельзя подписать своим Apple ID. Меняем только в проекте и двух Swift-файлах, где хардкодится имя XPC-сервиса:

```bash
sed -i '' 's/theboringteam\.boringnotch/dev.daniyar.boringnotch/g' \
  boringNotch.xcodeproj/project.pbxproj \
  boringNotch/XPCHelperClient/XPCHelperClient.swift \
  BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift
grep -rn 'theboringteam\.boringnotch' boringNotch.xcodeproj boringNotch BoringNotchXPCHelper
```

Expected: последний `grep` ничего не находит. (`theboringteam.boringNotch` с заглавной N в `TipStore.swift` — это иконка оригинала, её не трогаем.)

- [ ] **Step 5: Выключить автообновление**

В `boringNotch/boringNotchApp.swift` заменить:

```swift
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
```

на:

```swift
        // Fork: updates come from upstream merges, never from the original appcast.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
```

В `boringNotch/Info.plist` сразу после строки `<string>https://TheBoredTeam.github.io/boring.notch/appcast.xml</string>` добавить:

```xml
	<key>SUEnableAutomaticChecks</key>
	<false/>
```

- [ ] **Step 6: Подписка Personal Team**

Открыть `boringNotch.xcodeproj` в Xcode. Xcode → Settings → Accounts → добавить свой Apple ID. Для целей `boringNotch` и `BoringNotchXPCHelper`: вкладка Signing & Capabilities → Team = «<Имя> (Personal Team)», «Automatically manage signing» включено. Ошибок подписи быть не должно.

- [ ] **Step 7: Собрать и запустить**

```bash
xcodebuild -list -project boringNotch.xcodeproj
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build | tail -3
```

Expected: в списке схема `boringNotch`; сборка заканчивается `** BUILD SUCCEEDED **`.

Выйти из NotchNook (меню в строке меню → Quit), затем:

```bash
open build/Build/Products/Debug/boringNotch.app
```

Expected: в челке появляется Boring Notch, онбординг проходит. Включить Spotify: в свёрнутой челке обложка слева и визуализатор справа. Перетащить файл в челку: он появляется на полке и вытаскивается обратно.

- [ ] **Step 8: Тест-драйв (точка остановки)**

Пользоваться 2–3 дня вместо NotchNook. Если музыка или полка не устраивают — остановиться и вернуться к выбору основы. Дальше не идти.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "chore: own bundle ID, disable Sparkle updates, add spec and plan"
```

---

### Task 1: Пакет AgentsKit и разбор событий

**Files:**
- Create: `AgentsKit/Package.swift`
- Create: `AgentsKit/Sources/AgentsKit/AgentEvent.swift`
- Create: `AgentsKit/Sources/notch-agents-hooks/main.swift` (заглушка, полная версия в Task 6)
- Test: `AgentsKit/Tests/AgentsKitTests/AgentEventTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `public enum AgentSource: String { case iterm, ghostty, terminal, vscode, desktop, other }`, `static func detect(termProgram: String?, entrypoint: String?) -> AgentSource`, `var label: String`
  - `public struct AgentOrigin { var source: AgentSource; var pid: Int32?; var tty: String?; var itermSessionID: String?; func merged(with newer: AgentOrigin) -> AgentOrigin }`
  - `public struct AgentEvent { let sessionID: String; let cwd: String; let kind: Kind; let origin: AgentOrigin; static func parse(_ data: Data) -> AgentEvent? }`
  - `AgentEvent.Kind`: `.sessionStart`, `.userPromptSubmit`, `.preToolUse(tool: String, input: [String: String])`, `.postToolUse`, `.permissionRequest(tool: String, input: [String: String])`, `.permissionNotification(message: String)`, `.stop(lastMessage: String?)`, `.sessionEnd`, `.ignored`
  - Формат строки из сокета: `{"hook": <JSON от Claude Code>, "env": {"term_program": "...", "iterm_session_id": "...", "entrypoint": "...", "tty": "...", "pid": 123}}`

- [ ] **Step 1: Создать Package.swift**

`AgentsKit/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentsKit", targets: ["AgentsKit"]),
        .executable(name: "notch-agents-hooks", targets: ["notch-agents-hooks"]),
    ],
    targets: [
        .target(name: "AgentsKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "notch-agents-hooks",
            dependencies: ["AgentsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentsKitTests",
            dependencies: ["AgentsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

`AgentsKit/Sources/notch-agents-hooks/main.swift` (временная заглушка, чтобы пакет собирался):

```swift
print("usage: notch-agents-hooks install|uninstall|status")
```

- [ ] **Step 2: Написать падающие тесты**

`AgentsKit/Tests/AgentsKitTests/AgentEventTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentsKit

private func line(_ json: String) -> Data { Data(json.utf8) }

@Test func parsesPreToolUseWithOrigin() throws {
    let data = line("""
    {"hook":{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/Users/me/english-video",
    "tool_name":"Bash","tool_input":{"command":"npm test","timeout":5}},
    "env":{"term_program":"iTerm.app","iterm_session_id":"w0t1p0:ABC-123","entrypoint":"cli","tty":"ttys003","pid":4242}}
    """)
    let event = try #require(AgentEvent.parse(data))
    #expect(event.sessionID == "s1")
    #expect(event.cwd == "/Users/me/english-video")
    #expect(event.kind == .preToolUse(tool: "Bash", input: ["command": "npm test"]))
    #expect(event.origin == AgentOrigin(source: .iterm, pid: 4242, tty: "ttys003", itermSessionID: "w0t1p0:ABC-123"))
}

@Test func mapsEveryHookName() throws {
    func kind(_ name: String, _ extra: String = "") -> AgentEvent.Kind? {
        AgentEvent.parse(line(#"{"hook":{"session_id":"s","hook_event_name":"\#(name)","cwd":"/x"\#(extra)},"env":{}}"#))?.kind
    }
    #expect(kind("SessionStart") == .sessionStart)
    #expect(kind("UserPromptSubmit") == .userPromptSubmit)
    #expect(kind("PostToolUse") == .postToolUse)
    #expect(kind("PostToolUseFailure") == .postToolUse)
    #expect(kind("PermissionRequest", #","tool_name":"Bash","tool_input":{"command":"rm -rf dist"}"#)
        == .permissionRequest(tool: "Bash", input: ["command": "rm -rf dist"]))
    #expect(kind("Notification", #","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)
        == .permissionNotification(message: "Claude needs your permission to use Bash"))
    #expect(kind("Notification", #","notification_type":"idle_prompt","message":"Claude is waiting for your input""#) == .ignored)
    #expect(kind("Notification", #","message":"Claude needs your permission to use Edit""#)
        == .permissionNotification(message: "Claude needs your permission to use Edit"))
    #expect(kind("Stop", #","last_assistant_message":"Готово""#) == .stop(lastMessage: "Готово"))
    #expect(kind("Stop") == .stop(lastMessage: nil))
    #expect(kind("SessionEnd") == .sessionEnd)
    #expect(kind("SubagentStop") == .ignored)
}

@Test func rejectsGarbage() {
    #expect(AgentEvent.parse(line("not json")) == nil)
    #expect(AgentEvent.parse(line(#"{"hook":{"hook_event_name":"Stop"},"env":{}}"#)) == nil)
    #expect(AgentEvent.parse(line(#"{"hook":{"session_id":"","hook_event_name":"Stop"},"env":{}}"#)) == nil)
    #expect(AgentEvent.parse(line(#"{"env":{}}"#)) == nil)
}

@Test func treatsMissingTtyMarkersAsNil() throws {
    let event = try #require(AgentEvent.parse(line(#"{"hook":{"session_id":"s","hook_event_name":"Stop","cwd":"/x"},"env":{"tty":"??","term_program":""}}"#)))
    #expect(event.origin.tty == nil)
    #expect(event.origin.source == .other)
}

@Test func detectsSource() {
    #expect(AgentSource.detect(termProgram: nil, entrypoint: "claude-desktop") == .desktop)
    #expect(AgentSource.detect(termProgram: "iTerm.app", entrypoint: "cli") == .iterm)
    #expect(AgentSource.detect(termProgram: "ghostty", entrypoint: "cli") == .ghostty)
    #expect(AgentSource.detect(termProgram: "Apple_Terminal", entrypoint: "cli") == .terminal)
    #expect(AgentSource.detect(termProgram: "vscode", entrypoint: "cli") == .vscode)
    #expect(AgentSource.detect(termProgram: nil, entrypoint: "claude-vscode") == .vscode)
    #expect(AgentSource.detect(termProgram: "WarpTerminal", entrypoint: "cli") == .other)
}

@Test func mergeKeepsKnownFields() {
    let old = AgentOrigin(source: .iterm, pid: 10, tty: "ttys001", itermSessionID: "w0t0p0:A")
    let newer = AgentOrigin(source: .other, pid: nil, tty: nil, itermSessionID: nil)
    #expect(old.merged(with: newer) == old)
    let moved = AgentOrigin(source: .iterm, pid: 11, tty: "ttys002", itermSessionID: "w0t0p0:B")
    #expect(old.merged(with: moved) == moved)
}
```

- [ ] **Step 3: Запустить тесты и убедиться, что они падают**

Run: `cd AgentsKit && swift test --filter AgentEventTests`
Expected: FAIL при компиляции: `cannot find 'AgentEvent' in scope`.

- [ ] **Step 4: Реализация**

`AgentsKit/Sources/AgentsKit/AgentEvent.swift`:

```swift
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
```

- [ ] **Step 5: Запустить тесты**

Run: `cd AgentsKit && swift test --filter AgentEventTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add AgentsKit
git commit -m "feat(agents): AgentsKit package with hook event parsing"
```

---

### Task 2: Короткое описание действия и форматирование времени

**Files:**
- Create: `AgentsKit/Sources/AgentsKit/ActionSummary.swift`
- Create: `AgentsKit/Sources/AgentsKit/AgentFormat.swift`
- Test: `AgentsKit/Tests/AgentsKitTests/ActionSummaryTests.swift`
- Test: `AgentsKit/Tests/AgentsKitTests/AgentFormatTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `public enum ActionSummary { static func describe(tool: String, input: [String: String], limit: Int = 60) -> String; static func collapse(_ s: String) -> String; static func truncate(_ s: String, to limit: Int) -> String }`
  - `public enum AgentFormat { static func elapsed(_ seconds: TimeInterval) -> String }`

- [ ] **Step 1: Написать падающие тесты**

`AgentsKit/Tests/AgentsKitTests/ActionSummaryTests.swift`:

```swift
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
```

`AgentsKit/Tests/AgentsKitTests/AgentFormatTests.swift`:

```swift
import Testing
@testable import AgentsKit

@Test func formatsElapsed() {
    #expect(AgentFormat.elapsed(5) == "<1 мин")
    #expect(AgentFormat.elapsed(60) == "1 мин")
    #expect(AgentFormat.elapsed(59 * 60 + 59) == "59 мин")
    #expect(AgentFormat.elapsed(60 * 60) == "1 ч")
    #expect(AgentFormat.elapsed(5 * 60 * 60 + 10) == "5 ч")
    #expect(AgentFormat.elapsed(-3) == "<1 мин")
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `cd AgentsKit && swift test --filter "ActionSummaryTests|AgentFormatTests"`
Expected: FAIL: `cannot find 'ActionSummary' in scope`.

- [ ] **Step 3: Реализация**

`AgentsKit/Sources/AgentsKit/ActionSummary.swift`:

```swift
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
```

`AgentsKit/Sources/AgentsKit/AgentFormat.swift`:

```swift
import Foundation

public enum AgentFormat {
    /// "<1 мин", "14 мин", "2 ч".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "<1 мин" }
        if minutes < 60 { return "\(minutes) мин" }
        return "\(minutes / 60) ч"
    }
}
```

- [ ] **Step 4: Запустить тесты**

Run: `cd AgentsKit && swift test --filter "ActionSummaryTests|AgentFormatTests"`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add AgentsKit
git commit -m "feat(agents): action summaries and elapsed time formatting"
```

---

### Task 3: Хранилище сессий и переходы статусов

**Files:**
- Create: `AgentsKit/Sources/AgentsKit/AgentSessionStore.swift`
- Test: `AgentsKit/Tests/AgentsKitTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Consumes: `AgentEvent`, `AgentOrigin`, `ActionSummary` (Tasks 1–2)
- Produces:
  - `public enum AgentStatus: Int, Comparable { case waiting = 0, running, done, idle }`
  - `public struct AgentSession: Identifiable { let id: String; var cwd: String; var origin: AgentOrigin; var status: AgentStatus; var statusSince: Date; var lastEventAt: Date; var action: String?; var lastMessage: String?; var project: String; var subtitle: String }`
  - `public enum AgentEffect: Equatable { case waitingBanner(project: String) }`
  - `public struct AgentSessionStore { var sessions: [String: AgentSession]; mutating func apply(_ event: AgentEvent, now: Date) -> [AgentEffect]; mutating func prune(now: Date, maxIdle: TimeInterval = 21600, isAlive: (Int32) -> Bool); var visible: [AgentSession]; var hasWaiting: Bool }`

- [ ] **Step 1: Написать падающие тесты**

`AgentsKit/Tests/AgentsKitTests/AgentSessionStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentsKit

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private let iterm = AgentOrigin(source: .iterm, pid: 42, tty: "ttys001", itermSessionID: "w0t0p0:A")

private func ev(_ kind: AgentEvent.Kind, _ id: String = "s1", cwd: String = "/Users/me/english-video",
                origin: AgentOrigin = iterm) -> AgentEvent {
    AgentEvent(sessionID: id, cwd: cwd, kind: kind, origin: origin)
}

@Test func freshSessionIsHidden() {
    var store = AgentSessionStore()
    store.apply(ev(.sessionStart), now: t0)
    #expect(store.sessions["s1"]?.status == .idle)
    #expect(store.visible.isEmpty)
}

@Test func runningWithActionThenDone() throws {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit), now: t0)
    store.apply(ev(.preToolUse(tool: "Bash", input: ["command": "npm test"])), now: t0 + 5)
    var s = try #require(store.sessions["s1"])
    #expect(s.status == .running)
    #expect(s.action == "Bash: npm test")
    #expect(s.statusSince == t0)          // still running, timer not reset
    #expect(s.project == "english-video")
    #expect(s.subtitle == "Bash: npm test")

    store.apply(ev(.stop(lastMessage: "Добавил раздел 3\nи таблицу")), now: t0 + 60)
    s = try #require(store.sessions["s1"])
    #expect(s.status == .done)
    #expect(s.statusSince == t0 + 60)
    #expect(s.action == nil)
    #expect(s.lastMessage == "Добавил раздел 3 и таблицу")
    #expect(s.subtitle == "готово: «Добавил раздел 3 и таблицу»")
}

@Test func waitingEmitsBannerOncePerTransition() throws {
    var store = AgentSessionStore()
    store.apply(ev(.preToolUse(tool: "Bash", input: ["command": "rm -rf dist"])), now: t0)
    let first = store.apply(ev(.permissionRequest(tool: "Bash", input: ["command": "rm -rf dist"])), now: t0 + 1)
    #expect(first == [.waitingBanner(project: "english-video")])
    let second = store.apply(ev(.permissionNotification(message: "Claude needs your permission to use Bash")), now: t0 + 2)
    #expect(second.isEmpty)
    let s = try #require(store.sessions["s1"])
    #expect(s.status == .waiting)
    #expect(s.action == "ждёт разрешения: Bash: rm -rf dist")
    #expect(store.hasWaiting)

    store.apply(ev(.postToolUse), now: t0 + 10)
    #expect(store.sessions["s1"]?.status == .running)
    let again = store.apply(ev(.permissionNotification(message: "Claude needs your permission to use WebFetch")), now: t0 + 20)
    #expect(again == [.waitingBanner(project: "english-video")])
    #expect(store.sessions["s1"]?.action == "ждёт разрешения: Claude needs your permission to use Web…")
}

@Test func newPromptClearsDone() throws {
    var store = AgentSessionStore()
    store.apply(ev(.stop(lastMessage: "ok")), now: t0)
    store.apply(ev(.userPromptSubmit), now: t0 + 30)
    let s = try #require(store.sessions["s1"])
    #expect(s.status == .running)
    #expect(s.lastMessage == nil)
    #expect(s.subtitle == "думает…")
}

@Test func sessionEndRemovesAndIgnoredDoesNothing() {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit), now: t0)
    store.apply(ev(.ignored, "s2"), now: t0)
    #expect(store.sessions["s2"] == nil)
    store.apply(ev(.sessionEnd), now: t0 + 1)
    #expect(store.sessions.isEmpty)
}

@Test func visibleOrderWaitingRunningDone() {
    var store = AgentSessionStore()
    store.apply(ev(.stop(lastMessage: nil), "done", cwd: "/d"), now: t0)
    store.apply(ev(.userPromptSubmit, "run-late", cwd: "/r2"), now: t0 + 20)
    store.apply(ev(.userPromptSubmit, "run-early", cwd: "/r1"), now: t0 + 10)
    store.apply(ev(.permissionRequest(tool: "Bash", input: [:]), "wait", cwd: "/w"), now: t0 + 30)
    store.apply(ev(.sessionStart, "idle", cwd: "/i"), now: t0)
    #expect(store.visible.map(\.id) == ["wait", "run-early", "run-late", "done"])
}

@Test func originIsMergedAndCwdUpdated() throws {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit), now: t0)
    store.apply(ev(.postToolUse, cwd: "", origin: AgentOrigin(source: .other)), now: t0 + 1)
    let s = try #require(store.sessions["s1"])
    #expect(s.origin == iterm)
    #expect(s.cwd == "/Users/me/english-video")
}

@Test func projectFallsBackForEmptyCwd() throws {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit, cwd: ""), now: t0)
    #expect(try #require(store.sessions["s1"]).project == "?")
}

@Test func pruneRemovesDeadAndStale() {
    var store = AgentSessionStore()
    store.apply(ev(.userPromptSubmit, "alive", origin: AgentOrigin(source: .iterm, pid: 1)), now: t0)
    store.apply(ev(.userPromptSubmit, "dead", origin: AgentOrigin(source: .iterm, pid: 2)), now: t0)
    store.apply(ev(.userPromptSubmit, "stale", origin: AgentOrigin(source: .iterm, pid: 1)), now: t0 - 7 * 3600)
    store.apply(ev(.userPromptSubmit, "nopid", origin: AgentOrigin(source: .other)), now: t0)
    store.prune(now: t0 + 60, isAlive: { $0 == 1 })
    #expect(Set(store.sessions.keys) == ["alive", "nopid"])
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `cd AgentsKit && swift test --filter AgentSessionStoreTests`
Expected: FAIL: `cannot find 'AgentSessionStore' in scope`.

- [ ] **Step 3: Реализация**

`AgentsKit/Sources/AgentsKit/AgentSessionStore.swift`:

```swift
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
```

- [ ] **Step 4: Запустить тесты**

Run: `cd AgentsKit && swift test --filter AgentSessionStoreTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add AgentsKit
git commit -m "feat(agents): session store with status transitions and pruning"
```

---

### Task 4: Пути модуля и проверка жизни процесса

**Files:**
- Create: `AgentsKit/Sources/AgentsKit/AgentPaths.swift`
- Create: `AgentsKit/Sources/AgentsKit/ProcessProbe.swift`
- Test: `AgentsKit/Tests/AgentsKitTests/ProcessProbeTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `public enum AgentPaths { static var home: URL; static var supportDirectory: URL; static var socket: URL; static var hookScript: URL; static var claudeSettings: URL; static func ensureSupportDirectory() throws }`
  - `public enum ProcessProbe { static func isAlive(_ pid: Int32) -> Bool }`

- [ ] **Step 1: Написать падающие тесты**

`AgentsKit/Tests/AgentsKitTests/ProcessProbeTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentsKit

@Test func currentProcessIsAlive() {
    #expect(ProcessProbe.isAlive(getpid()))
}

@Test func finishedProcessIsDead() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try process.run()
    process.waitUntilExit()
    #expect(!ProcessProbe.isAlive(process.processIdentifier))
}

@Test func pathsLiveInRealHomeAndFitSocketLimit() {
    #expect(!AgentPaths.home.path.contains("/Library/Containers/"))
    #expect(AgentPaths.socket.path.hasSuffix("/.notch-agents/agents.sock"))
    #expect(AgentPaths.hookScript.lastPathComponent == "notch-agents-hook.sh")
    #expect(AgentPaths.claudeSettings.path.hasSuffix("/.claude/settings.json"))
    #expect(AgentPaths.socket.path.utf8.count < 104)
}
```

- [ ] **Step 2: Запустить тесты и убедиться, что они падают**

Run: `cd AgentsKit && swift test --filter ProcessProbeTests`
Expected: FAIL: `cannot find 'ProcessProbe' in scope`.

- [ ] **Step 3: Реализация**

`AgentsKit/Sources/AgentsKit/AgentPaths.swift`:

```swift
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
```

`AgentsKit/Sources/AgentsKit/ProcessProbe.swift`:

```swift
import Darwin

public enum ProcessProbe {
    /// Uses sysctl because kill(pid, 0) is denied inside the App Sandbox.
    /// When the kernel refuses to answer, reports "alive" so the idle timeout decides instead.
    public static func isAlive(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return true }
        return size > 0 && info.kp_proc.p_pid == pid
    }
}
```

- [ ] **Step 4: Запустить тесты**

Run: `cd AgentsKit && swift test --filter ProcessProbeTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add AgentsKit
git commit -m "feat(agents): module paths and sandbox-safe process liveness check"
```

---

### Task 5: Сервер Unix-сокета

**Files:**
- Create: `AgentsKit/Sources/AgentsKit/AgentSocketServer.swift`
- Create: `AgentsKit/Tests/AgentsKitTests/TestSupport.swift`
- Test: `AgentsKit/Tests/AgentsKitTests/AgentSocketServerTests.swift`

**Interfaces:**
- Consumes: —
- Produces:
  - `public final class AgentSocketServer { init(path: String, onLine: @escaping @Sendable (Data) -> Void); func start() throws; func stop(); static let maxLineBytes = 65536 }`
  - `AgentSocketServer.ServerError: .pathTooLong, .socket(Int32), .bind(Int32), .listen(Int32)`
  - Поведение: принимает подключение, читает до `\n` или EOF (не больше 64 КБ, таймаут чтения 1 с), закрывает подключение, вызывает `onLine` на своей фоновой очереди.
  - Тестовые помощники: `Inbox`, `waitUntil(_:_:)`, `sendLine(_:to:)`, `shortTempSocketPath()`

- [ ] **Step 1: Помощники для тестов**

`AgentsKit/Tests/AgentsKitTests/TestSupport.swift`:

```swift
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
```

- [ ] **Step 2: Написать падающие тесты**

`AgentsKit/Tests/AgentsKitTests/AgentSocketServerTests.swift`:

```swift
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
```

- [ ] **Step 3: Запустить тесты и убедиться, что они падают**

Run: `cd AgentsKit && swift test --filter AgentSocketServerTests`
Expected: FAIL: `cannot find 'AgentSocketServer' in scope`.

- [ ] **Step 4: Реализация**

`AgentsKit/Sources/AgentsKit/AgentSocketServer.swift`:

```swift
import Darwin
import Foundation

/// Listens on a Unix socket. Each connection carries one line; the server reads it, closes the
/// connection right away (so `nc` exits without waiting for its timeout) and hands the line over.
/// One-way by design: nothing is ever written back to the client.
public final class AgentSocketServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        case pathTooLong
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    public static let maxLineBytes = 64 * 1024

    private let path: String
    private let onLine: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "notch-agents.socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, onLine: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    public func start() throws {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ServerError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ServerError.bind(code)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw ServerError.listen(code)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let line = Self.readLine(from: client)
        close(client)
        if let line, !line.isEmpty { onLine(line) }
    }

    static func readLine(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxLineBytes {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            if let newline = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return data
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.isEmpty ? nil : data.prefix(maxLineBytes)
    }
}
```

- [ ] **Step 5: Запустить тесты**

Run: `cd AgentsKit && swift test --filter AgentSocketServerTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add AgentsKit
git commit -m "feat(agents): one-way Unix socket server"
```

---

### Task 6: Hook-скрипт, установщик hooks и консольная команда

**Files:**
- Create: `AgentsKit/Sources/AgentsKit/HookScript.swift`
- Create: `AgentsKit/Sources/AgentsKit/HookInstaller.swift`
- Modify: `AgentsKit/Sources/notch-agents-hooks/main.swift` (заменить заглушку)
- Test: `AgentsKit/Tests/AgentsKitTests/HookScriptTests.swift`
- Test: `AgentsKit/Tests/AgentsKitTests/HookInstallerTests.swift`

**Interfaces:**
- Consumes: `AgentSocketServer`, `AgentEvent.parse`, `AgentPaths` (Tasks 1, 4, 5); помощники из `TestSupport.swift`
- Produces:
  - `public enum HookScript { static func body(socketPath: String) -> String }` — скрипт понимает переменную `NOTCH_AGENTS_SOCKET` для тестов
  - `public enum HookInstaller { static let marker = "notch-agents-hook"; static let events: [String]; static func command(scriptPath: String) -> String; static func installing(into: [String: Any], command: String) -> [String: Any]; static func removing(from: [String: Any]) -> [String: Any]; static func isInstalled(in: [String: Any]) -> Bool; static func install(settingsURL: URL, scriptURL: URL, socketPath: String, now: Date) throws; static func uninstall(settingsURL: URL, scriptURL: URL, now: Date) throws; static func isInstalled(settingsURL: URL) -> Bool; static func backupURL(for: URL, now: Date) -> URL }`
  - CLI: `swift run --package-path AgentsKit notch-agents-hooks install|uninstall|status`

- [ ] **Step 1: Написать падающие тесты скрипта**

`AgentsKit/Tests/AgentsKitTests/HookScriptTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentsKit

private func writeScript(socketPath: String) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/na-hook-\(UUID().uuidString.prefix(8)).sh")
    try HookScript.body(socketPath: socketPath).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// Runs the script like Claude Code does: hook JSON on stdin, environment from the agent.
private func runScript(_ url: URL, stdin: String, env: [String: String]) throws -> (status: Int32, stdout: String, seconds: Double) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [url.path]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()].merging(env) { $1 }
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    let started = Date()
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (process.terminationStatus, out, Date().timeIntervalSince(started))
}

private let hookJSON = """
{"session_id":"s1","hook_event_name":"PreToolUse","cwd":"/Users/me/p",
 "tool_name":"Bash","tool_input":{"command":"echo \\"hi\\""}}
"""

@Test func deliversEnvelopeToSocket() throws {
    let socketPath = shortTempSocketPath()
    let inbox = Inbox()
    let server = AgentSocketServer(path: socketPath) { inbox.add($0) }
    try server.start()
    defer { server.stop() }
    let script = try writeScript(socketPath: socketPath)

    let result = try runScript(script, stdin: hookJSON, env: [
        "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:ABC",
        "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_PID": "\(getpid())",
    ])
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.seconds < 0.5)

    #expect(waitUntil { inbox.all.count == 1 })
    let event = try #require(inbox.all.first.flatMap(AgentEvent.parse))
    #expect(event.kind == .preToolUse(tool: "Bash", input: ["command": "echo \"hi\""]))
    #expect(event.origin.source == .iterm)
    #expect(event.origin.pid == getpid())
    #expect(event.origin.itermSessionID == "w0t0p0:ABC")
}

@Test func exitsInstantlyWithoutSocket() throws {
    let script = try writeScript(socketPath: "/tmp/na-missing-\(UUID().uuidString.prefix(8)).sock")
    let result = try runScript(script, stdin: hookJSON, env: [:])
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.seconds < 0.2)
}

@Test func envOverrideWinsOverBakedPath() throws {
    let socketPath = shortTempSocketPath()
    let inbox = Inbox()
    let server = AgentSocketServer(path: socketPath) { inbox.add($0) }
    try server.start()
    defer { server.stop() }
    let script = try writeScript(socketPath: "/tmp/na-wrong.sock")
    _ = try runScript(script, stdin: hookJSON, env: ["NOTCH_AGENTS_SOCKET": socketPath])
    #expect(waitUntil { inbox.all.count == 1 })
}

@Test func scriptCarriesMarker() {
    #expect(HookScript.body(socketPath: "/x").contains(HookInstaller.marker))
}
```

- [ ] **Step 2: Написать падающие тесты установщика**

`AgentsKit/Tests/AgentsKitTests/HookInstallerTests.swift`:

```swift
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
```

- [ ] **Step 3: Запустить тесты и убедиться, что они падают**

Run: `cd AgentsKit && swift test --filter "HookScriptTests|HookInstallerTests"`
Expected: FAIL: `cannot find 'HookScript' in scope`.

- [ ] **Step 4: Реализация скрипта**

`AgentsKit/Sources/AgentsKit/HookScript.swift`:

```swift
public enum HookScript {
    /// Fire-and-forget hook: wraps the event JSON with a few environment facts and sends one line.
    /// Never prints to stdout and always exits 0, so it can never block or steer Claude Code.
    /// Raw newlines are dropped from the payload: JSON escapes newlines inside strings, so this is lossless.
    public static func body(socketPath: String) -> String {
        """
        #!/bin/bash
        # \(HookInstaller.marker): sends Claude Code hook events to the notch app.
        # Generated by notch-agents-hooks; reinstalling overwrites this file.
        SOCK="${NOTCH_AGENTS_SOCKET:-\(socketPath)}"
        [ -S "$SOCK" ] || exit 0
        PAYLOAD=$(tr -d '\\n')
        [ -n "$PAYLOAD" ] || exit 0
        AGENT_PID="${CLAUDE_PID:-$PPID}"
        TTY=$(ps -o tty= -p "$AGENT_PID" 2>/dev/null | tr -d ' ')
        printf '{"hook":%s,"env":{"term_program":"%s","iterm_session_id":"%s","entrypoint":"%s","tty":"%s","pid":%d}}\\n' \\
          "$PAYLOAD" "${TERM_PROGRAM:-}" "${ITERM_SESSION_ID:-}" "${CLAUDE_CODE_ENTRYPOINT:-}" "$TTY" "$AGENT_PID" \\
          | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
        exit 0

        """
    }
}
```

- [ ] **Step 5: Реализация установщика**

`AgentsKit/Sources/AgentsKit/HookInstaller.swift`:

```swift
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
```

Скрипт берёт маркер из `HookInstaller.marker` и путь `~/.notch-agents/notch-agents-hook.sh` тоже содержит `notch-agents-hook`, поэтому команда в `settings.json` всегда распознаётся как наша.

- [ ] **Step 6: Консольная команда**

Заменить содержимое `AgentsKit/Sources/notch-agents-hooks/main.swift`:

```swift
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
```

- [ ] **Step 7: Запустить все тесты пакета**

Run: `cd AgentsKit && swift test`
Expected: PASS, 35 tests. Реальный `~/.claude/settings.json` тесты не трогают.

- [ ] **Step 8: Проверить команду без установки**

Run: `swift run --package-path AgentsKit notch-agents-hooks status`
Expected: `не установлены`. (Устанавливать по-настоящему — только в Task 10.)

- [ ] **Step 9: Commit**

```bash
git add AgentsKit
git commit -m "feat(agents): hook script, settings installer and CLI"
```

---

### Task 7: Подключение к приложению и вкладка «Агенты» (без оформления)

**Files:**
- Create: `boringNotch/Features/Agents/AgentsService.swift`
- Create: `boringNotch/Features/Agents/AgentStatus+Color.swift`
- Create: `boringNotch/Features/Agents/AgentsTabView.swift`
- Create: `scripts/agents/fake-events.sh`
- Modify: `boringNotch/enums/generic.swift` (`NotchViews`)
- Modify: `boringNotch/ContentView.swift:347-352` (switch по вкладкам)
- Modify: `boringNotch/components/Tabs/TabSelectionView.swift:17-20` (список вкладок)
- Modify: `boringNotch/components/Notch/BoringHeader.swift:19` (условие показа вкладок)
- Modify: `boringNotch/boringNotchApp.swift` (`applicationDidFinishLaunching`, `applicationWillTerminate`)
- Modify: `boringNotch/boringNotch.entitlements`
- Modify: `boringNotch.xcodeproj/project.pbxproj` (через Xcode: локальный пакет)

**Interfaces:**
- Consumes: всё из `AgentsKit`
- Produces:
  - `@MainActor final class AgentsService: ObservableObject { static let shared; @Published private(set) var sessions: [AgentSession]; @Published private(set) var bannerProject: String?; @Published private(set) var hooksInstalled: Bool; var hasWaiting: Bool; var hasClosedContent: Bool; var closedWingWidth: CGFloat; func start(); func stop() }`
  - `extension AgentStatus { var color: Color }`
  - `struct AgentsTabView: View`, `struct AgentRowView: View { let session: AgentSession; var onTap: () -> Void }`
  - `NotchViews.agents`

- [ ] **Step 1: Добавить пакет в проект**

В Xcode: File → Add Package Dependencies… → кнопка «Add Local…» → выбрать папку `AgentsKit` в корне репозитория → в диалоге добавить продукт `AgentsKit` в цель `boringNotch` (CLI `notch-agents-hooks` не добавлять).

- [ ] **Step 2: Разрешения песочницы**

В `boringNotch/boringNotch.entitlements` в массив `com.apple.security.temporary-exception.apple-events` добавить iTerm2 и Terminal, а перед закрывающим `</dict>` — доступ к папке модуля. Итоговые фрагменты:

```xml
	<key>com.apple.security.temporary-exception.apple-events</key>
	<array>
		<string>com.spotify.client</string>
		<string>com.apple.Music</string>
		<string>com.googlecode.iterm2</string>
		<string>com.apple.Terminal</string>
	</array>
```

```xml
	<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
	<array>
		<string>/.notch-agents/</string>
	</array>
```

- [ ] **Step 3: Новый вид в enum**

В `boringNotch/enums/generic.swift`:

```swift
public enum NotchViews {
    case home
    case shelf
    case agents
}
```

- [ ] **Step 4: Цвета статусов**

`boringNotch/Features/Agents/AgentStatus+Color.swift`:

```swift
import AgentsKit
import SwiftUI

extension AgentStatus {
    var color: Color {
        switch self {
        case .waiting: .yellow
        case .running: .blue
        case .done: .green
        case .idle: .gray
        }
    }
}
```

- [ ] **Step 5: Сервис**

`boringNotch/Features/Agents/AgentsService.swift`:

```swift
import AgentsKit
import Foundation
import SwiftUI

/// Glue between the socket, the pure session store and SwiftUI.
@MainActor
final class AgentsService: ObservableObject {
    static let shared = AgentsService()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var bannerProject: String?
    @Published private(set) var hooksInstalled = false

    var hasWaiting: Bool { sessions.contains { $0.status == .waiting } }
    var hasClosedContent: Bool { bannerProject != nil || !sessions.isEmpty }

    /// Extra width the closed notch needs on the right for dots or the banner.
    var closedWingWidth: CGFloat {
        if bannerProject != nil { return 150 }
        if sessions.isEmpty { return 0 }
        return CGFloat(min(sessions.count, 4)) * 11 + (sessions.count > 4 ? 22 : 0) + 8
    }

    private var store = AgentSessionStore()
    private var server: AgentSocketServer?
    private var bannerTask: Task<Void, Never>?
    private var pruneTimer: Timer?

    private init() {}

    func start() {
        guard server == nil else { return }
        do {
            try AgentPaths.ensureSupportDirectory()
            let server = AgentSocketServer(path: AgentPaths.socket.path) { [weak self] data in
                Task { @MainActor in self?.handle(data) }
            }
            try server.start()
            self.server = server
        } catch {
            NSLog("NotchAgents: socket failed to start: \(error)")
        }
        hooksInstalled = FileManager.default.fileExists(atPath: AgentPaths.hookScript.path)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    func stop() {
        pruneTimer?.invalidate()
        pruneTimer = nil
        server?.stop()
        server = nil
    }

    private func handle(_ data: Data) {
        guard let event = AgentEvent.parse(data) else {
            NSLog("NotchAgents: dropped malformed event (\(data.count) bytes)")
            return
        }
        let effects = store.apply(event, now: Date())
        sessions = store.visible
        for case let .waitingBanner(project) in effects {
            showBanner(project)
        }
    }

    private func showBanner(_ project: String) {
        bannerTask?.cancel()
        withAnimation(.smooth) { bannerProject = project }
        bannerTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { bannerProject = nil }
        }
    }

    private func prune() {
        store.prune(now: Date(), isAlive: ProcessProbe.isAlive)
        sessions = store.visible
        hooksInstalled = FileManager.default.fileExists(atPath: AgentPaths.hookScript.path)
    }
}
```

- [ ] **Step 6: Вкладка (пока простая)**

`boringNotch/Features/Agents/AgentsTabView.swift`:

```swift
import AgentsKit
import SwiftUI

struct AgentsTabView: View {
    @ObservedObject private var agents = AgentsService.shared

    var body: some View {
        Group {
            if agents.sessions.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(agents.sessions) { session in
                            AgentRowView(session: session) {}
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Агентов нет").foregroundStyle(.secondary)
            if !agents.hooksInstalled {
                Text("Установи hooks в терминале:").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("swift run --package-path AgentsKit notch-agents-hooks install")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentRowView: View {
    let session: AgentSession
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle().fill(session.status.color).frame(width: 8, height: 8)
                Text(session.project).fontWeight(.semibold).lineLimit(1)
                Text(session.subtitle).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 7: Подключить вкладку**

`boringNotch/components/Tabs/TabSelectionView.swift`:

```swift
let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Agents", icon: "sparkle", view: .agents)
]
```

`boringNotch/ContentView.swift`, в `switch coordinator.currentView` (около строки 347):

```swift
                    switch coordinator.currentView {
                    case .home:
                        NotchHomeView(albumArtNamespace: albumArtNamespace)
                    case .shelf:
                        ShelfView()
                    case .agents:
                        AgentsTabView()
                    }
```

`boringNotch/components/Notch/BoringHeader.swift`: добавить свойство в структуру `BoringHeader` рядом с другими `@ObservedObject`:

```swift
    @ObservedObject var agents = AgentsService.shared
```

и заменить условие на строке 19:

```swift
                if (!tvm.isEmpty || coordinator.alwaysShowTabs || !agents.sessions.isEmpty) && Defaults[.boringShelf] {
```

- [ ] **Step 8: Запуск сервиса**

`boringNotch/boringNotchApp.swift`: первой строкой тела `applicationDidFinishLaunching(_:)`:

```swift
        MainActor.assumeIsolated { AgentsService.shared.start() }
```

первой строкой тела `applicationWillTerminate(_:)`:

```swift
        MainActor.assumeIsolated { AgentsService.shared.stop() }
```

- [ ] **Step 9: Скрипт демо-событий**

`scripts/agents/fake-events.sh`:

```bash
#!/bin/bash
# Sends a fake agent scenario to the running notch app. Usage: fake-events.sh [demo|clear]
SOCK="${NOTCH_AGENTS_SOCKET:-$HOME/.notch-agents/agents.sock}"
[ -S "$SOCK" ] || { echo "socket not found: $SOCK (is the app running?)"; exit 1; }

# ev <session> <event> <cwd> <extra-json-fields> <term_program>
ev() {
  printf '{"hook":{"session_id":"%s","hook_event_name":"%s","cwd":"%s"%s},"env":{"term_program":"%s","pid":1}}\n' \
    "$1" "$2" "$3" "$4" "$5" | /usr/bin/nc -U -w 1 "$SOCK"
}

case "${1:-demo}" in
  demo)
    ev demo-a UserPromptSubmit /tmp/english-video '' iTerm.app
    ev demo-a PreToolUse /tmp/english-video ',"tool_name":"Bash","tool_input":{"command":"npm test"}' iTerm.app
    ev demo-b PreToolUse /tmp/SCADA ',"tool_name":"Edit","tool_input":{"file_path":"/tmp/SCADA/report.docx"}' vscode
    ev demo-c Stop "/tmp/Системный анализ" ',"last_assistant_message":"Добавил раздел 3 и таблицу"' ghostty
    sleep 3
    ev demo-a PermissionRequest /tmp/english-video ',"tool_name":"Bash","tool_input":{"command":"rm -rf dist"}' iTerm.app
    ;;
  clear)
    for s in demo-a demo-b demo-c; do ev "$s" SessionEnd /tmp '' ''; done
    ;;
  *)
    echo "usage: $0 [demo|clear]"; exit 2
    ;;
esac
```

```bash
chmod +x scripts/agents/fake-events.sh
```

`pid: 1` — это `launchd`, он всегда жив, поэтому демо-сессии не удаляются уборкой.

- [ ] **Step 10: Собрать**

Run: `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build | tail -3`
Expected: `** BUILD SUCCEEDED **`. Если компилятор пишет `switch must be exhaustive` в другом месте, добавить туда `case .agents: AgentsTabView()` (для видов) или `case .agents: break` (для логики).

- [ ] **Step 11: Проверить вручную**

```bash
pkill -x boringNotch; open build/Build/Products/Debug/boringNotch.app
ls -la ~/.notch-agents/
scripts/agents/fake-events.sh demo
```

Expected:
- `ls` показывает `agents.sock` с правами `srw-------`, папка `drwx------`.
- В раскрытой челке видна вкладка со звёздочкой; в ней 3 строки: `english-video` (ждёт), `SCADA` (`Edit report.docx`), `Системный анализ` (`готово: «Добавил раздел 3 и таблицу»`).
- `scripts/agents/fake-events.sh clear` — список пустеет, видна строка «Агентов нет» и команда установки hooks.

Если сокета нет: Console.app → фильтр `NotchAgents` покажет ошибку старта. Самая вероятная причина — исключение песочницы из Step 2 не применилось (пересобрать начисто: `rm -rf build`).

- [ ] **Step 12: Commit**

```bash
git add -A
git commit -m "feat(agents): wire AgentsKit into the app with a basic agents tab"
```

---

### Task 8: Свёрнутая челка — точки и плашка

**Files:**
- Create: `boringNotch/Features/Agents/AgentClosedWing.swift`
- Modify: `boringNotch/ContentView.swift` (свойство `agents`, `computedChinWidth`, `MusicLiveActivity()`, новая ветка без музыки)

**Interfaces:**
- Consumes: `AgentsService.shared.sessions`, `.bannerProject`, `.hasClosedContent`, `.closedWingWidth`; `AgentStatus.color` (Task 7)
- Produces: `struct AgentClosedWing: View`, `struct AgentsOnlyActivity: View { let notchWidth: CGFloat; let height: CGFloat }`

- [ ] **Step 1: Виды крыла**

`boringNotch/Features/Agents/AgentClosedWing.swift`:

```swift
import AgentsKit
import SwiftUI

/// Right side of the closed notch: one dot per agent, or the yellow banner for 5 seconds.
struct AgentClosedWing: View {
    @ObservedObject private var agents = AgentsService.shared

    var body: some View {
        Group {
            if let project = agents.bannerProject {
                Text("\(project) ждёт")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.yellow))
                    .frame(maxWidth: 140)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if !agents.sessions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(agents.sessions.prefix(4)) { session in
                        Circle()
                            .fill(session.status.color)
                            .frame(width: 7, height: 7)
                            .shadow(color: session.status == .done ? .clear : session.status.color, radius: 3)
                    }
                    if agents.sessions.count > 4 {
                        Text("+\(agents.sessions.count - 4)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.gray)
                    }
                }
                .transition(.opacity)
            }
        }
        .fixedSize()
    }
}

/// Closed notch when no music is playing but agents are active.
struct AgentsOnlyActivity: View {
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.black).frame(width: notchWidth)
            AgentClosedWing()
        }
        .frame(height: height)
    }
}
```

- [ ] **Step 2: Свойство в ContentView**

В `struct ContentView` рядом с другими `@ObservedObject` добавить:

```swift
    @ObservedObject var agents = AgentsService.shared
```

- [ ] **Step 3: Точки рядом с визуализатором**

В `MusicLiveActivity()` найти конец `HStack` с визуализатором — модификатор:

```swift
            .frame(
                width: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                        + gestureProgress / 2
                ),
                height: max(
                    0,
                    vm.effectiveClosedNotchHeight - 12
                ),
                alignment: .center
            )
```

Сразу после этого модификатора, всё ещё внутри внешнего `HStack`, добавить:

```swift

            AgentClosedWing()
```

- [ ] **Step 4: Ветка без музыки**

В цепочке `if/else if` закрытой челки заменить:

```swift
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
```

на:

```swift
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && agents.hasClosedContent && !vm.hideOnClosed {
                          AgentsOnlyActivity(notchWidth: vm.closedNotchSize.width, height: vm.effectiveClosedNotchHeight)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
```

- [ ] **Step 5: Ширина области наведения**

В `computedChinWidth` заменить ветку музыки и добавить ветку агентов:

```swift
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && (musicManager.isPlaying || !musicManager.isPlayerIdle)
            && coordinator.musicLiveActivityEnabled && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20) + agents.closedWingWidth
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && agents.hasClosedContent
            && !vm.hideOnClosed
        {
            chinWidth += agents.closedWingWidth + 12
        } else if !coordinator.expandingView.show && vm.notchState == .closed
```

(последняя строка — начало существующей ветки с `showNotHumanFace`, её не меняем.)

- [ ] **Step 6: Собрать**

Run: `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Проверить вручную**

```bash
pkill -x boringNotch; open build/Build/Products/Debug/boringNotch.app
```

1. Включить Spotify. `scripts/agents/fake-events.sh demo`.
   Expected: справа от визуализатора 3 точки (синяя, синяя, зелёная); через ~3 секунды на 5 секунд жёлтая плашка «english-video ждёт», затем одна из точек жёлтая.
2. Поставить Spotify на паузу и дождаться, пока плеер станет неактивным.
   Expected: челка с точками без обложки.
3. `scripts/agents/fake-events.sh clear`.
   Expected: точки исчезают, челка выглядит как в upstream.
4. Навести курсор на челку с точками: она раскрывается так же, как раньше.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(agents): status dots and waiting banner in the closed notch"
```

---

### Task 9: Вкладка «Агенты» — оформление и автопереход

**Files:**
- Modify: `boringNotch/Features/Agents/AgentsTabView.swift` (`AgentRowView`)
- Modify: `boringNotch/components/Tabs/TabSelectionView.swift` (жёлтая точка)
- Modify: `boringNotch/ContentView.swift:505-509` (`doOpen()`)

**Interfaces:**
- Consumes: `AgentsService.shared.hasWaiting`, `AgentFormat.elapsed`, `AgentSource.label`
- Produces: `AgentRowView` в финальном виде; поведение «открыться на вкладке агентов, если кто-то ждёт»

- [ ] **Step 1: Строка в финальном виде**

В `boringNotch/Features/Agents/AgentsTabView.swift` заменить `AgentRowView` целиком:

```swift
struct AgentRowView: View {
    let session: AgentSession
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 8, height: 8)
                    .shadow(color: session.status == .done ? .clear : session.status.color, radius: 3)
                Text(session.project)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 120, alignment: .leading)
                Text(session.subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(session.origin.source.label)
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(AgentFormat.elapsed(context.date.timeIntervalSince(session.statusSince)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(session.status == .waiting
                          ? Color.yellow.opacity(0.12)
                          : (hovering ? Color.white.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 2: Жёлтая точка на кнопке вкладки**

В `boringNotch/components/Tabs/TabSelectionView.swift` в `struct TabSelectionView` добавить свойство:

```swift
    @ObservedObject var agents = AgentsService.shared
```

и после `.frame(height: 26)` у `TabButton` добавить:

```swift
                    .overlay(alignment: .topTrailing) {
                        if tab.view == .agents && agents.hasWaiting {
                            Circle().fill(Color.yellow).frame(width: 6, height: 6).offset(x: -8, y: 4)
                        }
                    }
```

- [ ] **Step 3: Автопереход**

В `boringNotch/ContentView.swift` заменить `doOpen()`:

```swift
    private func doOpen() {
        if agents.hasWaiting {
            coordinator.currentView = .agents
        }
        withAnimation(animationSpring) {
            vm.open()
        }
    }
```

- [ ] **Step 4: Собрать**

Run: `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Проверить вручную**

```bash
pkill -x boringNotch; open build/Build/Products/Debug/boringNotch.app
scripts/agents/fake-events.sh demo
```

Подождать 5 секунд, навести на челку.
Expected: челка открывается сразу на вкладке агентов; на кнопке вкладки жёлтая точка; строка `english-video` подсвечена жёлтым, в ней `ждёт разрешения: Bash: rm -rf dist`, метка `iTerm`, время `<1 мин`. Строки при наведении подсвечиваются. После `scripts/agents/fake-events.sh clear` и повторного открытия челка открывается на последней вкладке, как в upstream.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(agents): polished agents tab, waiting badge and auto-open"
```

---

### Task 10: Переход в окно агента

**Files:**
- Create: `boringNotch/Features/Agents/AgentWindowJumper.swift`
- Modify: `boringNotch/Features/Agents/AgentsTabView.swift` (`AgentRowView(session:) {}` → вызов перехода)
- Modify: `boringNotch/Info.plist` (только если нет описания Apple Events)

**Interfaces:**
- Consumes: `AgentSession.origin` (`source`, `tty`, `itermSessionID`), `AgentSession.cwd`
- Produces: `@MainActor enum AgentWindowJumper { static func jump(to session: AgentSession) }`

- [ ] **Step 1: Реализация**

`boringNotch/Features/Agents/AgentWindowJumper.swift`:

```swift
import AgentsKit
import AppKit

/// Brings the agent's window to front. Precise down to the tab for iTerm2 and Terminal,
/// folder window for VS Code, app-level for Ghostty and the Claude desktop app.
@MainActor
enum AgentWindowJumper {
    static func jump(to session: AgentSession) {
        let origin = session.origin
        switch origin.source {
        case .iterm:
            if let id = origin.itermSessionID, let uuid = id.split(separator: ":").last,
               runScript(itermScript(sessionUUID: String(uuid))) { return }
            activate("com.googlecode.iterm2")
        case .terminal:
            if let tty = origin.tty, runScript(terminalScript(tty: "/dev/" + tty)) { return }
            activate("com.apple.Terminal")
        case .vscode:
            openVSCode(folder: session.cwd)
        case .ghostty:
            activate("com.mitchellh.ghostty")
        case .desktop:
            activate("com.anthropic.claudefordesktop")
        case .other:
            NSSound.beep()
        }
    }

    private static func activate(_ bundleID: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            NSSound.beep()
            return
        }
        app.activate()
    }

    private static func openVSCode(folder: String) {
        guard !folder.isEmpty,
              let path = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "vscode://file" + path)
        else { return activate("com.microsoft.VSCode") }
        NSWorkspace.shared.open(url)
    }

    /// Returns true only when the script found and selected the target.
    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("NotchAgents: AppleScript failed: \(error)") }
        return result?.stringValue == "ok"
    }

    /// Identifiers come from environment variables; keep only safe characters before embedding.
    private static func sanitized(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "/" }
    }

    private static func itermScript(sessionUUID: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique id of s is "\(sanitized(sessionUUID))" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(sanitized(tty))" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }
}
```

- [ ] **Step 2: Подключить к строке**

В `boringNotch/Features/Agents/AgentsTabView.swift` заменить:

```swift
                            AgentRowView(session: session) {}
```

на:

```swift
                            AgentRowView(session: session) {
                                AgentWindowJumper.jump(to: session)
                            }
```

- [ ] **Step 3: Описание для запроса прав**

Run: `grep -c NSAppleEventsUsageDescription boringNotch/Info.plist boringNotch.xcodeproj/project.pbxproj`
Если оба счётчика `0`, добавить в `boringNotch/Info.plist` внутрь корневого `<dict>`:

```xml
	<key>NSAppleEventsUsageDescription</key>
	<string>Чтобы показывать музыку и переходить в окно терминала с агентом.</string>
```

- [ ] **Step 4: Собрать**

Run: `xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug -derivedDataPath build build | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Проверить вручную**

Переход нельзя проверить фейковыми событиями: нужны настоящие окна. Проверка — в Task 11, Step 4.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(agents): jump to the agent's window on click"
```

---

### Task 11: Установка hooks и сквозная проверка

Ручная задача.

**Files:**
- Modify: `~/.claude/settings.json` (через CLI, с копией)

**Interfaces:**
- Consumes: всё выше
- Produces: рабочая система на реальных сессиях

- [ ] **Step 1: Установить hooks**

```bash
swift run --package-path AgentsKit notch-agents-hooks install
swift run --package-path AgentsKit notch-agents-hooks status
ls ~/.claude/ | grep notch-agents-backup
```

Expected: «Hooks установлены…», затем `установлены`, и есть файл копии.

- [ ] **Step 2: Проверить hook вхолостую**

```bash
echo '{"session_id":"probe","hook_event_name":"UserPromptSubmit","cwd":"/tmp/probe"}' | ~/.notch-agents/notch-agents-hook.sh; echo "exit=$?"
```

Expected: `exit=0`, ничего больше не напечатано; в челке появилась синяя точка `probe`. Убрать: `echo '{"session_id":"probe","hook_event_name":"SessionEnd","cwd":"/tmp"}' | ~/.notch-agents/notch-agents-hook.sh`.

- [ ] **Step 3: Выключить старые уведомления**

Открыть `~/.claude/settings.json`, найти записи с `terminal-notifier` и удалить их (или весь блок, если он только про уведомления). Копия до изменений уже есть с шага 1.

- [ ] **Step 4: Чек-лист на настоящих сессиях**

Для каждого источника открыть **новую** сессию Claude Code (старые hooks не подхватывают) и попросить агента сделать что-то с командой в терминале в режиме, где он спросит разрешение:

| Проверка | iTerm2 | Ghostty | VS Code | Десктоп Claude |
|---|---|---|---|---|
| Точка синяя, пока агент работает | ☐ | ☐ | ☐ | ☐ |
| Плашка 5 с и жёлтая точка при запросе разрешения | ☐ | ☐ | ☐ | ☐ |
| После ответа точка снова синяя | ☐ | ☐ | ☐ | ☐ |
| Зелёная точка и «готово: …» после окончания | ☐ | ☐ | ☐ | ☐ |
| Метка источника в строке верная | ☐ | ☐ | ☐ | ☐ |
| Клик по строке переводит в окно (iTerm — в нужную вкладку; Ghostty и Claude — в приложение) | ☐ | ☐ | ☐ | ☐ |
| `/exit` убирает агента | ☐ | ☐ | ☐ | — |

Дополнительно:
- ☐ Закрыть вкладку терминала с работающим агентом, не выходя из Claude Code: в течение ~30 секунд агент пропадает. Если не пропадает — значит, песочница не даёт `sysctl` видеть чужие процессы; тогда он пропадёт через 6 часов, и это нужно записать как известное ограничение.
- ☐ Выйти из приложения челки и поработать агентом: Claude Code работает без задержек (hook выходит сразу).
- ☐ Музыка и полка работают как до изменений.
- ☐ При первом клике по iTerm/Terminal macOS спрашивает разрешение на управление — разрешить.

- [ ] **Step 5: Записать результаты и закоммитить**

Добавить в конец спецификации раздел «Результаты проверки 2026-…» с отмеченной таблицей и найденными ограничениями.

```bash
git add docs
git commit -m "docs(agents): end-to-end verification results"
```

---

## Как держать форк в актуальном состоянии

Раз в несколько недель или после обновления macOS, если сломалась музыка:

```bash
git fetch upstream
git merge upstream/main
```

Конфликты возможны только в файлах из списка правок upstream (`ContentView.swift`, `TabSelectionView.swift`, `BoringHeader.swift`, `generic.swift`, `boringNotchApp.swift`, `Info.plist`, `boringNotch.entitlements`, `project.pbxproj`). Код в `AgentsKit/` и `boringNotch/Features/Agents/` конфликтовать не может.
