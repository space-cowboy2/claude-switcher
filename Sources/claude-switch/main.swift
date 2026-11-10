import Foundation
import SwitchCore

let usage = """
claude-switch: switch the Claude desktop app between two accounts.

  claude-switch status                 show both accounts and which one is active
  claude-switch switch [--to N] [--session local_ID] [--force]
                                       quit Claude, sync sessions, open the other account
  claude-switch sync                   sync the session list now (Claude must be closed)
  claude-switch auto on|off            switch automatically when a usage limit is hit
  claude-switch menu                   print what the menu bar shows
  claude-switch install-hooks [--settings FILE] [--bin PATH]
  claude-switch uninstall-hooks [--settings FILE]
  claude-switch hook stop-failure|session-start    (called by Claude Code)
  claude-switch test-limit --profile N [--session local_ID]
                                       pretend profile N just hit its limit

  --home DIR   use DIR instead of ~/Library/Application Support/AccountSwitcher
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let store = Store(home: option("--home").map { URL(fileURLWithPath: Config.normalize($0)) })
let engine = Engine(store: store)
let command = args.first ?? "help"
args = Array(args.dropFirst())

func printStatus() {
    let s = engine.status()
    for p in s.profiles {
        let mark = p.running ? "*" : " "
        let who = p.ready ? (p.email ?? p.account.map { String($0.prefix(8)) } ?? "signed in") : "not signed in"
        var line = "\(mark) \(p.profile.id)  \(p.profile.name)  [\(who)]"
        if let u = p.usage {
            line += "  5h=\(u.fiveHour.map { "\(Int($0.rounded()))%" } ?? "?") week=\(u.weekly.map { "\(Int($0.rounded()))%" } ?? "?")"
        }
        if let until = p.limitedUntil, until > Date().timeIntervalSince1970 {
            line += "  limit reached, resets \(MenuModel.clock(until))"
        }
        print(line)
    }
    print("auto-switch: \(s.autoSwitch ? "on" : "off")")
    if let p = s.needsRestart { print("profile \(p) needs a restart to load shared sessions") }
}

switch command {
case "status":
    printStatus()

case "switch":
    let to = option("--to").flatMap(Int.init)
    let session = option("--session")
    do {
        let r = try engine.switchTo(to, reason: "manual", sessionId: session, force: flag("--force"))
        print(r.launched ? "now on profile \(r.to)\(r.report.map { " (\($0))" } ?? "")" : "profile \(r.to) is already active")
    } catch {
        fail("\(error)")
    }

case "sync":
    guard let r = engine.syncIfIdle() else { fail("Not synced: Claude is running, or another switch is in progress.") }
    print(r)

case "auto":
    guard let v = args.first, v == "on" || v == "off" else { fail("usage: claude-switch auto on|off") }
    var c = store.loadConfig()
    c.autoSwitch = v == "on"
    do { try store.saveConfig(c) } catch { fail("\(error)") }
    print("auto-switch: \(v)")

case "menu":
    let s = engine.status()
    print("[\(s.title)]")
    for row in MenuModel.rows(s) {
        switch row.kind {
        case .separator: print("  ----")
        default:
            print("  \(row.checked ? "✓" : " ") \(row.title)\(row.enabled ? "" : "  (disabled)")")
            if let sub = row.subtitle { print("      \(sub)") }
        }
    }

case "install-hooks", "uninstall-hooks":
    let settings = URL(fileURLWithPath: Config.normalize(option("--settings") ?? "~/.claude/settings.json"))
    let bin = option("--bin") ?? Config.normalize("~/.local/bin/claude-switch")
    do {
        if let backup = try HookInstaller.update(file: settings, bin: bin, install: command == "install-hooks") {
            print("updated \(settings.path) (backup: \(backup.lastPathComponent))")
        } else {
            print("no change to \(settings.path)")
        }
    } catch {
        fail("\(error)")
    }

case "hook":
    let env = ProcessInfo.processInfo.environment
    switch args.first {
    case "stop-failure":
        HookRunner.stopFailure(input: FileHandle.standardInput.readDataToEndOfFile(), env: env, store: store)
    case "session-start":
        HookRunner.sessionStart(env: env, store: store)
    default:
        break
    }
    // A hook must never fail the session it runs in.
    exit(0)

case "test-limit":
    guard let id = option("--profile").flatMap(Int.init), store.loadConfig().profile(id) != nil else {
        fail("usage: claude-switch test-limit --profile N")
    }
    let event = LimitEvent(at: Date().timeIntervalSince1970, profileId: id, sessionId: option("--session"),
                           resetsAt: Date().timeIntervalSince1970 + 3600, limitType: "five_hour",
                           message: "test event")
    let data = try JSONEncoder().encode(event)
    try data.write(to: store.eventsDir.appendingPathComponent("limit-\(Int(event.at * 1000))-test.json"), options: .atomic)
    print("wrote a limit event for profile \(id); the menu bar app acts on it within a few seconds")

default:
    print(usage)
}
