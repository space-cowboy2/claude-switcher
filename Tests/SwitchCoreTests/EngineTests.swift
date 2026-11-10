import XCTest
@testable import SwitchCore

final class InstancesTests: XCTestCase {
    func testMapsMainProcessesToProfilesAndIgnoresHelpers() {
        let w = World()
        let exe = "/Fake/Claude.app/Contents/MacOS/Claude"
        let procs = [
            ProcInfo(pid: 1, command: exe),
            ProcInfo(pid: 2, command: exe + " --user-data-dir=" + w.p2.dataDir + " claude://code/continue?session=local_x"),
            ProcInfo(pid: 3, command: exe + " --user-data-dir=/somewhere/else"),
            ProcInfo(pid: 4, command: "/Fake/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=gpu-process --user-data-dir=" + w.p2.dataDir + " --x"),
            ProcInfo(pid: 5, command: w.p1.dataDir + "/claude-code/2.1/claude.app/Contents/MacOS/claude"),
        ]
        let found = Instances.mains(config: w.config, procs: procs)
        XCTAssertEqual(found, [Instance(pid: 1, profileId: 1), Instance(pid: 2, profileId: 2), Instance(pid: 3, profileId: nil)])
        XCTAssertTrue(Instances.dirInUse(w.p2.dataDir, procs: procs))
        XCTAssertFalse(Instances.dirInUse(w.p1.dataDir, procs: procs))
        XCTAssertFalse(Instances.updaterRunning(procs))
    }
}

final class PathTests: XCTestCase {
    func testTempFoldersHaveOneSpelling() {
        XCTAssertEqual(Config.normalize("/private/tmp/nope/x"), "/tmp/nope/x")
        XCTAssertEqual(Config.normalize("/private/var/folders/a/../b"), "/var/folders/b")
        XCTAssertEqual(Config.normalize("/privateer/tmp"), "/privateer/tmp")
        XCTAssertEqual(Config.normalize("~/x"), NSHomeDirectory() + "/x")
    }

    func testProfilesInTempFoldersMatchEitherSpelling() {
        let p = Profile(id: 2, name: "B", dataDir: "/private/tmp/sw/it b")
        var cfg = Config(appPath: "/Fake/Claude.app", profiles: [p])
        cfg.defaultDataDir = "/nowhere"
        XCTAssertEqual(p.dataDir, "/tmp/sw/it b")
        let exe = "/Fake/Claude.app/Contents/MacOS/Claude"
        for dir in ["/tmp/sw/it b", "/private/tmp/sw/it b"] {
            let procs = [ProcInfo(pid: 1, command: exe + " --user-data-dir=" + dir + " claude://x")]
            XCTAssertEqual(Instances.mains(config: cfg, procs: procs), [Instance(pid: 1, profileId: 2)], dir)
            XCTAssertTrue(Instances.dirInUse(p.dataDir, procs: [ProcInfo(pid: 3, command: "helper --user-data-dir=" + dir + " --x")]))
            XCTAssertEqual(HookRunner.profile(execPath: dir + "/claude-code/1/claude", config: cfg)?.id, 2)
        }
    }
}

final class EngineTests: XCTestCase {
    private func make() -> (World, FakeSystem, Engine) {
        let w = World()
        let sys = FakeSystem(now: w.now)
        sys.keep = w
        return (w, sys, Engine(store: w.store, system: sys))
    }

    func testSwitchQuitsSyncsThenLaunchesTheOtherProfileOnTheSameSession() throws {
        let (w, sys, engine) = make()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        sys.run(nil, pid: 10)

        let r = try engine.switchTo(reason: "manual", sessionId: "local_abc-123")

        XCTAssertEqual(r.from, 1)
        XCTAssertEqual(r.to, 2)
        XCTAssertTrue(r.launched)
        XCTAssertEqual(sys.terminated.map(\.pid), [10])
        XCTAssertEqual(sys.terminated.map(\.force), [false])
        XCTAssertEqual(sys.launches, [["--user-data-dir=" + w.p2.dataDir, "claude://code/continue?session=local_abc-123"]])
        XCTAssertEqual(w.ids(in: w.folder(w.p2)), ["local_s1"], "sessions were synced before launch")
        XCTAssertEqual(w.store.loadState().lastSwitch?.to, 2)
        XCTAssertEqual(engine.instances(w.config), [Instance(pid: 501, profileId: 2)])
    }

    func testSwitchingBackToTheDefaultProfilePassesNoDataDir() throws {
        let (w, sys, engine) = make()
        sys.run(w.p2.dataDir, pid: 10)
        try engine.switchTo(reason: "manual", sessionId: "not a session id")
        XCTAssertEqual(sys.launches, [[]])
    }

    func testGivesUpWhenClaudeWillNotQuit() {
        let (w, sys, engine) = make()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        sys.run(nil, pid: 10)
        sys.stubborn = [10]

        XCTAssertThrowsError(try engine.switchTo(reason: "manual")) { XCTAssertEqual($0 as? SwitchError, .quitTimeout) }
        XCTAssertTrue(sys.launches.isEmpty)
        XCTAssertTrue(w.store.loadState().manifest.isEmpty, "no sync while Claude is still running")
        XCTAssertGreaterThanOrEqual(sys.slept, 5)
    }

    func testForceKillsAfterTheTimeout() throws {
        let (_, sys, engine) = make()
        sys.run(nil, pid: 10)
        sys.stubborn = [10]
        try engine.switchTo(reason: "manual", force: true)
        XCTAssertEqual(sys.terminated.map(\.force), [false, true])
        XCTAssertEqual(sys.launches.count, 1)
    }

    func testAlreadyOnTheTargetOnlyActivates() throws {
        let (w, sys, engine) = make()
        sys.run(w.p2.dataDir, pid: 10)
        let r = try engine.switchTo(2, reason: "manual")
        XCTAssertFalse(r.launched)
        XCTAssertTrue(sys.terminated.isEmpty)
        XCTAssertTrue(sys.launches.isEmpty)
        XCTAssertEqual(sys.activations, 1)
    }

    func testRestartRelaunchesTheSameProfile() throws {
        let (w, sys, engine) = make()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        sys.run(w.p2.dataDir, pid: 10)
        try w.store.mutateState { $0.setupProfile = 2 }

        try engine.switchTo(2, reason: "reseed", restart: true)

        XCTAssertEqual(sys.terminated.map(\.pid), [10])
        XCTAssertEqual(sys.launches, [["--user-data-dir=" + w.p2.dataDir]])
        XCTAssertNil(w.store.loadState().setupProfile)
    }

    func testWaitsForAPendingUpdateBeforeLaunching() throws {
        let (_, sys, engine) = make()
        sys.run(nil, pid: 10)
        sys.updaterPolls = 6
        try engine.switchTo(reason: "manual")
        XCTAssertEqual(sys.updaterPolls, 0, "kept polling until the updater was gone")
        XCTAssertEqual(sys.launches.count, 1)
    }

    func testDoesNotWaitForTheUpdaterWhileAnotherInstanceIsOpen() throws {
        let (_, sys, engine) = make()
        sys.run(nil, pid: 10)
        sys.run("/somewhere/else", pid: 11)
        sys.updaterPolls = 1000
        try engine.switchTo(reason: "manual")
        XCTAssertEqual(sys.terminated.map(\.pid), [10], "an instance outside the configured profiles is left alone")
        XCTAssertEqual(sys.launches.count, 1)
    }

    func testAFailedSyncStillOpensClaude() throws {
        let (w, sys, engine) = make()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        try Data("in the way".utf8).write(to: URL(fileURLWithPath: w.p2.dataDir))
        sys.run(nil, pid: 10)

        let r = try engine.switchTo(reason: "manual")

        XCTAssertNil(r.report)
        XCTAssertEqual(sys.launches.count, 1)
        XCTAssertTrue(try String(contentsOf: w.store.logURL).contains("session sync failed"))
    }

    func testSetupMarksTheProfileUntilTheNextSwitchAway() throws {
        let (w, sys, engine) = make()
        sys.run(nil, pid: 10)
        try engine.switchTo(2, reason: "setup")
        XCTAssertEqual(w.store.loadState().setupProfile, 2)
        try engine.switchTo(1, reason: "manual")
        XCTAssertNil(w.store.loadState().setupProfile)
    }

    func testIdleSyncOnlyRunsWhenClaudeIsClosed() {
        let (w, sys, engine) = make()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        sys.run(nil, pid: 10)
        XCTAssertNil(engine.syncIfIdle())
        sys.procs = []
        XCTAssertEqual(engine.syncIfIdle()?.copied, 1)
    }

    func testStatusAndMenu() throws {
        let (w, sys, engine) = make()
        w.signIn(w.p1, account: A1)
        sys.run(nil, pid: 10)
        try Data("{\"version\":2,\"samples\":[{\"t\":\(Int(w.now.timeIntervalSince1970 * 1000) - 60000),\"org\":\"\(B1)\",\"u\":{\"fh\":41.6,\"sd\":12}}]}".utf8)
            .write(to: URL(fileURLWithPath: w.p1.dataDir + "/plan-usage-history.json"))
        try w.store.mutateState {
            $0.identities["1"] = Identity(account: A1, org: B1, email: "me@example.com", at: 0)
            $0.limits["2"] = LimitMark(until: w.now.timeIntervalSince1970 + 600, kind: "five_hour", at: 0)
        }

        let s = engine.status()
        XCTAssertEqual(s.title, "1")
        XCTAssertEqual(s.profiles.map(\.ready), [true, false])
        XCTAssertEqual(s.profiles[0].email, "me@example.com")

        let rows = MenuModel.rows(s, now: w.now)
        XCTAssertEqual(rows[1].title, "Account 1 · me@example.com")
        XCTAssertEqual(rows[1].subtitle, "Active · 5-hour 42% · weekly 12%")
        XCTAssertTrue(rows[1].checked)
        XCTAssertEqual(rows[2].title, "Set up Account 2…")
        XCTAssertEqual(rows[2].kind, .account(2))
        let sw = rows.first { $0.kind == .action("switch:2") }
        XCTAssertEqual(sw?.title, "Switch to Account 2")
        XCTAssertEqual(sw?.enabled, false, "cannot switch to a profile that never signed in")
        XCTAssertTrue(rows.contains { $0.kind == .toggle("auto") && $0.checked })

        w.signIn(w.p2, account: A2)
        let ready = MenuModel.rows(engine.status(), now: w.now)
        XCTAssertEqual(ready[2].title, "Account 2")
        XCTAssertTrue(ready[2].subtitle?.hasPrefix("Limit reached · resets ") ?? false)
        XCTAssertEqual(ready.first { $0.kind == .action("switch:2") }?.enabled, true)
    }

    func testANewAccountFolderInTheRunningProfileAsksForARestart() throws {
        let (w, sys, engine) = make()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        _ = engine.syncIfIdle()
        sys.run(w.p2.dataDir, pid: 10)
        XCTAssertNil(engine.status().needsRestart)
        w.makeFolder(w.p2, A2, B2)
        XCTAssertEqual(engine.status().needsRestart, 2)
    }
}

final class LimitDecisionTests: XCTestCase {
    private func decide(_ w: World, event: LimitEvent? = nil, state: State = State(), running: [Int] = [1],
                        ready: Bool = true, accounts: [Int: String] = [1: A1, 2: A2],
                        edit: (inout Config) -> Void = { _ in }) -> LimitDecision {
        var cfg = w.config
        edit(&cfg)
        let e = event ?? LimitEvent(at: w.now.timeIntervalSince1970 - 5, profileId: 1)
        return Engine.decide(event: e, config: cfg, state: state, running: running,
                             ready: { _ in ready }, account: { accounts[$0.id] }, now: w.now)
    }

    func testSwitchesWhenEverythingAllowsIt() {
        XCTAssertEqual(decide(World()), .switchTo(2))
    }

    func testEveryReasonNotToSwitch() {
        let w = World()
        let t = w.now.timeIntervalSince1970
        func skipped(_ d: LimitDecision, notify: Bool, _ line: UInt = #line) {
            guard case .skip(_, let n) = d else { return XCTFail("expected a skip, got \(d)", line: line) }
            XCTAssertEqual(n, notify, line: line)
        }
        skipped(decide(w, edit: { $0.autoSwitch = false }), notify: false)
        skipped(decide(w, event: LimitEvent(at: t - 600, profileId: 1)), notify: false)
        skipped(decide(w, event: LimitEvent(at: t - 5, profileId: 7)), notify: false)
        skipped(decide(w, running: [2]), notify: false)
        skipped(decide(w, running: [1, 2]), notify: false)
        skipped(decide(w, running: []), notify: false)
        var recent = State()
        recent.lastSwitch = SwitchRecord(at: t - 30, from: 2, to: 1, reason: "manual")
        skipped(decide(w, state: recent), notify: false)
        skipped(decide(w, ready: false), notify: true)
        skipped(decide(w, accounts: [1: A1, 2: A1]), notify: true)
        var limited = State()
        limited.limits["2"] = LimitMark(until: t + 60, kind: "five_hour", at: t - 100)
        skipped(decide(w, state: limited), notify: true)
        limited.limits["2"] = LimitMark(until: t - 60, kind: "five_hour", at: t - 9000)
        XCTAssertEqual(decide(w, state: limited), .switchTo(2), "an expired limit mark does not block")
    }
}

final class LimitHandlingTests: XCTestCase {
    func testALimitEventSwitchesAndRecordsTheResetTime() throws {
        let w = World()
        let sys = FakeSystem(now: w.now)
        let engine = Engine(store: w.store, system: sys)
        w.signIn(w.p1, account: A1)
        w.signIn(w.p2, account: A2)
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        sys.run(nil, pid: 10)
        let t = w.now.timeIntervalSince1970
        let event = LimitEvent(at: t - 2, profileId: 1, sessionId: "local_s1", resetsAt: t + 7200, limitType: "five_hour")

        XCTAssertEqual(engine.handle(event), .switched(from: 1, to: 2))
        XCTAssertEqual(sys.launches, [["--user-data-dir=" + w.p2.dataDir, "claude://code/continue?session=local_s1"]])
        XCTAssertEqual(w.store.loadState().limits["1"]?.until, t + 7200)

        // The second account hits its limit a while later: both are limited, so stay put.
        sys.sleep(600)
        let second = LimitEvent(at: sys.now().timeIntervalSince1970 - 1, profileId: 2)
        guard case .skipped(let why, let notify) = engine.handle(second) else { return XCTFail("expected a skip") }
        XCTAssertTrue(notify)
        XCTAssertTrue(why.contains("Both accounts"))
        XCTAssertEqual(sys.launches.count, 1)
        let mark = try XCTUnwrap(w.store.loadState().limits["2"])
        XCTAssertEqual(mark.until, sys.now().timeIntervalSince1970 + 3600, accuracy: 1, "unknown reset time falls back to an hour")
    }

    func testPendingEventsAreReadOnceAndIdentitiesAreRemembered() throws {
        let w = World()
        let engine = Engine(store: w.store, system: FakeSystem(now: w.now))
        let env = ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_ACCOUNT_UUID": A2,
                   "CLAUDE_CODE_ORGANIZATION_UUID": B2, "CLAUDE_CODE_USER_EMAIL": "two@example.com",
                   "CLAUDE_CODE_EXECPATH": w.p2.dataDir + "/claude-code/2.1.0/x/claude.app/Contents/MacOS/claude",
                   "CLAUDE_CODE_HOST_SESSION_ID": "local_s7"]
        XCTAssertNotNil(HookRunner.sessionStart(env: env, store: w.store))
        XCTAssertNotNil(HookRunner.sessionStart(env: env, store: w.store))
        let input = Data(#"{"hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You've hit your 5-hour limit · resets 3:20pm (America/Chicago)"}"#.utf8)
        XCTAssertNotNil(HookRunner.stopFailure(input: input, env: env, store: w.store))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: w.store.eventsDir.path).count, 2)

        let limits = engine.ingestEvents()

        XCTAssertEqual(limits.map(\.profileId), [2])
        XCTAssertEqual(limits.first?.sessionId, "local_s7")
        XCTAssertEqual(w.store.loadState().identities["2"]?.email, "two@example.com")
        XCTAssertTrue(engine.ingestEvents().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: w.store.eventsDir.path).isEmpty)
    }
}
