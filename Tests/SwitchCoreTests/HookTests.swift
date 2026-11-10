import XCTest
@testable import SwitchCore

final class LimitClassifierTests: XCTestCase {
    func testUsageLimitMessages() {
        for m in ["You've hit your 5-hour limit · resets 3:20pm (America/Chicago)",
                  "You've hit your session limit · resets 2:10am (America/Chicago)",
                  "You’ve hit your weekly limit",
                  "You've hit your Opus limit · resets Nov 12, 9am",
                  "You're out of usage credits",
                  "You've reached your monthly spend limit"] {
            XCTAssertTrue(LimitClassifier.isUsageLimit(m), m)
        }
    }

    func testTransientErrorsAreNotUsageLimits() {
        for m in ["API Error: Request rejected (429) Server is temporarily limiting requests (not your usage limit)",
                  "Repeated 529 Overloaded errors",
                  "Opus is experiencing high load, please use /model to switch to Sonnet",
                  "Request timed out", ""] {
            XCTAssertFalse(LimitClassifier.isUsageLimit(m), m)
        }
        XCTAssertFalse(LimitClassifier.isUsageLimit(nil))
    }

    private func transcript(_ lines: [String]) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        try! Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    let limitEntry = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiError":"usage_limit_reached","apiErrorStatus":429,"apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":1800003600,"rateLimitType":"five_hour"}},"quotaLimits":{"status":"rejected","resetsAt":1800003600,"rateLimitType":"five_hour"}}"#
    let transientEntry = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429}"#

    func testTranscriptTailFindsTheLimitAndItsResetTime() {
        let path = transcript([#"{"type":"user","message":"hi"}"#, "not json", limitEntry])
        XCTAssertEqual(LimitClassifier.transcriptTail(path: path),
                       TranscriptTail(isUsageLimit: true, resetsAt: 1_800_003_600, limitType: "five_hour"))
    }

    func testTheLastApiErrorDecides() {
        let path = transcript([limitEntry, #"{"type":"user","message":"again"}"#, transientEntry])
        XCTAssertEqual(LimitClassifier.transcriptTail(path: path)?.isUsageLimit, false)
        XCTAssertNil(LimitClassifier.transcriptTail(path: transcript([#"{"type":"user"}"#])))
        XCTAssertNil(LimitClassifier.transcriptTail(path: "/nonexistent/file.jsonl"))
        XCTAssertNil(LimitClassifier.transcriptTail(path: nil))
    }

    func testTailWorksOnALargeTranscript() {
        let filler = Array(repeating: #"{"type":"assistant","message":{"content":"\#(String(repeating: "é", count: 5000))"}}"#, count: 200)
        XCTAssertEqual(LimitClassifier.transcriptTail(path: transcript(filler + [limitEntry]))?.resetsAt, 1_800_003_600)
    }

    private func env(_ w: World, entry: String = "claude-desktop", exec: String? = nil) -> [String: String] {
        ["CLAUDE_CODE_ENTRYPOINT": entry, "CLAUDE_CODE_ACCOUNT_UUID": A1,
         "CLAUDE_CODE_EXECPATH": exec ?? w.p1.dataDir + "/claude-code/2.1.0/x/claude.app/Contents/MacOS/claude",
         "CLAUDE_CODE_HOST_SESSION_ID": "local_s1"]
    }

    func testStopFailureHookWritesAnEventOnlyForADesktopUsageLimit() {
        let w = World()
        func input(_ error: String, message: String? = nil, transcript: String? = nil) -> Data {
            var o: [String: Any] = ["hook_event_name": "StopFailure", "error": error]
            o["last_assistant_message"] = message
            o["transcript_path"] = transcript
            return try! JSONSerialization.data(withJSONObject: o)
        }
        let limit = "You've hit your 5-hour limit · resets 3:20pm (America/Chicago)"

        let e = HookRunner.stopFailure(input: input("rate_limit", message: limit, transcript: transcript([limitEntry])),
                                       env: env(w), store: w.store, now: w.now)
        XCTAssertEqual(e?.profileId, 1)
        XCTAssertEqual(e?.resetsAt, 1_800_003_600)
        XCTAssertEqual(e?.sessionId, "local_s1")

        // The message is optional in the hook payload; the transcript alone is enough.
        XCTAssertNotNil(HookRunner.stopFailure(input: input("rate_limit", transcript: transcript([limitEntry])),
                                               env: env(w), store: w.store))
        XCTAssertNil(HookRunner.stopFailure(input: input("rate_limit", message: "Server is temporarily limiting requests (not your usage limit)", transcript: transcript([transientEntry])), env: env(w), store: w.store))
        XCTAssertNil(HookRunner.stopFailure(input: input("server_error", message: limit), env: env(w), store: w.store))
        XCTAssertNil(HookRunner.stopFailure(input: input("rate_limit", message: limit), env: env(w, entry: "cli"), store: w.store),
                     "a terminal session uses its own login")
        XCTAssertNil(HookRunner.stopFailure(input: input("rate_limit", message: limit),
                                            env: env(w, exec: "/Users/x/.local/bin/claude"), store: w.store))
        XCTAssertNil(HookRunner.stopFailure(input: Data("garbage".utf8), env: env(w), store: w.store))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: w.store.eventsDir.path).count, 2)
    }
}

final class HookInstallerTests: XCTestCase {
    let existing: [String: Any] = [
        "env": ["X": "1"],
        "hooks": [
            "SessionStart": [["matcher": "startup", "hooks": [["type": "command", "command": "/usr/bin/python3 kb.py hook-start", "timeout": 30]]]],
            "SessionEnd": [["hooks": [["type": "command", "command": "/usr/bin/python3 kb.py hook-end"]]]],
        ],
    ]

    func testAddsHooksWithoutTouchingOthersAndIsIdempotent() {
        let once = HookInstaller.apply(to: existing, bin: "/Users/me/.local/bin/secondwind", install: true)
        let twice = HookInstaller.apply(to: once, bin: "/Users/me/.local/bin/secondwind", install: true)
        XCTAssertTrue(NSDictionary(dictionary: once).isEqual(to: twice))

        let hooks = once["hooks"] as! [String: Any]
        let start = hooks["SessionStart"] as! [[String: Any]]
        XCTAssertEqual(start.count, 2)
        XCTAssertEqual(start[0]["matcher"] as? String, "startup")
        let stop = hooks["StopFailure"] as! [[String: Any]]
        XCTAssertEqual(stop[0]["matcher"] as? String, "rate_limit")
        XCTAssertEqual((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String,
                       "/Users/me/.local/bin/secondwind hook stop-failure")
        XCTAssertNotNil(hooks["SessionEnd"])
        XCTAssertNotNil(once["env"])
    }

    func testHooksInstalledUnderTheOldNameAreReplaced() {
        var old = existing
        var hooks = old["hooks"] as! [String: Any]
        hooks["StopFailure"] = [["matcher": "rate_limit", "hooks": [["type": "command", "command": "/Users/me/.local/bin/claude-switch hook stop-failure"]]]]
        var start = hooks["SessionStart"] as! [[String: Any]]
        start.append(["hooks": [["type": "command", "command": "/Users/me/.local/bin/claude-switch hook session-start"]]])
        hooks["SessionStart"] = start
        old["hooks"] = hooks

        let updated = HookInstaller.apply(to: old, bin: "/Users/me/.local/bin/secondwind", install: true)
        let fresh = HookInstaller.apply(to: existing, bin: "/Users/me/.local/bin/secondwind", install: true)

        XCTAssertTrue(NSDictionary(dictionary: updated).isEqual(to: fresh), "same result as a clean install")
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: updated), as: UTF8.self)
        XCTAssertFalse(text.contains("claude-switch"))
        XCTAssertTrue(text.contains("kb.py hook-start"))
    }

    func testUninstallRestoresTheOriginal() {
        let installed = HookInstaller.apply(to: existing, bin: "/a b/secondwind", install: true)
        let removed = HookInstaller.apply(to: installed, bin: "", install: false)
        XCTAssertTrue(NSDictionary(dictionary: removed).isEqual(to: existing))
        XCTAssertNil(HookInstaller.apply(to: HookInstaller.apply(to: [:], bin: "secondwind", install: true),
                                         bin: "", install: false)["hooks"])
    }

    func testOnlyTheHooksValueChangesInARealSettingsFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let before = """
        {
          "model": "opus",
          "env": { "Z": "a \\"quoted\\" } brace", "A": "1" },
          "hooks": {
            "SessionStart": [ { "matcher": "startup", "hooks": [ { "type": "command", "command": "kb.py hook-start" } ] } ]
          },
          "theme": "dark",
          "autoMode": true
        }
        """
        try Data(before.utf8).write(to: file)

        try HookInstaller.update(file: file, bin: "/x/secondwind", install: true)
        let after = try String(contentsOf: file)

        let head = before.components(separatedBy: "\"hooks\"")[0]
        let tail = "  \"theme\": \"dark\",\n  \"autoMode\": true\n}"
        XCTAssertTrue(after.hasPrefix(head), "everything before hooks is byte-for-byte the same")
        XCTAssertTrue(after.hasSuffix(tail), "everything after hooks is byte-for-byte the same")
        XCTAssertTrue(after.contains("/x/secondwind hook stop-failure"))
        XCTAssertTrue(after.contains("kb.py hook-start"))

        try HookInstaller.update(file: file, bin: "", install: false)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let original = try JSONSerialization.jsonObject(with: Data(before.utf8)) as! [String: Any]
        XCTAssertTrue(NSDictionary(dictionary: parsed).isEqual(to: original))

        // No hooks key at all: one is added, the rest stays.
        let bare = dir.appendingPathComponent("bare.json")
        try Data("{\n  \"model\": \"opus\"\n}".utf8).write(to: bare)
        try HookInstaller.update(file: bare, bin: "/x/secondwind", install: true)
        XCTAssertTrue(try String(contentsOf: bare).hasSuffix("\n  \"model\": \"opus\"\n}"))
        let empty = dir.appendingPathComponent("empty.json")
        try Data("{}".utf8).write(to: empty)
        try HookInstaller.update(file: empty, bin: "/x/secondwind", install: true)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: Data(contentsOf: empty)) as? [String: Any])?["hooks"])
    }

    func testUpdatesAFileWithABackupAndLeavesBadFilesAlone() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: existing).write(to: file)

        let backup = try XCTUnwrap(HookInstaller.update(file: file, bin: "/x/secondwind", install: true))
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.json.bak-secondwind-"))
        XCTAssertNil(try HookInstaller.update(file: file, bin: "/x/secondwind", install: true), "second run changes nothing")
        let text = try String(contentsOf: file)
        XCTAssertTrue(text.contains("/x/secondwind hook stop-failure"))
        XCTAssertTrue(text.contains("kb.py hook-start"))

        let bad = dir.appendingPathComponent("bad.json")
        try Data("[1,2]".utf8).write(to: bad)
        XCTAssertThrowsError(try HookInstaller.update(file: bad, bin: "/x/secondwind", install: true))
        XCTAssertEqual(try String(contentsOf: bad), "[1,2]")
    }
}
