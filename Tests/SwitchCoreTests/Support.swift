import Foundation
import XCTest
@testable import SwitchCore

let A1 = "11111111-1111-1111-1111-111111111111"
let B1 = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
let A2 = "22222222-2222-2222-2222-222222222222"
let B2 = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

/// A throwaway world: two profile folders and a switcher home, all under one temp directory.
final class World {
    let base: URL
    let p1: Profile
    let p2: Profile
    let store: Store
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("swtest-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        p1 = Profile(id: 1, name: "Account 1", dataDir: base.appendingPathComponent("p 1").path)
        p2 = Profile(id: 2, name: "Account 2", dataDir: base.appendingPathComponent("p 2").path)
        store = Store(home: base.appendingPathComponent("home"))
        var cfg = Config(appPath: "/Fake/Claude.app", profiles: [p1, p2])
        cfg.defaultDataDir = p1.dataDir
        cfg.quitTimeout = 5
        try! store.saveConfig(cfg)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    var config: Config { store.loadConfig() }
    var backups: URL { store.backupsDir }

    func folder(_ p: Profile, _ a: String = A1, _ b: String = B1) -> URL {
        SessionSync.root(p).appendingPathComponent(a).appendingPathComponent(b)
    }

    @discardableResult
    func makeFolder(_ p: Profile, _ a: String = A1, _ b: String = B1) -> URL {
        let f = folder(p, a, b)
        try! FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    /// Writes a session record with a modification time relative to `now` (negative = before).
    func write(_ id: String, _ text: String, in f: URL, at offset: Double = -100) {
        let url = f.appendingPathComponent(id + ".json")
        try! Data(text.utf8).write(to: url)
        try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(offset)], ofItemAtPath: url.path)
    }

    func read(_ id: String, in f: URL) -> String? {
        (try? Data(contentsOf: f.appendingPathComponent(id + ".json"))).map { String(decoding: $0, as: UTF8.self) }
    }

    func ids(in f: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? [])
            .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Records which session a profile has open, the way the app saves it.
    func open(_ session: String, in p: Profile, asText: Bool = false) {
        try! FileManager.default.createDirectory(atPath: p.dataDir, withIntermediateDirectories: true)
        let panes: [String: Any] = ["state": ["lastPrimaryCodeSession": ["id": session, "type": "local"]], "version": 4]
        let value: Any = asText ? String(decoding: try! JSONSerialization.data(withJSONObject: panes), as: UTF8.self) : panes
        let cfg: [String: Any] = ["preferences": ["epitaxyPrefs": ["desktop-frame.paneStore.v1": value]]]
        try! JSONSerialization.data(withJSONObject: cfg).write(to: URL(fileURLWithPath: p.dataDir + "/claude_desktop_config.json"))
    }

    /// Marks a profile as signed in to an account.
    func signIn(_ p: Profile, account: String) {
        try! FileManager.default.createDirectory(atPath: p.dataDir, withIntermediateDirectories: true)
        try! Data("{\"lastKnownAccountUuid\":\"\(account)\",\"oauth:tokenCache\":\"secret\"}".utf8)
            .write(to: URL(fileURLWithPath: p.dataDir + "/config.json"))
    }

    func sync(_ state: inout State, at offset: Double = 0) throws -> SyncReport {
        try SessionSync.sync(profiles: [p1, p2], state: &state, backups: backups, now: now.addingTimeInterval(offset))
    }
}

/// A scripted stand-in for ps, kill and open, with a clock that only moves when the code sleeps.
final class FakeSystem: System {
    var procs: [ProcInfo] = []
    var clock: Date
    var terminated: [(pid: Int32, force: Bool)] = []
    var launches: [[String]] = []
    var activations = 0
    var openedURLs: [String] = []
    /// Pids that ignore SIGTERM.
    var stubborn = Set<Int32>()
    /// Number of process listings for which the updater stays alive once no app instance is left.
    var updaterPolls = 0
    var slept = 0.0
    /// Keeps the test's temp folders alive for as long as the system is.
    var keep: AnyObject?
    private var nextPid: Int32 = 500
    let exe: String

    init(now: Date, exe: String = "/Fake/Claude.app/Contents/MacOS/Claude") {
        clock = now
        self.exe = exe
    }

    func run(_ dataDir: String?, pid: Int32) {
        procs.append(ProcInfo(pid: pid, command: dataDir.map { exe + " --user-data-dir=" + $0 } ?? exe))
    }

    func processes() -> [ProcInfo] {
        var out = procs
        if updaterPolls > 0, !procs.contains(where: { $0.command.hasPrefix(exe) }) {
            updaterPolls -= 1
            out.append(ProcInfo(pid: 9, command: "/Fake/Claude.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt x"))
        }
        return out
    }

    func terminate(pid: Int32, force: Bool) {
        terminated.append((pid, force))
        if force || !stubborn.contains(pid) { procs.removeAll { $0.pid == pid } }
    }

    func launch(appPath: String, args: [String]) throws {
        launches.append(args)
        nextPid += 1
        procs.append(ProcInfo(pid: nextPid, command: ([exe] + args).joined(separator: " ")))
    }

    func activate(appPath: String) { activations += 1 }
    func openURL(appPath: String, url: String) { openedURLs.append(url) }
    func now() -> Date { clock }
    func sleep(_ seconds: Double) { clock.addTimeInterval(seconds); slept += seconds }
}
