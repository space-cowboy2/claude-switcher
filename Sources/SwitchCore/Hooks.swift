import Foundation

// MARK: - Events written by the hooks

/// A Code session in a profile failed because the account hit a usage limit.
public struct LimitEvent: Codable, Equatable {
    public var at: Double
    public var profileId: Int
    public var account: String?
    /// Desktop session id (`local_…`), used to reopen the session after the switch.
    public var sessionId: String?
    /// When the limit resets, epoch seconds, if the transcript said so.
    public var resetsAt: Double?
    public var limitType: String?
    public var message: String?

    public init(at: Double, profileId: Int, account: String? = nil, sessionId: String? = nil,
                resetsAt: Double? = nil, limitType: String? = nil, message: String? = nil) {
        self.at = at; self.profileId = profileId; self.account = account; self.sessionId = sessionId
        self.resetsAt = resetsAt; self.limitType = limitType; self.message = message
    }
}

/// Which account a profile is signed in to, seen when a session starts.
public struct IdentityEvent: Codable, Equatable {
    public var at: Double
    public var profileId: Int
    public var account: String
    public var org: String?
    public var email: String?
}

// MARK: - Telling a usage limit from a transient error

public struct TranscriptTail: Equatable {
    public var isUsageLimit: Bool
    public var resetsAt: Double?
    public var limitType: String?
}

public enum LimitClassifier {
    /// True for the messages Claude Code shows when a plan's usage limit is reached. A transient
    /// 429 ("not your usage limit") and overload errors are not usage limits.
    public static func isUsageLimit(_ message: String?) -> Bool {
        guard let m = message?.lowercased() else { return false }
        if m.contains("not your usage limit") { return false }
        let patterns = [
            "(hit|reached) your .*limit",
            "out of (extra usage|usage credits)",
            "usage limit reached",
            "hit your .*shared budget",
        ]
        return patterns.contains { m.range(of: $0, options: .regularExpression) != nil }
    }

    /// Looks at the last API error near the end of a transcript. Nil when there is none.
    public static func transcriptTail(path: String?, maxBytes: UInt64 = 400_000) -> TranscriptTail? {
        guard let path, let fh = FileHandle(forReadingAtPath: (path as NSString).expandingTildeInPath) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for line in lines.suffix(30).reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["isApiErrorMessage"] as? Bool == true else { continue }
            let quota = obj["quotaLimits"] as? [String: Any]
            let info = (obj["apiErrorParams"] as? [String: Any])?["rate_limit_info"] as? [String: Any]
            let resets = ((quota?["resetsAt"] ?? info?["resetsAt"]) as? NSNumber)?.doubleValue
            let type = (quota?["rateLimitType"] ?? info?["rateLimitType"]) as? String
            return TranscriptTail(isUsageLimit: obj["apiError"] as? String == "usage_limit_reached",
                                  resetsAt: resets, limitType: type)
        }
        return nil
    }
}

// MARK: - What the hook commands do

/// The hooks run inside a Code session, as children of the app that a switch is about to quit.
/// They only write a small event file; the menu bar app acts on it.
public enum HookRunner {
    /// The profile a session belongs to, from the path of the Claude Code binary the app started
    /// (each profile keeps its own copy under its data folder).
    public static func profile(execPath: String?, config: Config) -> Profile? {
        guard let execPath = execPath.map(Config.normalize) else { return nil }
        return config.profiles
            .filter { execPath.hasPrefix($0.dataDir + "/") }
            .max { $0.dataDir.count < $1.dataDir.count }
    }

    static func write<T: Encodable>(_ event: T, name: String, store: Store) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        let tmp = store.eventsDir.appendingPathComponent("." + name + ".tmp")
        let dst = store.eventsDir.appendingPathComponent(name)
        guard (try? data.write(to: tmp)) != nil else { return }
        if rename(tmp.path, dst.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
    }

    /// `StopFailure` hook: writes a limit event when a desktop session stopped on a usage limit.
    @discardableResult
    public static func stopFailure(input: Data, env: [String: String], store: Store, now: Date = Date()) -> LimitEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              obj["error"] as? String == "rate_limit",
              env["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop",
              let p = profile(execPath: env["CLAUDE_CODE_EXECPATH"], config: store.loadConfig()) else { return nil }
        let message = obj["last_assistant_message"] as? String
        let tail = LimitClassifier.transcriptTail(path: obj["transcript_path"] as? String)
        guard LimitClassifier.isUsageLimit(message) || tail?.isUsageLimit == true else { return nil }
        let event = LimitEvent(at: now.timeIntervalSince1970, profileId: p.id,
                               account: env["CLAUDE_CODE_ACCOUNT_UUID"],
                               sessionId: env["CLAUDE_CODE_HOST_SESSION_ID"],
                               resetsAt: tail?.resetsAt, limitType: tail?.limitType,
                               message: message.map { String($0.prefix(200)) })
        write(event, name: "limit-\(Int(now.timeIntervalSince1970 * 1000))-\(getpid()).json", store: store)
        return event
    }

    /// `SessionStart` hook: remembers which account a profile is signed in to (for menu labels).
    @discardableResult
    public static func sessionStart(env: [String: String], store: Store, now: Date = Date()) -> IdentityEvent? {
        guard env["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop",
              let account = env["CLAUDE_CODE_ACCOUNT_UUID"], !account.isEmpty,
              let p = profile(execPath: env["CLAUDE_CODE_EXECPATH"], config: store.loadConfig()) else { return nil }
        let event = IdentityEvent(at: now.timeIntervalSince1970, profileId: p.id, account: account,
                                  org: env["CLAUDE_CODE_ORGANIZATION_UUID"], email: env["CLAUDE_CODE_USER_EMAIL"])
        // One file per profile, overwritten, so events cannot pile up while the menu bar app is closed.
        write(event, name: "identity-\(p.id).json", store: store)
        return event
    }
}

// MARK: - Adding the hooks to Claude Code's settings

public enum HookInstaller {
    static func isOurs(_ hook: [String: Any]) -> Bool {
        guard let c = hook["command"] as? String else { return false }
        return c.contains("claude-switch") && c.contains(" hook ")
    }

    /// Returns `settings` with the switcher's hooks added (or removed). Other hooks are untouched,
    /// and applying it twice gives the same result.
    public static func apply(to settings: [String: Any], bin: String, install: Bool) -> [String: Any] {
        var out = settings
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var kept: [[String: Any]] = []
            for var g in groups {
                guard let hs = g["hooks"] as? [[String: Any]] else { kept.append(g); continue }
                let rest = hs.filter { !isOurs($0) }
                if rest.count == hs.count { kept.append(g); continue }
                if !rest.isEmpty { g["hooks"] = rest; kept.append(g) }
            }
            if kept.isEmpty { hooks[event] = nil } else { hooks[event] = kept }
        }
        if install {
            let cmd = bin.contains(" ") ? "\"\(bin)\"" : bin
            var stop = hooks["StopFailure"] as? [[String: Any]] ?? []
            stop.append(["matcher": "rate_limit",
                         "hooks": [["type": "command", "command": cmd + " hook stop-failure", "timeout": 20]]])
            hooks["StopFailure"] = stop
            var start = hooks["SessionStart"] as? [[String: Any]] ?? []
            start.append(["hooks": [["type": "command", "command": cmd + " hook session-start", "timeout": 10,
                                     "async": true]]])
            hooks["SessionStart"] = start
        }
        if hooks.isEmpty { out["hooks"] = nil } else { out["hooks"] = hooks }
        return out
    }

    /// Updates a settings file in place. Returns the backup's URL, or nil when nothing changed.
    @discardableResult
    public static func update(file: URL, bin: String, install: Bool, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        var original: Data?
        if fm.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwitchError.io("\(file.path) is not a JSON object; left untouched.")
            }
            settings = obj
            original = data
        }
        let updated = apply(to: settings, bin: bin, install: install)
        if NSDictionary(dictionary: updated).isEqual(to: settings) { return nil }
        var backup: URL?
        if let original {
            let b = file.deletingLastPathComponent()
                .appendingPathComponent(file.lastPathComponent + ".bak-claude-switch-\(Int(now.timeIntervalSince1970))")
            try original.write(to: b)
            backup = b
        }
        let data = try original.flatMap { splice($0, hooks: updated["hooks"] as? [String: Any], expecting: updated) }
            ?? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
        return backup ?? file
    }

    // MARK: Editing only the "hooks" value, so the rest of the file keeps its order and layout

    /// Byte range of the value of a top-level key in the text of a JSON object.
    static func topLevelValueRange(of key: String, in t: [UInt8]) -> Range<Int>? {
        let n = t.count
        func skipSpace(_ j: Int) -> Int {
            var j = j
            while j < n, t[j] == 0x20 || t[j] == 0x0A || t[j] == 0x0D || t[j] == 0x09 { j += 1 }
            return j
        }
        func stringEnd(_ start: Int) -> Int? {
            var j = start + 1
            while j < n {
                if t[j] == 0x5C { j += 2; continue }
                if t[j] == 0x22 { return j + 1 }
                j += 1
            }
            return nil
        }
        func valueEnd(_ start: Int) -> Int? {
            if t[start] == 0x22 { return stringEnd(start) }
            if t[start] == 0x7B || t[start] == 0x5B {
                var depth = 0, k = start
                while k < n {
                    let c = t[k]
                    if c == 0x22 {
                        guard let e = stringEnd(k) else { return nil }
                        k = e
                        continue
                    }
                    if c == 0x7B || c == 0x5B { depth += 1 }
                    if c == 0x7D || c == 0x5D {
                        depth -= 1
                        if depth == 0 { return k + 1 }
                    }
                    k += 1
                }
                return nil
            }
            var k = start
            while k < n, t[k] != 0x2C, t[k] != 0x7D, skipSpace(k) == k { k += 1 }
            return k
        }
        var i = skipSpace(0)
        guard i < n, t[i] == 0x7B else { return nil }
        i += 1
        while true {
            i = skipSpace(i)
            guard i < n, t[i] == 0x22, let keyEnd = stringEnd(i) else { return nil }
            let name = String(decoding: t[(i + 1)..<(keyEnd - 1)], as: UTF8.self)
            i = skipSpace(keyEnd)
            guard i < n, t[i] == 0x3A else { return nil }
            i = skipSpace(i + 1)
            guard i < n, let end = valueEnd(i) else { return nil }
            if name == key { return i..<end }
            i = skipSpace(end)
            guard i < n, t[i] == 0x2C else { return nil }
            i += 1
        }
    }

    /// The original text with only the top-level "hooks" value replaced (or added). Nil when that
    /// cannot be done safely; the caller then rewrites the whole file.
    static func splice(_ original: Data, hooks: [String: Any]?, expecting: [String: Any]) -> Data? {
        var bytes = [UInt8](original)
        var value = "{}"
        if let hooks, !hooks.isEmpty {
            guard let d = try? JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
            // Match the usual `"key": value` style and the two-space indent of the block it sits in.
            value = String(decoding: d, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map { line in
                line.replacingOccurrences(of: #"^(\s*"[^"]*") : "#, with: "$1: ", options: .regularExpression)
            }.joined(separator: "\n  ")
        }
        if let r = topLevelValueRange(of: "hooks", in: bytes) {
            bytes.replaceSubrange(r, with: Array(value.utf8))
        } else if let open = bytes.firstIndex(of: 0x7B) {
            let rest = bytes[(open + 1)...].first { $0 != 0x20 && $0 != 0x0A && $0 != 0x0D && $0 != 0x09 }
            let entry = "\n  \"hooks\": " + value + (rest == 0x7D ? "\n" : ",")
            bytes.insert(contentsOf: Array(entry.utf8), at: open + 1)
        } else {
            return nil
        }
        // Accept the edit only if it parses to exactly what was intended.
        let data = Data(bytes)
        var want = expecting
        if want["hooks"] == nil { want["hooks"] = [String: Any]() }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NSDictionary(dictionary: parsed).isEqual(to: want) else { return nil }
        return data
    }
}
