import Foundation
import SQLite3
import XCTest
@testable import E1Recorder

/// Finding new Voice Memos recordings: which to take, which to wait for, and reading Voice Memos' database.
final class VoiceMemosTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func memo(_ file: String, minutesAgo: Double, sec: Int = 600, deleted: Bool = false) -> VoiceMemos.Memo {
        VoiceMemos.Memo(file: file, title: "t", created: now.addingTimeInterval(-minutesAgo * 60), durationSec: sec, deleted: deleted)
    }
    private func settled(_ size: Int64) -> VoiceMemos.FileState { .init(size: size, modified: now.addingTimeInterval(-120)) }

    func testOnlyAfterTheSwitchWasTurnedOn() {
        let since = now.addingTimeInterval(-30 * 60)
        let memos = [memo("old.m4a", minutesAgo: 60), memo("new.m4a", minutesAgo: 10)]
        let files = ["old.m4a": settled(100), "new.m4a": settled(200)]
        let r = VoiceMemos.pick(memos, since: since, handled: [], minDurationSec: 10, files: files,
                                lastSizes: ["old.m4a": 100, "new.m4a": 200], now: now)
        XCTAssertEqual(r.ready.map(\.file), ["new.m4a"])
    }

    func testWaitsUntilTheFileStopsGrowing() {
        let since = now.addingTimeInterval(-3600)
        let memos = [memo("a.m4a", minutesAgo: 5)]
        // First sight: remembered, not taken.
        var r = VoiceMemos.pick(memos, since: since, handled: [], minDurationSec: 10, files: ["a.m4a": settled(100)], lastSizes: [:], now: now)
        XCTAssertTrue(r.ready.isEmpty)
        XCTAssertEqual(r.settling, ["a.m4a": 100])
        // Still growing.
        r = VoiceMemos.pick(memos, since: since, handled: [], minDurationSec: 10, files: ["a.m4a": settled(150)], lastSizes: r.settling, now: now)
        XCTAssertTrue(r.ready.isEmpty)
        // Same size, but written to seconds ago.
        let fresh = VoiceMemos.FileState(size: 150, modified: now.addingTimeInterval(-20))
        r = VoiceMemos.pick(memos, since: since, handled: [], minDurationSec: 10, files: ["a.m4a": fresh], lastSizes: r.settling, now: now)
        XCTAssertTrue(r.ready.isEmpty)
        // Settled.
        r = VoiceMemos.pick(memos, since: since, handled: [], minDurationSec: 10, files: ["a.m4a": settled(150)], lastSizes: ["a.m4a": 150], now: now)
        XCTAssertEqual(r.ready.map(\.file), ["a.m4a"])
        XCTAssertTrue(r.settling.isEmpty)
    }

    func testSkipsDeletedHandledShortAndMissing() {
        let since = now.addingTimeInterval(-3600)
        let memos = [memo("deleted.m4a", minutesAgo: 5, deleted: true), memo("done.m4a", minutesAgo: 5),
                     memo("short.m4a", minutesAgo: 5, sec: 3), memo("notyet.m4a", minutesAgo: 5), memo("ok.qta", minutesAgo: 5)]
        let files = ["deleted.m4a": settled(1), "done.m4a": settled(1), "short.m4a": settled(1), "ok.qta": settled(1)]
        let r = VoiceMemos.pick(memos, since: since, handled: ["done.m4a"], minDurationSec: 10, files: files,
                                lastSizes: ["deleted.m4a": 1, "done.m4a": 1, "short.m4a": 1, "ok.qta": 1], now: now)
        XCTAssertEqual(r.ready.map(\.file), ["ok.qta"])
        XCTAssertTrue(r.settling.isEmpty)
    }

    /// A folder laid out like Voice Memos': titles, start times and 最近删除 come from the database.
    func testReadsTitlesAndDeletedFromTheDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmtest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["20261113 101500-AAAA0001.m4a", "20261113 111500-AAAA0002.m4a", "20261113 121500-AAAA0003.qta"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(f))
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("CloudRecordings.db").path, &db), SQLITE_OK)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let sql = """
        CREATE TABLE ZCLOUDRECORDING (Z_PK INTEGER PRIMARY KEY, ZDATE TIMESTAMP, ZDURATION FLOAT, ZEVICTIONDATE TIMESTAMP,
            ZENCRYPTEDTITLE VARCHAR, ZPATH VARCHAR);
        INSERT INTO ZCLOUDRECORDING VALUES (1, 800000000, 61.6, NULL, '周会', '20261113 101500-AAAA0001.m4a');
        INSERT INTO ZCLOUDRECORDING VALUES (2, 800003600, 30, 800004000, '删掉的', '20261113 111500-AAAA0002.m4a');
        INSERT INTO ZCLOUDRECORDING VALUES (3, 800007200, 900, NULL, NULL, '20261113 121500-AAAA0003.qta');
        INSERT INTO ZCLOUDRECORDING VALUES (4, 800009000, 10, NULL, '还没下载', '20261113 123000-AAAA0004.m4a');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let memos = try VoiceMemos.list(dir).sorted { $0.created < $1.created }
        XCTAssertEqual(memos.map(\.file), ["20261113 101500-AAAA0001.m4a", "20261113 111500-AAAA0002.m4a", "20261113 121500-AAAA0003.qta"])
        XCTAssertEqual(memos[0].title, "周会")
        XCTAssertEqual(memos[0].created, start)
        XCTAssertEqual(memos[0].durationSec, 62)
        XCTAssertFalse(memos[0].deleted)
        XCTAssertTrue(memos[1].deleted)
        XCTAssertEqual(memos[2].title, "")
    }

    func testWithoutADatabaseFallsBackToTheFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmtest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.m4a"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("a-track1.waveform"))
        let memos = try VoiceMemos.list(dir)
        XCTAssertEqual(memos.map(\.file), ["a.m4a"])
        XCTAssertEqual(memos[0].durationSec, -1)   // unknown: measured after copying
    }

    func testMissingFolderIsNotFound() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vmtest-missing-" + UUID().uuidString)
        XCTAssertThrowsError(try VoiceMemos.list(dir)) { XCTAssertEqual($0 as? VoiceMemos.Problem, .notFound) }
    }
}
