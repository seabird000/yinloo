import AVFoundation
import Foundation
import SQLite3

/// Apple's Voice Memos on this Mac: recordings made here, and those made on iPhone that iCloud has synced here.
/// Strictly read-only — the app copies Voice Memos' database to a temporary folder before reading it and never
/// writes, renames or deletes anything in Voice Memos' own folder.
enum VoiceMemos {
    /// Where Voice Memos keeps its recordings (macOS 14 and later). Not documented by Apple, so it may move.
    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
    }

    struct Memo: Equatable {
        let file: String          // file name inside the Recordings folder; unique, never reused
        let title: String         // as shown in Voice Memos ("" when unknown)
        let created: Date         // when the recording started
        let durationSec: Int
        let deleted: Bool         // in 「最近删除」
    }

    enum Problem: Error, Equatable {
        case noAccess             // macOS privacy protection: needs 完全磁盘访问权限
        case notFound             // Voice Memos has never stored a recording on this Mac
        case unreadable(String)
    }

    static let audioExtensions: Set<String> = ["m4a", "qta"]

    /// Changes whenever a recording is added, removed, renamed or finishes syncing; used to skip idle rounds.
    static func signature(_ dir: URL = folder) -> String? {
        let fm = FileManager.default
        var parts: [String] = []
        for name in ["", "CloudRecordings.db", "CloudRecordings.db-wal"] {
            let p = name.isEmpty ? dir.path : dir.appendingPathComponent(name).path
            guard let a = try? fm.attributesOfItem(atPath: p) else { return nil }
            let mod = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("\(mod)/\((a[.size] as? NSNumber)?.int64Value ?? 0)")
        }
        return parts.joined(separator: "|")
    }

    /// Every recording Voice Memos lists. Falls back to the audio files alone (no titles, nothing counts as deleted)
    /// if the database can't be read the way this version expects.
    static func list(_ dir: URL = folder) throws -> [Memo] {
        let fm = FileManager.default
        let names: [String]
        do { names = try fm.contentsOfDirectory(atPath: dir.path) } catch { throw classify(error) }
        let audio = names.filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        if let fromDB = try? readDatabase(dir) {
            // Only rows whose audio is really here (an iPhone recording can be listed before it has downloaded).
            let present = Set(audio)
            return fromDB.filter { present.contains($0.file) }
        }
        return audio.compactMap { name in
            guard let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path) else { return nil }
            let created = a[.creationDate] as? Date ?? Date()
            return Memo(file: name, title: "", created: created, durationSec: -1, deleted: false)
        }
    }

    private static func classify(_ error: Error) -> Problem {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoSuchFileError || e.code == NSFileNoSuchFileError) { return .notFound }
        let posix = (e.userInfo[NSUnderlyingErrorKey] as? NSError).map { $0.domain == NSPOSIXErrorDomain ? $0.code : 0 } ?? 0
        if e.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) { return .noAccess }
        return .unreadable(e.localizedDescription)
    }

    /// Reads a private copy of CloudRecordings.db (with its write-ahead log, which holds the newest rows).
    private static func readDatabase(_ dir: URL) throws -> [Memo] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("vm-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        for suffix in ["", "-wal", "-shm"] {
            let src = dir.appendingPathComponent("CloudRecordings.db" + suffix)
            guard fm.fileExists(atPath: src.path) else { if suffix.isEmpty { throw Problem.notFound }; continue }
            try fm.copyItem(at: src, to: tmp.appendingPathComponent("CloudRecordings.db" + suffix))
        }
        var db: OpaquePointer?
        // Our own copy, opened read-write so SQLite can replay the log into it.
        guard sqlite3_open_v2(tmp.appendingPathComponent("CloudRecordings.db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db); throw Problem.unreadable("打不开语音备忘录的数据库")
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT ZPATH, ZENCRYPTEDTITLE, ZDATE, ZDURATION, ZEVICTIONDATE IS NOT NULL FROM ZCLOUDRECORDING WHERE ZPATH IS NOT NULL"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw Problem.unreadable("语音备忘录的数据库格式不认识") }
        defer { sqlite3_finalize(st) }
        func text(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
        var out: [Memo] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let file = (text(0) as NSString).lastPathComponent
            guard !file.isEmpty else { continue }
            out.append(Memo(file: file, title: text(1).trimmingCharacters(in: .whitespacesAndNewlines),
                            created: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(st, 2)),
                            durationSec: Int(sqlite3_column_double(st, 3).rounded()), deleted: sqlite3_column_int(st, 4) != 0))
        }
        return out
    }

    /// Size and age of a file, to tell when it has stopped growing.
    struct FileState: Equatable { let size: Int64; let modified: Date }

    /// Which recordings to take this round, and which to look at again next round. A recording qualifies once it was
    /// made after `since`, isn't in 「最近删除」 or already handled, and its file has kept the same size since the
    /// last round and hasn't changed for a minute — until then it is still being recorded, or still arriving from
    /// iPhone. Too-short recordings are left alone.
    static func pick(_ memos: [Memo], since: Date, handled: Set<String>, minDurationSec: Int,
                     files: [String: FileState], lastSizes: [String: Int64], now: Date) -> (ready: [Memo], settling: [String: Int64]) {
        var ready: [Memo] = [], settling: [String: Int64] = [:]
        for m in memos.sorted(by: { $0.created < $1.created })
        where !m.deleted && m.created >= since && !handled.contains(m.file) {
            guard let f = files[m.file] else { continue }
            if lastSizes[m.file] != f.size || now.timeIntervalSince(f.modified) < 60 { settling[m.file] = f.size; continue }
            if m.durationSec >= 0 && m.durationSec < max(1, minDurationSec) { continue }
            ready.append(m)
        }
        return (ready, settling)
    }

    static func fileStates(_ names: [String], in dir: URL = folder) -> [String: FileState] {
        var out: [String: FileState] = [:]
        for n in names {
            guard let a = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path),
                  let size = (a[.size] as? NSNumber)?.int64Value, let mod = a[.modificationDate] as? Date else { continue }
            out[n] = FileState(size: size, modified: mod)
        }
        return out
    }

    /// Length in whole seconds (0 when it can't be read).
    static func duration(of url: URL) async -> Int {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return 0 }
        return Int(CMTimeGetSeconds(d).rounded())
    }

    /// Copies a recording to `dst` (an .m4a). An .m4a is copied as is; an .qta (spatial audio, from newer iPhones)
    /// carries a stereo AAC track next to the spatial one, and that track is copied out without re-encoding.
    static func export(_ file: String, from dir: URL = folder, to dst: URL) async throws {
        let src = dir.appendingPathComponent(file)
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        if (file as NSString).pathExtension.lowercased() != "qta" {
            try fm.copyItem(at: src, to: dst)
            return
        }
        let asset = AVURLAsset(url: src)
        var aac: AVAssetTrack?
        for t in try await asset.loadTracks(withMediaType: .audio) {
            let d = try await t.load(.formatDescriptions)
            if d.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) { aac = t; break }
        }
        guard let aac else { throw AppError("这条语音备忘录的音频格式不认识") }
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError("语音备忘录转换失败")
        }
        try track.insertTimeRange(try await aac.load(.timeRange), of: aac, at: .zero)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw AppError("语音备忘录转换失败") }
        try await ex.export(to: dst, as: .m4a)
    }
}
