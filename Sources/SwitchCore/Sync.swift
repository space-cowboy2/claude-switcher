import Foundation

public struct SyncReport: Codable, Equatable, CustomStringConvertible {
    /// Replica folders taking part.
    public var folders = 0
    /// Folders created so every profile has every account folder.
    public var created = 0
    /// Record files written.
    public var copied = 0
    /// Sessions removed everywhere because they were deleted in one place.
    public var deleted = 0
    /// Deletions not propagated (the session was used elsewhere, or the safety valve tripped).
    public var kept = 0
    public var warnings: [String] = []

    public init() {}

    public var description: String {
        "folders=\(folders) created=\(created) copied=\(copied) deleted=\(deleted) kept=\(kept)"
            + (warnings.isEmpty ? "" : " warnings=\(warnings)")
    }
}

/// Keeps one Code-session list across accounts and profiles.
///
/// The app stores sessions as `claude-code-sessions/<account>/<org>/local_<id>.json` and opens that
/// folder with O_NOFOLLOW, so the folders cannot be symlinked together. A record carries no account
/// id, so a copy in another account's folder is that account's session too. This type copies records
/// between every `<account>/<org>` folder of every profile. It must only run while Claude is closed.
public enum SessionSync {
    public static let storeName = "claude-code-sessions"
    static let mtimeTolerance = 0.01
    static let modifiedSlack = 2.0

    struct Rec {
        let id: String
        let url: URL
        let mtime: Double
    }

    static func isUUID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                options: .regularExpression) != nil
    }

    /// File type from lstat (symlinks are not followed). Nil when nothing is there.
    static func kind(_ url: URL) -> mode_t? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? (st.st_mode & S_IFMT) : nil
    }

    public static func root(_ p: Profile) -> URL {
        URL(fileURLWithPath: p.dataDir).appendingPathComponent(storeName)
    }

    /// The `<account>/<org>` pairs that exist as real directories in a profile.
    public static func pairs(in p: Profile) -> [String] {
        let fm = FileManager.default
        let r = root(p)
        var out: [String] = []
        for a in (try? fm.contentsOfDirectory(atPath: r.path)) ?? [] {
            let aURL = r.appendingPathComponent(a)
            guard isUUID(a), kind(aURL) == S_IFDIR else { continue }
            for b in (try? fm.contentsOfDirectory(atPath: aURL.path)) ?? [] {
                guard isUUID(b), kind(aURL.appendingPathComponent(b)) == S_IFDIR else { continue }
                out.append(a + "/" + b)
            }
        }
        return out.sorted()
    }

    /// Every replica folder path that currently exists, across profiles.
    public static func existingFolders(profiles: [Profile]) -> [String] {
        profiles.flatMap { p in pairs(in: p).map { root(p).appendingPathComponent($0).path } }
    }

    static func records(in folder: URL) -> [String: Rec] {
        var out: [String: Rec] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("local_") && name.hasSuffix(".json") {
            let url = folder.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            let id = String(name.dropLast(5))
            out[id] = Rec(id: id, url: url, mtime: mtime)
        }
        return out
    }

    /// Atomic copy that keeps the source's modification time, so replicas compare equal afterwards.
    static func copy(_ src: Rec, to folder: URL) throws {
        let name = src.url.lastPathComponent
        let tmp = folder.appendingPathComponent(".swsync-" + name + ".tmp")
        let dst = folder.appendingPathComponent(name)
        let data = try Data(contentsOf: src.url)
        try? FileManager.default.removeItem(at: tmp)
        guard FileManager.default.createFile(atPath: tmp.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw SwitchError.io("Cannot write \(tmp.path)")
        }
        let whole = floor(src.mtime)
        let tv = timeval(tv_sec: Int(whole), tv_usec: Int32((src.mtime - whole) * 1_000_000))
        var times = [tv, tv]
        utimes(tmp.path, &times)
        guard rename(tmp.path, dst.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SwitchError.io("Cannot replace \(dst.path)")
        }
    }

    /// Brings every replica folder to the same set of session records.
    ///
    /// - Newest copy of a session wins.
    /// - A session that a folder held at the last sync and no longer holds was deleted there; it is
    ///   removed everywhere unless another copy changed since (then it is restored).
    /// - Safety: a folder that lost all of its records, or a sync that would delete more than half
    ///   of the list, is treated as an accident and nothing is deleted.
    public static func sync(profiles: [Profile], state: inout State, backups: URL, now: Date) throws -> SyncReport {
        let fm = FileManager.default
        var report = SyncReport()

        var allPairs = Set<String>()
        for p in profiles { allPairs.formUnion(pairs(in: p)) }
        guard !allPairs.isEmpty else { return report }

        // Every profile gets every account folder.
        var folders: [URL] = []
        var fresh = Set<String>()
        for p in profiles {
            for pair in allPairs.sorted() {
                let f = root(p).appendingPathComponent(pair)
                switch kind(f) {
                case .some(S_IFDIR):
                    break
                case .none:
                    try fm.createDirectory(at: f, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
                    report.created += 1
                    fresh.insert(f.path)
                default:
                    report.warnings.append("skipped \(f.path): not a plain folder")
                    continue
                }
                folders.append(f)
            }
        }

        var present: [String: [String: Rec]] = [:]
        for f in folders { present[f.path] = records(in: f) }

        if !state.initialBackupDone {
            let dest = backups.appendingPathComponent("initial-\(Int(now.timeIntervalSince1970))")
            for (i, f) in folders.enumerated() {
                guard let recs = present[f.path], !recs.isEmpty else { continue }
                let d = dest.appendingPathComponent("folder-\(i)")
                try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? Data(f.path.utf8).write(to: d.appendingPathComponent("ORIGIN.txt"))
                for r in recs.values {
                    try? fm.copyItem(at: r.url, to: d.appendingPathComponent(r.url.lastPathComponent))
                }
            }
            state.initialBackupDone = true
        }

        // Which sessions were deleted, and where.
        var deletedIn: [String: [URL]] = [:]
        for f in folders {
            guard let m = state.manifest[f.path], !fresh.contains(f.path), let here = present[f.path] else { continue }
            if here.isEmpty && m.ids.count >= 3 {
                report.warnings.append("\(f.path) lost all \(m.ids.count) sessions; treated as a reset, nothing deleted")
                continue
            }
            for id in m.ids where here[id] == nil { deletedIn[id, default: []].append(f) }
        }

        var ids = Set<String>()
        for m in present.values { ids.formUnion(m.keys) }

        // Decide deletions first so the safety valve can see the total.
        var toDelete: [String] = []
        for id in ids.sorted() where deletedIn[id] != nil {
            let changedElsewhere = folders.contains { f in
                guard let r = present[f.path]?[id] else { return false }
                guard let m = state.manifest[f.path] else { return true }
                return r.mtime > m.syncedAt + modifiedSlack
            }
            if changedElsewhere { report.kept += 1 } else { toDelete.append(id) }
        }
        if toDelete.count > max(5, ids.count / 2) {
            report.warnings.append("refused to delete \(toDelete.count) of \(ids.count) sessions in one sync")
            report.kept += toDelete.count
            toDelete = []
        }

        if !toDelete.isEmpty {
            let bin = backups.appendingPathComponent("deleted")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for id in toDelete {
                var saved = false
                for f in folders {
                    guard let r = present[f.path]?[id] else { continue }
                    if !saved {
                        let keep = bin.appendingPathComponent(r.url.lastPathComponent)
                        try? fm.removeItem(at: keep)
                        saved = (try? fm.copyItem(at: r.url, to: keep)) != nil
                    }
                    try fm.removeItem(at: r.url)
                    present[f.path]?[id] = nil
                }
                ids.remove(id)
                report.deleted += 1
            }
        }

        // Newest copy wins; fill in everywhere it is missing or older.
        for id in ids.sorted() {
            guard let newest = folders.compactMap({ present[$0.path]?[id] }).max(by: { $0.mtime < $1.mtime }) else { continue }
            for f in folders {
                if let r = present[f.path]?[id], r.mtime >= newest.mtime - mtimeTolerance { continue }
                try copy(newest, to: f)
                present[f.path]?[id] = Rec(id: id, url: f.appendingPathComponent(newest.url.lastPathComponent),
                                           mtime: newest.mtime)
                report.copied += 1
            }
        }

        // Tombstones stop the app from re-listing a deleted session's transcript; share them too.
        var tombs: [String: URL] = [:]
        for f in folders {
            for name in (try? fm.contentsOfDirectory(atPath: f.path)) ?? [] where name.hasPrefix("deleted_") {
                let u = f.appendingPathComponent(name)
                if kind(u) == S_IFREG, tombs[name] == nil { tombs[name] = u }
            }
        }
        for (name, src) in tombs {
            for f in folders where kind(f.appendingPathComponent(name)) == nil {
                try? fm.copyItem(at: src, to: f.appendingPathComponent(name))
            }
        }

        let stamp = now.timeIntervalSince1970
        var manifest: [String: FolderManifest] = [:]
        for f in folders {
            manifest[f.path] = FolderManifest(ids: (present[f.path] ?? [:]).keys.sorted(), syncedAt: stamp)
        }
        state.manifest = manifest
        report.folders = folders.count
        return report
    }
}
