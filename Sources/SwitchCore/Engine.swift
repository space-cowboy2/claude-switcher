import Foundation

// MARK: - System access (replaceable in tests)

public struct ProcInfo: Equatable {
    public let pid: Int32
    public let command: String
    public init(pid: Int32, command: String) { self.pid = pid; self.command = command }
}

public protocol System: AnyObject {
    func processes() -> [ProcInfo]
    func terminate(pid: Int32, force: Bool)
    /// Starts a new instance of the app with the given arguments.
    func launch(appPath: String, args: [String]) throws
    /// Brings the already running app to the front.
    func activate(appPath: String)
    func now() -> Date
    func sleep(_ seconds: Double)
}

public final class RealSystem: System {
    public init() {}

    public func processes() -> [ProcInfo] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=", "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [ProcInfo] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let t = line.drop { $0 == " " }
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
            out.append(ProcInfo(pid: pid, command: String(t[t.index(after: sp)...])))
        }
        return out
    }

    public func terminate(pid: Int32, force: Bool) { kill(pid, force ? SIGKILL : SIGTERM) }

    private func open(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw SwitchError.launchFailed("\(error)") }
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw SwitchError.launchFailed("open exited with \(p.terminationStatus)") }
    }

    public func launch(appPath: String, args: [String]) throws {
        try open(["-n", "-a", appPath] + (args.isEmpty ? [] : ["--args"] + args))
    }

    public func activate(appPath: String) { try? open(["-a", appPath]) }

    public func now() -> Date { Date() }

    public func sleep(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
}

// MARK: - Running instances

public struct Instance: Equatable {
    public let pid: Int32
    /// Nil when the instance uses a data folder that is not one of the configured profiles.
    public let profileId: Int?
}

public enum Instances {
    static func executable(_ config: Config) -> String {
        config.appPath + "/Contents/MacOS/"
            + URL(fileURLWithPath: config.appPath).deletingPathExtension().lastPathComponent
    }

    /// Main processes of the app (helpers excluded), each mapped to its profile.
    public static func mains(config: Config, procs: [ProcInfo]) -> [Instance] {
        let exe = executable(config)
        var out: [Instance] = []
        for p in procs where p.command == exe || p.command.hasPrefix(exe + " ") {
            let rest = p.command.dropFirst(exe.count)
            if let r = rest.range(of: "--user-data-dir=") {
                var tail = String(rest[r.upperBound...])
                if tail.hasPrefix("/private/") { tail = Config.normalize(String(tail.prefix { $0 != " " })) + tail.drop { $0 != " " } }
                let match = config.profiles
                    .filter { tail == $0.dataDir || tail.hasPrefix($0.dataDir + " ") }
                    .max { $0.dataDir.count < $1.dataDir.count }
                out.append(Instance(pid: p.pid, profileId: match?.id))
            } else {
                out.append(Instance(pid: p.pid, profileId: config.profiles.first { config.isDefault($0) }?.id))
            }
        }
        return out
    }

    /// True while any process (main or helper) still has the data folder open.
    static func dirInUse(_ dir: String, procs: [ProcInfo]) -> Bool {
        // Helpers may spell a temp folder with or without the /private prefix.
        return ["--user-data-dir=" + dir, "--user-data-dir=/private" + dir].contains { flag in
            procs.contains { $0.command.hasSuffix(flag) || $0.command.contains(flag + " ") }
        }
    }

    /// The Squirrel updater waits for every instance to exit and then replaces the app bundle.
    public static func updaterRunning(_ procs: [ProcInfo]) -> Bool {
        procs.contains { $0.command.contains("Squirrel.framework/Resources/ShipIt") }
    }
}

// MARK: - Profile facts read from disk

public struct UsageSample: Equatable {
    public var fiveHour: Double?
    public var weekly: Double?
    public var at: Double
}

public enum ProfileProbe {
    /// The account last signed in to a profile. Reads one non-secret key and nothing else.
    public static func account(_ p: Profile) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p.dataDir + "/config.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["lastKnownAccountUuid"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Latest usage sample the app saved for a profile (optionally for one organization).
    public static func usage(_ p: Profile, org: String?) -> UsageSample? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: p.dataDir + "/plan-usage-history.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let samples = obj["samples"] as? [[String: Any]] else { return nil }
        for s in samples.reversed() {
            if let org, (s["org"] as? String) != org { continue }
            guard let u = s["u"] as? [String: Any], let t = (s["t"] as? NSNumber)?.doubleValue else { continue }
            return UsageSample(fiveHour: (u["fh"] as? NSNumber)?.doubleValue,
                               weekly: (u["sd"] as? NSNumber)?.doubleValue,
                               at: t > 1e11 ? t / 1000 : t)
        }
        return nil
    }

    /// True when a Code transcript was written very recently, i.e. a session is probably working.
    public static func recentTranscriptWrite(within seconds: Double, now: Date = Date(),
                                             projects: String = NSHomeDirectory() + "/.claude/projects") -> Bool {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-seconds)
        for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
            let d = projects + "/" + dir
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".jsonl") {
                if let m = (try? fm.attributesOfItem(atPath: d + "/" + f))?[.modificationDate] as? Date, m > cutoff {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - Status and menu

public struct ProfileStatus: Equatable {
    public var profile: Profile
    public var running: Bool
    /// Signed in at least once.
    public var ready: Bool
    public var account: String?
    public var email: String?
    public var usage: UsageSample?
    public var limitedUntil: Double?
}

public struct Status: Equatable {
    public var profiles: [ProfileStatus]
    public var autoSwitch: Bool
    /// Profile whose running instance has an account folder that has never been synced; it needs
    /// one restart to show the shared list.
    public var needsRestart: Int?
    public var setupProfile: Int?

    public var active: [Int] { profiles.filter(\.running).map(\.profile.id) }

    /// Short text for the menu bar: the active profile number.
    public var title: String {
        switch active.count {
        case 0: return "–"
        case 1: return String(active[0])
        default: return active.map(String.init).joined(separator: "+")
        }
    }
}

public struct MenuRow: Equatable {
    public enum Kind: Equatable {
        case header
        case account(Int)
        case action(String)
        case toggle(String)
        case info
        case separator
    }

    public var kind: Kind
    public var title: String
    public var subtitle: String?
    public var checked = false
    public var enabled = true

    public init(_ kind: Kind, _ title: String = "", subtitle: String? = nil, checked: Bool = false, enabled: Bool = true) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.checked = checked; self.enabled = enabled
    }
}

public enum MenuModel {
    /// A time of day, with the weekday when it is not today.
    public static func clock(_ t: Double, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }

    static func subtitle(_ p: ProfileStatus, now: Date) -> String? {
        guard p.ready else { return "Not signed in yet" }
        var parts: [String] = []
        if p.running { parts.append("Active") }
        if let until = p.limitedUntil, until > now.timeIntervalSince1970 {
            parts.append("Limit reached · resets " + clock(until, now: now))
        } else if let u = p.usage, now.timeIntervalSince1970 - u.at < 7 * 86400 {
            if let fh = u.fiveHour { parts.append("5-hour \(Int(fh.rounded()))%") }
            if let sd = u.weekly { parts.append("weekly \(Int(sd.rounded()))%") }
            if !p.running { parts.append("as of " + clock(u.at, now: now)) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func rows(_ s: Status, now: Date = Date()) -> [MenuRow] {
        var rows: [MenuRow] = [MenuRow(.header, "Claude account", enabled: false)]
        for p in s.profiles {
            let label = p.ready ? p.profile.name + (p.email.map { " · " + $0 } ?? "") : "Set up \(p.profile.name)…"
            rows.append(MenuRow(.account(p.profile.id), label, subtitle: subtitle(p, now: now), checked: p.running))
        }
        rows.append(MenuRow(.separator))
        let active = s.active
        if active.count > 1 {
            rows.append(MenuRow(.info, "Two profiles are open. Quit one of them.", enabled: false))
        }
        if active.count == 1, let other = s.profiles.first(where: { !$0.running }) {
            rows.append(MenuRow(.action("switch:\(other.profile.id)"), "Switch to \(other.profile.name)",
                                enabled: other.ready))
        }
        rows.append(MenuRow(.toggle("auto"), "Switch automatically at limit", checked: s.autoSwitch))
        if s.needsRestart != nil {
            rows.append(MenuRow(.action("restart"), "Restart Claude to load shared sessions"))
        }
        let ready = s.profiles.filter(\.ready)
        if ready.count > 1, Set(ready.compactMap(\.account)).count == 1 {
            rows.append(MenuRow(.info, "Both profiles are signed in to the same account.", enabled: false))
        }
        rows.append(MenuRow(.separator))
        rows.append(MenuRow(.action("open"), "Open Claude"))
        rows.append(MenuRow(.action("quit"), "Quit Switcher"))
        return rows
    }
}

// MARK: - Engine

public struct SwitchResult: Equatable {
    public var from: Int?
    public var to: Int
    public var launched: Bool
    public var report: SyncReport?
}

public enum LimitDecision: Equatable {
    case switchTo(Int)
    case skip(String, notify: Bool)
}

public enum LimitOutcome: Equatable {
    case switched(from: Int, to: Int)
    case skipped(String, notify: Bool)
    case failed(String)
}

public final class Engine {
    public let store: Store
    public let system: System
    /// Longest wait for a pending app update to finish installing.
    public var updateWait: Double = 120

    public init(store: Store, system: System = RealSystem()) {
        self.store = store
        self.system = system
    }

    public func instances(_ cfg: Config) -> [Instance] {
        Instances.mains(config: cfg, procs: system.processes())
    }

    // MARK: Status

    public func status() -> Status {
        let cfg = store.loadConfig()
        let st = store.loadState()
        let running = Set(instances(cfg).compactMap(\.profileId))
        var needsRestart: Int?
        let profiles = cfg.profiles.map { p -> ProfileStatus in
            let account = ProfileProbe.account(p)
            let ident = st.identities[String(p.id)].flatMap { $0.account == account ? $0 : nil }
            if running.contains(p.id), !st.manifest.isEmpty,
               SessionSync.existingFolders(profiles: [p]).contains(where: { st.manifest[$0] == nil }) {
                needsRestart = needsRestart ?? p.id
            }
            return ProfileStatus(profile: p, running: running.contains(p.id), ready: account != nil,
                                 account: account, email: ident?.email,
                                 usage: ProfileProbe.usage(p, org: ident?.org),
                                 limitedUntil: st.limits[String(p.id)]?.until)
        }
        return Status(profiles: profiles, autoSwitch: cfg.autoSwitch, needsRestart: needsRestart,
                      setupProfile: st.setupProfile)
    }

    // MARK: Switching

    /// Quits the running profile, syncs sessions, and starts the target profile.
    ///
    /// - Parameters:
    ///   - target: profile to end up on; nil means "the other one".
    ///   - sessionId: a `local_…` session to reopen in the target profile.
    ///   - force: SIGKILL if the app does not quit in time (default: give up instead).
    ///   - restart: also quit and restart the target when it is already running.
    @discardableResult
    public func switchTo(_ target: Int? = nil, reason: String, sessionId: String? = nil,
                         force: Bool = false, restart: Bool = false) throws -> SwitchResult {
        try store.withLock("switch.lock", wait: false) {
            let cfg = store.loadConfig()
            let running = instances(cfg).filter { $0.profileId != nil }
            let from = running.first?.profileId
            let last = store.loadState().lastSwitch?.to

            let targetId: Int
            if let target {
                targetId = target
            } else if let base = from ?? last ?? cfg.profiles.first?.id, let other = cfg.other(than: base) {
                targetId = other.id
            } else {
                throw SwitchError.unknownProfile(0)
            }
            guard let tp = cfg.profile(targetId) else { throw SwitchError.unknownProfile(targetId) }

            let targetRunning = running.contains { $0.profileId == targetId }
            let toQuit = running.filter { restart || $0.profileId != targetId }
            if targetRunning && toQuit.isEmpty {
                system.activate(appPath: cfg.appPath)
                return SwitchResult(from: from, to: targetId, launched: false, report: nil)
            }

            for i in toQuit { system.terminate(pid: i.pid, force: false) }
            try waitForExit(toQuit, cfg: cfg, force: force)

            let keepTarget = targetRunning && !restart
            var report: SyncReport?
            if !keepTarget {
                waitForUpdater(cfg)
                // Claude is closed at this point. A failed sync must not leave it closed: log it and
                // start the target anyway (its list is then as it was).
                do {
                    report = try store.mutateState { st in
                        try SessionSync.sync(profiles: cfg.profiles, state: &st, backups: store.backupsDir, now: system.now())
                    }
                } catch {
                    store.log("session sync failed, continuing: \(error)")
                }
            }
            try store.mutateState { st in
                st.lastSwitch = SwitchRecord(at: system.now().timeIntervalSince1970, from: from, to: targetId, reason: reason)
                if reason == "setup" {
                    st.setupProfile = targetId
                } else if reason == "reseed" || st.setupProfile != targetId {
                    st.setupProfile = nil
                }
            }
            if keepTarget {
                system.activate(appPath: cfg.appPath)
            } else {
                var args: [String] = []
                if !cfg.isDefault(tp) { args.append("--user-data-dir=" + tp.dataDir) }
                if let s = sessionId, s.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil {
                    args.append("claude://code/continue?session=" + s)
                }
                try system.launch(appPath: cfg.appPath, args: args)
            }
            store.log("switch \(from.map(String.init) ?? "-") -> \(targetId) (\(reason)) \(report?.description ?? "no sync")")
            return SwitchResult(from: from, to: targetId, launched: !keepTarget, report: report)
        }
    }

    private func waitForExit(_ quitting: [Instance], cfg: Config, force: Bool) throws {
        guard !quitting.isEmpty else { return }
        let pids = Set(quitting.map(\.pid))
        let dirs = quitting.compactMap { $0.profileId.flatMap(cfg.profile)?.dataDir }
        func alive() -> [Int32] { system.processes().map(\.pid).filter(pids.contains) }

        let deadline = system.now().addingTimeInterval(cfg.quitTimeout)
        while !alive().isEmpty {
            if system.now() >= deadline {
                guard force else { throw SwitchError.quitTimeout }
                for pid in alive() { system.terminate(pid: pid, force: true) }
                system.sleep(1)
                break
            }
            system.sleep(0.25)
        }
        // Helpers flush cookies and storage for a moment after the main process is gone.
        let settle = system.now().addingTimeInterval(5)
        while system.now() < settle {
            let procs = system.processes()
            if !dirs.contains(where: { Instances.dirInUse($0, procs: procs) }) { break }
            system.sleep(0.25)
        }
    }

    /// If an update is staged, the updater replaces the app once the last instance has exited.
    /// Starting the app during that swap can launch a half-replaced bundle.
    private func waitForUpdater(_ cfg: Config) {
        let deadline = system.now().addingTimeInterval(updateWait)
        while system.now() < deadline {
            let procs = system.processes()
            // Another instance still running means the updater cannot start yet.
            if !Instances.mains(config: cfg, procs: procs).isEmpty { return }
            if !Instances.updaterRunning(procs) { break }
            system.sleep(0.5)
        }
        let exe = Instances.executable(cfg)
        let appeared = system.now().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: exe), system.now() < appeared { system.sleep(0.5) }
    }

    /// Syncs sessions when no configured profile is running. Returns nil when it could not run.
    public func syncIfIdle() -> SyncReport? {
        try? store.withLock("switch.lock", wait: false) { () -> SyncReport? in
            let cfg = store.loadConfig()
            guard instances(cfg).allSatisfy({ $0.profileId == nil }) else { return nil }
            return try store.mutateState { st in
                try SessionSync.sync(profiles: cfg.profiles, state: &st, backups: store.backupsDir, now: system.now())
            }
        }
    }

    // MARK: Hook events

    /// Reads and removes pending hook events. Identity events are folded into the state; limit
    /// events are returned for `handle`.
    public func ingestEvents() -> [LimitEvent] {
        let fm = FileManager.default
        var limits: [LimitEvent] = []
        var identities: [IdentityEvent] = []
        for name in ((try? fm.contentsOfDirectory(atPath: store.eventsDir.path)) ?? []).sorted()
        where name.hasSuffix(".json") {
            let url = store.eventsDir.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url) else { continue }
            if name.hasPrefix("limit-"), let e = try? JSONDecoder().decode(LimitEvent.self, from: data) {
                limits.append(e)
            } else if name.hasPrefix("identity-"), let e = try? JSONDecoder().decode(IdentityEvent.self, from: data) {
                identities.append(e)
            }
        }
        if !identities.isEmpty {
            _ = try? store.mutateState { st in
                for e in identities {
                    st.identities[String(e.profileId)] = Identity(account: e.account, org: e.org, email: e.email, at: e.at)
                }
            }
        }
        return limits
    }

    /// The rules for acting on a usage-limit event. Pure, so it can be tested exhaustively.
    public static func decide(event: LimitEvent, config: Config, state: State, running: [Int],
                              ready: (Profile) -> Bool, account: (Profile) -> String?, now: Date) -> LimitDecision {
        guard config.autoSwitch else { return .skip("Automatic switching is off.", notify: false) }
        guard let from = config.profile(event.profileId) else { return .skip("Unknown profile.", notify: false) }
        let t = now.timeIntervalSince1970
        guard t - event.at < 180 else { return .skip("The limit event is stale.", notify: false) }
        guard running == [from.id] else {
            return .skip("\(from.name) is not the only profile running.", notify: false)
        }
        if let last = state.lastSwitch, t - last.at < config.debounce {
            return .skip("A switch just happened.", notify: false)
        }
        guard let to = config.other(than: from.id) else { return .skip("There is no other profile.", notify: false) }
        guard ready(to) else { return .skip("\(to.name) is not set up yet.", notify: true) }
        if let a = account(from), a == account(to) {
            return .skip("Both profiles are signed in to the same account.", notify: true)
        }
        if let mark = state.limits[String(to.id)], mark.until > t {
            return .skip("Both accounts are at their limit. \(to.name) resets \(MenuModel.clock(mark.until, now: now)).",
                         notify: true)
        }
        return .switchTo(to.id)
    }

    /// Records the limit and switches if the rules allow it.
    public func handle(_ event: LimitEvent) -> LimitOutcome {
        let cfg = store.loadConfig()
        let now = system.now()
        let t = now.timeIntervalSince1970
        var until = t + cfg.limitFallbackMinutes * 60
        if let r = event.resetsAt, r > t, r < t + 8 * 86400 { until = r }
        _ = try? store.mutateState { st in
            st.limits[String(event.profileId)] = LimitMark(until: until, kind: event.limitType ?? "usage", at: event.at)
        }
        let decision = Engine.decide(event: event, config: cfg, state: store.loadState(),
                                     running: instances(cfg).compactMap(\.profileId),
                                     ready: { ProfileProbe.account($0) != nil },
                                     account: ProfileProbe.account, now: now)
        switch decision {
        case .skip(let why, let notify):
            store.log("limit on profile \(event.profileId): not switching: \(why)")
            return .skipped(why, notify: notify)
        case .switchTo(let id):
            do {
                try switchTo(id, reason: "limit", sessionId: event.sessionId)
                return .switched(from: event.profileId, to: id)
            } catch {
                store.log("limit on profile \(event.profileId): switch failed: \(error)")
                return .failed("\(error)")
            }
        }
    }
}
