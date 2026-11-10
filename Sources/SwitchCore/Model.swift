import Foundation

// MARK: - Config

public struct Profile: Codable, Equatable {
    public var id: Int
    public var name: String
    /// Absolute path of the app's data folder for this profile.
    public var dataDir: String

    public init(id: Int, name: String, dataDir: String) {
        self.id = id
        self.name = name
        self.dataDir = Config.normalize(dataDir)
    }
}

public struct Config: Codable, Equatable {
    public var appPath: String
    public var profiles: [Profile]
    public var autoSwitch: Bool
    public var hotkey: Bool
    /// Seconds to wait for Claude to exit after SIGTERM.
    public var quitTimeout: Double
    /// Seconds after a switch during which limit events are ignored.
    public var debounce: Double
    /// How long an account counts as limited when the reset time is unknown.
    public var limitFallbackMinutes: Double
    /// Seconds after launch before the "reopen this session" link is sent a second time. 0 turns
    /// the second send off.
    public var reopenDelay: Double = 8
    /// The data folder Claude uses when started with no arguments.
    public var defaultDataDir: String = Config.defaultDataDir

    public static var defaultDataDir: String {
        normalize(NSHomeDirectory() + "/Library/Application Support/Claude")
    }

    /// One spelling per folder: tilde expanded, `.`/`..` removed, and the `/private` prefix that
    /// macOS puts in front of /tmp, /var and /etc dropped (whether or not the folder exists yet).
    public static func normalize(_ path: String) -> String {
        let p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        for root in ["/tmp", "/var", "/etc"] where p == "/private" + root || p.hasPrefix("/private" + root + "/") {
            return String(p.dropFirst("/private".count))
        }
        return p
    }

    public init(appPath: String = "/Applications/Claude.app", profiles: [Profile], autoSwitch: Bool = true,
                hotkey: Bool = true, quitTimeout: Double = 100, debounce: Double = 90,
                limitFallbackMinutes: Double = 60) {
        self.appPath = appPath
        self.profiles = profiles
        self.autoSwitch = autoSwitch
        self.hotkey = hotkey
        self.quitTimeout = quitTimeout
        self.debounce = debounce
        self.limitFallbackMinutes = limitFallbackMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? "/Applications/Claude.app"
        profiles = try c.decode([Profile].self, forKey: .profiles).map {
            Profile(id: $0.id, name: $0.name, dataDir: $0.dataDir)
        }
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? true
        hotkey = try c.decodeIfPresent(Bool.self, forKey: .hotkey) ?? true
        quitTimeout = try c.decodeIfPresent(Double.self, forKey: .quitTimeout) ?? 100
        debounce = try c.decodeIfPresent(Double.self, forKey: .debounce) ?? 90
        limitFallbackMinutes = try c.decodeIfPresent(Double.self, forKey: .limitFallbackMinutes) ?? 60
        reopenDelay = try c.decodeIfPresent(Double.self, forKey: .reopenDelay) ?? 8
        defaultDataDir = Config.normalize(try c.decodeIfPresent(String.self, forKey: .defaultDataDir) ?? Config.defaultDataDir)
    }

    public func profile(_ id: Int) -> Profile? { profiles.first { $0.id == id } }

    /// The default profile is the one Claude uses when started with no arguments.
    public func isDefault(_ p: Profile) -> Bool { p.dataDir == defaultDataDir }

    /// The next profile after `id`, wrapping around. Nil when there is only one.
    public func other(than id: Int) -> Profile? {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return profiles[(i + 1) % profiles.count]
    }
}

// MARK: - State

public struct FolderManifest: Codable, Equatable {
    public var ids: [String]
    public var syncedAt: Double
    public init(ids: [String], syncedAt: Double) { self.ids = ids; self.syncedAt = syncedAt }
}

public struct LimitMark: Codable, Equatable {
    public var until: Double
    public var kind: String
    public var at: Double
    public init(until: Double, kind: String, at: Double) { self.until = until; self.kind = kind; self.at = at }
}

public struct Identity: Codable, Equatable {
    public var account: String
    public var org: String?
    public var email: String?
    public var at: Double
    public init(account: String, org: String?, email: String?, at: Double) {
        self.account = account; self.org = org; self.email = email; self.at = at
    }
}

public struct SwitchRecord: Codable, Equatable {
    public var at: Double
    public var from: Int?
    public var to: Int
    public var reason: String
    public init(at: Double, from: Int?, to: Int, reason: String) {
        self.at = at; self.from = from; self.to = to; self.reason = reason
    }
}

public struct State: Codable, Equatable {
    /// Session ids each replica folder held after the last sync, keyed by folder path.
    public var manifest: [String: FolderManifest] = [:]
    /// Usage-limit marks keyed by profile id.
    public var limits: [String: LimitMark] = [:]
    /// Who was last seen signed in to each profile, keyed by profile id.
    public var identities: [String: Identity] = [:]
    public var lastSwitch: SwitchRecord?
    /// Profile whose first sign-in is in progress (one automatic restart is allowed).
    public var setupProfile: Int?
    public var initialBackupDone = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try c.decodeIfPresent([String: FolderManifest].self, forKey: .manifest) ?? [:]
        limits = try c.decodeIfPresent([String: LimitMark].self, forKey: .limits) ?? [:]
        identities = try c.decodeIfPresent([String: Identity].self, forKey: .identities) ?? [:]
        lastSwitch = try c.decodeIfPresent(SwitchRecord.self, forKey: .lastSwitch)
        setupProfile = try c.decodeIfPresent(Int.self, forKey: .setupProfile)
        initialBackupDone = try c.decodeIfPresent(Bool.self, forKey: .initialBackupDone) ?? false
    }
}

// MARK: - Errors

public enum SwitchError: Error, CustomStringConvertible, Equatable {
    case busy
    case unknownProfile(Int)
    case quitTimeout
    case launchFailed(String)
    case io(String)

    public var description: String {
        switch self {
        case .busy: return "Another switch is already in progress."
        case .unknownProfile(let id): return "There is no profile \(id)."
        case .quitTimeout: return "Claude did not quit in time. Nothing was changed."
        case .launchFailed(let why): return "Claude could not be started: \(why)"
        case .io(let why): return why
        }
    }
}

// MARK: - Store

/// Files the switcher keeps: config, state, pending hook events, backups and a log.
public final class Store {
    public let home: URL

    public init(home: URL? = nil) {
        if let home {
            self.home = home
        } else if let env = ProcessInfo.processInfo.environment["SECONDWIND_HOME"], !env.isEmpty {
            self.home = URL(fileURLWithPath: Config.normalize(env))
        } else {
            self.home = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/AccountSwitcher")
        }
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    public var configURL: URL { home.appendingPathComponent("config.json") }
    public var stateURL: URL { home.appendingPathComponent("state.json") }
    public var eventsDir: URL { home.appendingPathComponent("events") }
    public var backupsDir: URL { home.appendingPathComponent("backups") }
    public var logURL: URL { home.appendingPathComponent("switch.log") }

    public func defaultConfig() -> Config {
        Config(profiles: [
            Profile(id: 1, name: "Account 1", dataDir: Config.defaultDataDir),
            Profile(id: 2, name: "Account 2", dataDir: home.appendingPathComponent("profile-2").path),
        ])
    }

    public func loadConfig() -> Config {
        guard let data = try? Data(contentsOf: configURL) else {
            let c = defaultConfig()
            try? saveConfig(c)
            return c
        }
        // A config that does not parse is left alone; the defaults are used for this run only.
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? defaultConfig()
    }

    public func saveConfig(_ c: Config) throws { try write(c, to: configURL) }

    public func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    public func saveState(_ s: State) throws { try write(s, to: stateURL) }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(value).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Runs `body` while holding an exclusive file lock. With `wait: false` it throws `.busy`
    /// instead of waiting.
    public func withLock<T>(_ name: String, wait: Bool = true, _ body: () throws -> T) throws -> T {
        let fd = open(home.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw SwitchError.io("Cannot open lock file \(name).") }
        defer { close(fd) }
        guard flock(fd, wait ? LOCK_EX : (LOCK_EX | LOCK_NB)) == 0 else { throw SwitchError.busy }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Read-modify-write of the state file under a lock, so the app and the CLI cannot clobber
    /// each other.
    @discardableResult
    public func mutateState<T>(_ body: (inout State) throws -> T) throws -> T {
        try withLock("state.lock") {
            var s = loadState()
            let r = try body(&s)
            try saveState(s)
            return r
        }
    }

    public func log(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + message + "\n"
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
