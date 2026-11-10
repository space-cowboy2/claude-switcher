import XCTest
@testable import SwitchCore

final class SyncTests: XCTestCase {
    func testEveryFolderInEveryProfileGetsEverySession() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1, A1, B1)
        let f2 = w.makeFolder(w.p1, A2, B2)
        w.write("local_s1", "one", in: f1)
        w.write("local_s2", "two", in: f1)
        w.write("local_s3", "three", in: f2)
        var st = State()

        let r = try w.sync(&st)

        XCTAssertEqual(r.folders, 4)
        XCTAssertEqual(r.created, 2, "profile 2 gets both account folders")
        for f in [f1, f2, w.folder(w.p2, A1, B1), w.folder(w.p2, A2, B2)] {
            XCTAssertEqual(w.ids(in: f), ["local_s1", "local_s2", "local_s3"])
        }
        XCTAssertEqual(w.read("local_s3", in: w.folder(w.p2, A1, B1)), "three")
        let copy = w.folder(w.p2, A1, B1).appendingPathComponent("local_s1.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: copy.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attrs[.modificationDate] as! Date).timeIntervalSince1970, w.now.timeIntervalSince1970 - 100, accuracy: 0.01)
        XCTAssertEqual(st.manifest.count, 4)
    }

    func testSecondSyncChangesNothing() throws {
        let w = World()
        w.write("local_s1", "one", in: w.makeFolder(w.p1))
        var st = State()
        _ = try w.sync(&st)
        let r = try w.sync(&st, at: 10)
        XCTAssertEqual(r.copied, 0)
        XCTAssertEqual(r.deleted, 0)
        XCTAssertEqual(r.created, 0)
    }

    func testNewerCopyWinsInBothDirections() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        w.write("local_s1", "old", in: f1)
        w.write("local_s2", "old", in: f1)
        var st = State()
        _ = try w.sync(&st)
        let f2 = w.folder(w.p2)

        w.write("local_s1", "changed in profile 2", in: f2, at: 50)
        w.write("local_s2", "changed in profile 1", in: f1, at: 60)
        w.write("local_s9", "new in profile 2", in: f2, at: 70)
        _ = try w.sync(&st, at: 100)

        XCTAssertEqual(w.read("local_s1", in: f1), "changed in profile 2")
        XCTAssertEqual(w.read("local_s2", in: f2), "changed in profile 1")
        XCTAssertEqual(w.read("local_s9", in: f1), "new in profile 2")
    }

    func testDeletionPropagatesAndKeepsACopy() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        for i in 1...4 { w.write("local_s\(i)", "x\(i)", in: f1) }
        var st = State()
        _ = try w.sync(&st)
        let f2 = w.folder(w.p2)

        try FileManager.default.removeItem(at: f1.appendingPathComponent("local_s2.json"))
        try Data("t".utf8).write(to: f1.appendingPathComponent("deleted_local_s2"))
        let r = try w.sync(&st, at: 100)

        XCTAssertEqual(r.deleted, 1)
        XCTAssertEqual(w.ids(in: f2), ["local_s1", "local_s3", "local_s4"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.backups.appendingPathComponent("deleted/local_s2.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f2.appendingPathComponent("deleted_local_s2").path),
                      "tombstones are shared")
        XCTAssertEqual(try w.sync(&st, at: 200).deleted, 0)
    }

    func testDeletedSessionUsedElsewhereIsRestored() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        for i in 1...4 { w.write("local_s\(i)", "x\(i)", in: f1) }
        var st = State()
        _ = try w.sync(&st)
        let f2 = w.folder(w.p2)

        try FileManager.default.removeItem(at: f1.appendingPathComponent("local_s2.json"))
        w.write("local_s2", "continued in profile 2", in: f2, at: 30)
        let r = try w.sync(&st, at: 100)

        XCTAssertEqual(r.deleted, 0)
        XCTAssertEqual(r.kept, 1)
        XCTAssertEqual(w.read("local_s2", in: f1), "continued in profile 2")
    }

    func testWipedFolderIsRefilledNotMassDeleted() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        for i in 1...4 { w.write("local_s\(i)", "x\(i)", in: f1) }
        var st = State()
        _ = try w.sync(&st)
        let f2 = w.folder(w.p2)

        for id in w.ids(in: f2) { try FileManager.default.removeItem(at: f2.appendingPathComponent(id + ".json")) }
        let r = try w.sync(&st, at: 100)

        XCTAssertEqual(r.deleted, 0)
        XCTAssertFalse(r.warnings.isEmpty)
        XCTAssertEqual(w.ids(in: f1).count, 4)
        XCTAssertEqual(w.ids(in: f2).count, 4)
    }

    func testRemovedProfileFolderIsRecreatedNotMassDeleted() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        for i in 1...4 { w.write("local_s\(i)", "x\(i)", in: f1) }
        var st = State()
        _ = try w.sync(&st)

        try FileManager.default.removeItem(atPath: w.p2.dataDir)
        let r = try w.sync(&st, at: 100)

        XCTAssertEqual(r.deleted, 0)
        XCTAssertEqual(r.created, 1)
        XCTAssertEqual(w.ids(in: f1).count, 4)
        XCTAssertEqual(w.ids(in: w.folder(w.p2)).count, 4)
    }

    func testRefusesToDeleteMostOfTheList() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        for i in 1...12 { w.write("local_s\(i)", "x", in: f1) }
        var st = State()
        _ = try w.sync(&st)

        for i in 1...8 { try FileManager.default.removeItem(at: f1.appendingPathComponent("local_s\(i).json")) }
        let r = try w.sync(&st, at: 100)

        XCTAssertEqual(r.deleted, 0)
        XCTAssertEqual(w.ids(in: f1).count, 12)
        XCTAssertTrue(r.warnings.contains { $0.contains("refused") })
    }

    func testIgnoresSymlinksTempFilesAndOtherFiles() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        w.write("local_s1", "one", in: f1)
        try Data("x".utf8).write(to: f1.appendingPathComponent("local_s2.json.tmp"))
        try Data("x".utf8).write(to: f1.appendingPathComponent("scheduled-tasks.json"))
        try FileManager.default.createSymbolicLink(at: f1.appendingPathComponent("local_s3.json"),
                                                   withDestinationURL: f1.appendingPathComponent("local_s1.json"))
        // A symlinked account folder is not a replica.
        try FileManager.default.createSymbolicLink(
            at: SessionSync.root(w.p1).appendingPathComponent(A2), withDestinationURL: f1.deletingLastPathComponent())
        var st = State()

        let r = try w.sync(&st)

        XCTAssertEqual(r.folders, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: w.folder(w.p2).path), ["local_s1.json"])
    }

    func testFirstSyncBacksUpOnce() throws {
        let w = World()
        let f1 = w.makeFolder(w.p1)
        w.write("local_s1", "one", in: f1)
        var st = State()
        _ = try w.sync(&st)
        _ = try w.sync(&st, at: 50)

        let initial = try FileManager.default.contentsOfDirectory(atPath: w.backups.path).filter { $0.hasPrefix("initial-") }
        XCTAssertEqual(initial.count, 1)
        let dir = w.backups.appendingPathComponent(initial[0]).appendingPathComponent("folder-0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("local_s1.json").path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("ORIGIN.txt")), f1.path)
    }

    func testNothingToDoWithoutAnyAccountFolder() throws {
        let w = World()
        var st = State()
        XCTAssertEqual(try w.sync(&st).folders, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.p2.dataDir))
    }
}
