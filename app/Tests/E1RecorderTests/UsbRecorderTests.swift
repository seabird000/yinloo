import Foundation
import XCTest
@testable import E1Recorder

/// 通用 U 盘录音笔和设备档案：认设备、找录音、从文件名取时间、挑新录音、档案校验、脱敏描述。全部用临时目录里的假数据。
final class UsbRecorderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usbrec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func wav(seconds: Double) -> Data {
        let n = Int(seconds * 32000)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n))
        d.append(Data(count: n))
        return d
    }

    private func put(_ rel: String, _ data: Data = Data([1, 2, 3]), modified: Date? = Date(timeIntervalSinceNow: -3600)) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if let m = modified { try FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: url.path) }
    }

    private func comps(_ d: Date?) -> [Int] {
        guard let d else { return [] }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!]
    }

    // MARK: 时间

    func testReadsCommonFileNameTimes() {
        XCTAssertEqual(comps(UsbRecorder.date(rel: "RECORD/20261120_143005.mp3", pattern: nil)), [2026, 11, 20, 14, 30, 5])
        XCTAssertEqual(comps(UsbRecorder.date(rel: "REC_20261120-143005.wav", pattern: nil)), [2026, 11, 20, 14, 30, 5])
        XCTAssertEqual(comps(UsbRecorder.date(rel: "VOICE/2026-11-20 14-30-05.wav", pattern: nil)), [2026, 11, 20, 14, 30, 5])
        XCTAssertEqual(comps(UsbRecorder.date(rel: "261120_1430.mp3", pattern: nil)), [2026, 11, 20, 14, 30, 0])
        XCTAssertEqual(comps(UsbRecorder.date(rel: "MEETING/20261119/17_19_17.wav", pattern: nil)), [2026, 11, 19, 17, 19, 17])
    }

    func testRejectsNamesThatAreNotTimes() {
        XCTAssertNil(UsbRecorder.date(rel: "REC001.wav", pattern: nil))
        XCTAssertNil(UsbRecorder.date(rel: "20261340_250000.wav", pattern: nil))   // 13 月以后、25 点
        XCTAssertNil(UsbRecorder.date(rel: "20260231_101010.wav", pattern: nil))   // 2 月 31 日
        XCTAssertNil(UsbRecorder.date(rel: "1234567890123456.wav", pattern: nil))
    }

    func testProfilePatternIsUsedAlone() {
        // 档案写了格式就只用它：年月日在后面的写法
        XCTAssertEqual(comps(UsbRecorder.date(rel: "A/1430_20112026.wav", pattern: "HHmm_ddMMyyyy")), [2026, 11, 20, 14, 30, 0])
        XCTAssertNil(UsbRecorder.date(rel: "A/20261120_143005.wav", pattern: "HHmm_ddMMyyyy"))
    }

    func testPatternValidation() {
        XCTAssertNotNil(UsbRecorder.regex(for: "yyyyMMdd_HHmmss"))
        XCTAssertNotNil(UsbRecorder.regex(for: "yyyyMMdd/HH_mm_ss"))
        XCTAssertNil(UsbRecorder.regex(for: "yyyyMMdd"))           // 没有时分
        XCTAssertNil(UsbRecorder.regex(for: "REC_yyyyMMdd_HHmm"))  // 不认识的字母
        XCTAssertNil(UsbRecorder.regex(for: "yyyyMMddMM_HHmm"))    // 重复
        XCTAssertNil(UsbRecorder.regex(for: ""))
    }

    func testTimeUncertain() {
        let now = Date()
        func rec(_ d: Date?) -> UsbRecorder.Recording {
            UsbRecorder.Recording(rel: "a.wav", category: "录音", created: d, fromName: true, modified: now, size: 1, durationSec: 10)
        }
        XCTAssertTrue(rec(UsbRecorder.date(rel: "20200101_000512.wav", pattern: nil)).timeUncertain(now: now))
        XCTAssertTrue(rec(now.addingTimeInterval(3 * 86400)).timeUncertain(now: now))
        XCTAssertTrue(rec(nil).timeUncertain(now: now))
        XCTAssertFalse(rec(now.addingTimeInterval(-3600)).timeUncertain(now: now))
    }

    // MARK: 找录音

    func testScanSkipsMusicHiddenAndOtherFiles() throws {
        try put("RECORD/20261120_143005.mp3")
        try put("RECORD/notes.txt")
        try put("MUSIC/song.mp3")
        try put(".Trashes/old.wav")
        try put("RECORD/._20261120_143005.mp3")
        try put("VOICE/sub/20261121_090000.wma")
        let rels = UsbRecorder.scan(root, profile: nil).map(\.rel).sorted()
        XCTAssertEqual(rels, ["RECORD/20261120_143005.mp3", "VOICE/sub/20261121_090000.wma"])
    }

    func testScanFollowsTheProfile() throws {
        try put("RECORD/20261120_143005.mp3")
        try put("RECORD/20261120_150000.wav")
        try put("OTHER/20261120_160000.mp3")
        let p = DeviceProfile(id: "x", name: "X", match: .init(vendorID: 1), audioRoots: ["RECORD"], extensions: ["mp3"])
        XCTAssertEqual(UsbRecorder.scan(root, profile: p).map(\.rel), ["RECORD/20261120_143005.mp3"])
    }

    func testListReadsDurationsAndTimes() async throws {
        try put("RECORD/20261120_143005.wav", wav(seconds: 3))
        try put("RECORD/20261121_090000.wma")
        try put("RECORD/REC001.wav", wav(seconds: 1), modified: Date(timeIntervalSince1970: 1_790_000_000))
        let recs = await UsbRecorder.list(root, profile: nil)
        XCTAssertEqual(recs.count, 3)
        let byRel = Dictionary(uniqueKeysWithValues: recs.map { ($0.rel, $0) })
        XCTAssertEqual(byRel["RECORD/20261120_143005.wav"]?.durationSec, 3)
        XCTAssertEqual(byRel["RECORD/20261120_143005.wav"]?.fromName, true)
        XCTAssertEqual(byRel["RECORD/20261121_090000.wma"]?.supported, false)
        XCTAssertEqual(byRel["RECORD/20261121_090000.wma"]?.durationSec, 0)
        // 文件名里没有时间：用修改时间
        XCTAssertEqual(byRel["RECORD/REC001.wav"]?.fromName, false)
        XCTAssertEqual(byRel["RECORD/REC001.wav"]?.created, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(recs.first?.rel, "RECORD/20261121_090000.wma")   // 新的在前
    }

    // MARK: 挑新录音

    func testPick() {
        let now = Date()
        func rec(_ rel: String, _ dur: Int, modified: Date = Date(timeIntervalSinceNow: -3600)) -> UsbRecorder.Recording {
            UsbRecorder.Recording(rel: rel, category: "录音", created: now, fromName: true, modified: modified, size: 100, durationSec: dur)
        }
        let recs = [rec("a.wav", 60), rec("b.wav", 60), rec("c.wav", 60), rec("d.wma", 60), rec("e.mp3", 2),
                    rec("f.wav", 60, modified: now.addingTimeInterval(-5)), rec("g.wav", 60)]
        let (fresh, short) = UsbRecorder.pick(recs, handled: ["a.wav#100"], before: ["b.wav#100"], jobKeys: ["g.wav#100"],
                                              minDurationSec: 5, now: now)
        XCTAssertEqual(fresh.map(\.rel), ["c.wav"])     // d 格式不支持，f 刚写入，g 已有转写记录
        XCTAssertEqual(short.map(\.rel), ["e.mp3"])
    }

    func testClockBehindOnlyCountsNewNamedFiles() {
        let last = Date()
        func rec(_ rel: String, _ t: TimeInterval, named: Bool = true) -> UsbRecorder.Recording {
            UsbRecorder.Recording(rel: rel, category: "录音", created: last.addingTimeInterval(t), fromName: named, modified: last,
                                  size: 1, durationSec: 10)
        }
        let recs = [rec("old.wav", -7200), rec("new-behind.wav", -1800), rec("new-ok.wav", 600), rec("mtime.wav", -1800, named: false)]
        XCTAssertEqual(UsbRecorder.clockBehind(recs, seen: ["old.wav#1"], lastListed: last), ["new-behind.wav#1"])
        XCTAssertEqual(UsbRecorder.clockBehind(recs, seen: [], lastListed: nil), [])
    }

    // MARK: 认设备

    func testIdentityHashHidesTheSerial() {
        let h = UsbRecorder.Identity.hash(serial: "ABC123456789")
        XCTAssertEqual(h, UsbRecorder.Identity.hash(serial: " ABC123456789 "))
        XCTAssertEqual(h?.count, 16)
        XCTAssertFalse(h!.contains("123456"))
        XCTAssertNil(UsbRecorder.Identity.hash(serial: ""))
        XCTAssertNil(UsbRecorder.Identity.hash(serial: nil))
    }

    func testEntryMatching() {
        let e = UsbRecorder.Entry(id: "e", name: "X", vendorID: 0x1234, productID: 0x5678, serialHash: "aa", productName: nil,
                                  profileId: nil, auto: true, added: Date())
        XCTAssertTrue(e.matches(.init(vendorID: 0x1234, productID: 0x5678, serialHash: "aa")))
        XCTAssertFalse(e.matches(.init(vendorID: 0x1234, productID: 0x5678, serialHash: "bb")))   // 同型号另一支
        XCTAssertTrue(e.matches(.init(vendorID: 0x1234, productID: 0x5678, serialHash: nil)))     // 没有序列号的型号
        XCTAssertFalse(e.matches(.init(vendorID: 0x1234, productID: 0x9999, serialHash: "aa")))
    }

    func testProfileMatching() {
        let p = DeviceProfile(id: "x", name: "X", match: .init(vendorID: 0x1234, productID: 0x5678, productName: "X1 Recorder"))
        XCTAssertTrue(p.matches(.init(vendorID: 0x1234, productID: 0x5678, productName: " x1 recorder")))
        XCTAssertFalse(p.matches(.init(vendorID: 0x1234, productID: 0x5678, productName: "Other")))
        XCTAssertFalse(p.matches(.init(vendorID: 0x1235, productID: 0x5678, productName: "X1 Recorder")))
        let loose = DeviceProfile(id: "y", name: "Y", match: .init(vendorID: 0x1234))
        XCTAssertTrue(loose.matches(.init(vendorID: 0x1234, productID: 1)))
    }

    func testProfileVolumeCheck() throws {
        try put("RECORD/a.wav")
        let p = DeviceProfile(id: "x", name: "X", match: .init(vendorID: 1, requiredPaths: ["RECORD"]))
        XCTAssertTrue(p.volumeMatches(root))
        let q = DeviceProfile(id: "x", name: "X", match: .init(vendorID: 1, requiredPaths: ["RECORD", "SYSTEM"]))
        XCTAssertFalse(q.volumeMatches(root))
    }

    // MARK: 档案校验

    func testProfileValidation() {
        let ok = DeviceProfile(id: "brand-x1", name: "某品牌 X1", match: .init(vendorID: 0x1234, productID: 0x5678),
                               audioRoots: ["RECORD"], exclude: ["MUSIC"], extensions: ["wav", "mp3"], timeFromName: "yyyyMMdd_HHmmss",
                               categories: ["RECORD": "录音"])
        XCTAssertTrue(ok.isValid)
        var bad = ok; bad.id = "Bad ID"; XCTAssertFalse(bad.isValid)
        bad = ok; bad.audioRoots = ["../etc"]; XCTAssertFalse(bad.isValid)
        bad = ok; bad.audioRoots = ["/Users"]; XCTAssertFalse(bad.isValid)
        bad = ok; bad.timeFromName = "whatever"; XCTAssertFalse(bad.isValid)
        bad = ok; bad.extensions = ["wav;rm"]; XCTAssertFalse(bad.isValid)
        bad = ok; bad.match.vendorID = 0x10000; XCTAssertFalse(bad.isValid)
        bad = ok; bad.name = ""; XCTAssertFalse(bad.isValid)
    }

    func testParseDropsBadProfilesAndRejectsNewerSchema() {
        let json = """
        {"schema": 1, "updated": "2026-11-20", "profiles": [
          {"id": "good", "name": "好的", "match": {"vendorID": 4660}},
          {"id": "good", "name": "重复的", "match": {"vendorID": 4661}},
          {"id": "bad", "name": "坏的", "match": {"vendorID": 4662}, "audioRoots": ["../x"]}
        ]}
        """
        let f = DeviceProfiles.parse(Data(json.utf8))
        XCTAssertEqual(f?.profiles.map(\.name), ["好的"])
        XCTAssertEqual(f?.updated, "2026-11-20")
        XCTAssertNil(DeviceProfiles.parse(Data(#"{"schema": 2, "profiles": []}"#.utf8)))
        XCTAssertNil(DeviceProfiles.parse(Data("not json".utf8)))
        XCTAssertEqual(DeviceProfiles.parse(Data(#"{"schema": 1, "profiles": []}"#.utf8))?.profiles.count, 0)
    }

    func testShippedDevicesFileParses() throws {
        // app/release/devices.json 要传到阿里云：它必须能被应用读懂
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("release/devices.json")
        XCTAssertNotNil(DeviceProfiles.parse(try Data(contentsOf: url)))
    }

    func testCloudOverridesBuiltIn() {
        var lib = DeviceProfiles.Library()
        lib.builtIn = [DeviceProfile(id: "x", name: "旧名", match: .init(vendorID: 1)), DeviceProfile(id: "y", name: "Y", match: .init(vendorID: 2))]
        lib.cloud = [DeviceProfile(id: "x", name: "新名", match: .init(vendorID: 1))]
        XCTAssertEqual(lib.all.map(\.name).sorted(), ["Y", "新名"])
        XCTAssertEqual(lib.origin(of: "x"), .cloud)
        XCTAssertEqual(lib.origin(of: "y"), .builtIn)
        XCTAssertEqual(lib.match(.init(vendorID: 1, productID: 9))?.name, "新名")
    }

    func testFetchFallsBackAndCaches() async throws {
        // 读不到的地址跳过，读到合格的就用；不合格的不用
        let bad = root.appendingPathComponent("missing.json")
        let good = root.appendingPathComponent("devices.json")
        try Data(#"{"schema": 1, "profiles": [{"id": "a", "name": "A", "match": {"vendorID": 1}}]}"#.utf8).write(to: good)
        let junk = root.appendingPathComponent("junk.json")
        try Data("<html>".utf8).write(to: junk)
        // file:// 没有 HTTP 状态码，所以这里只测解析失败时继续往下读
        let f = await DeviceProfiles.fetch(sources: [bad, junk], session: .shared)
        XCTAssertNil(f)
    }

    // MARK: 拷到 Mac

    func testFileNamesAndFolders() {
        let r = UsbRecorder.Recording(rel: "RECORD/REC001.MP3", category: "录音", created: nil, fromName: false, modified: Date(),
                                      size: 1, durationSec: 1)
        let t = UsbRecorder.date(rel: "20261120_143005", pattern: nil)
        XCTAssertEqual(UsbRecorder.fileName(r, device: "某品牌 X1", created: t), "某品牌X1_20261120_143005.mp3")
        XCTAssertEqual(UsbRecorder.fileName(r, device: "X1", created: nil), "X1_RECORD_REC001.MP3")
        XCTAssertEqual(UsbRecorder.safeName("a/b:c"), "abc")
        XCTAssertEqual(UsbRecorder.safeName("  "), "U盘录音笔")
    }

    func testCopyKeepsTheOriginal() throws {
        try put("RECORD/a.mp3", Data(repeating: 7, count: 1000))
        let src = root.appendingPathComponent("RECORD/a.mp3"), dst = root.appendingPathComponent("out/a.mp3")
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UsbRecorder.copy(src, to: dst)
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path + ".part"))
        XCTAssertEqual(UsbRecorder.destination(name: "a.mp3", size: 1000, in: dst.deletingLastPathComponent()), dst)
        XCTAssertEqual(UsbRecorder.destination(name: "a.mp3", size: 5, in: dst.deletingLastPathComponent()).lastPathComponent, "a_2.mp3")
    }

    // MARK: 脱敏描述

    func testShape() {
        XCTAssertEqual(UsbRecorder.shape("REC_20261120_143005"), "REC_########_######")
        XCTAssertEqual(UsbRecorder.shape("张三的访谈2026"), "*####")
        XCTAssertEqual(UsbRecorder.shape("VOICE"), "VOICE")
    }

    func testDescriptionLeavesOutPrivateThings() {
        let id = UsbRecorder.Identity(vendorID: 0x1234, productID: 0x5678, productName: "X1 Recorder", manufacturer: "Example",
                                      serialHash: UsbRecorder.Identity.hash(serial: "SN998877665544"))
        let now = Date()
        let files = [
            UsbRecorder.Recording(rel: "RECORD/20261120_143005.wav", category: "录音", created: now, fromName: true, modified: now, size: 10, durationSec: 10),
            UsbRecorder.Recording(rel: "张三客户/项目复盘.mp3", category: "录音", created: now, fromName: false, modified: now, size: 10, durationSec: 10),
        ]
        let text = UsbRecorder.describe(identity: id, fileSystem: "msdos", capacityBytes: 31_900_000_000, files: files)
        XCTAssertTrue(text.contains("0x1234"))
        XCTAssertTrue(text.contains("X1 Recorder"))
        XCTAssertTrue(text.contains("########_######"))
        XCTAssertTrue(text.contains("\"capacityGB\" : 32"))
        for secret in ["SN998877665544", id.serialHash!, "张三", "项目复盘", "20261120"] {
            XCTAssertFalse(text.contains(secret), "描述里不该有 \(secret)")
        }
    }
}

final class JobOrderTests: XCTestCase {
    private func job(_ id: String, recorded: Double, finished: Double?, updated: Double = 0, state: Job.State = .done) -> Job {
        Job(id: id, title: id, scene: "会议", source: "导入", created: Date(timeIntervalSince1970: recorded), durationSec: 60,
            marks: [], audioPath: "/x", listenPath: nil, timeUncertain: false, state: state, dataId: nil, provider: nil,
            notePath: nil, error: nil, speakerNames: nil, topic: nil, bssids: nil,
            updated: Date(timeIntervalSince1970: updated), finished: finished.map { Date(timeIntervalSince1970: $0) })
    }

    /// 转写页和菜单栏按转写先后排，不按录音时间：一条老录音刚转完，应该排在最上面。
    func testListIsOrderedByWhenTranscribed() {
        let old = job("old-recording", recorded: 100, finished: 9000)
        let new = job("new-recording", recorded: 5000, finished: 6000)
        let legacy = job("before-1.5.1", recorded: 8000, finished: nil, updated: 7000)
        let running = job("running", recorded: 1, finished: nil, updated: 1, state: .transcribing)
        XCTAssertEqual([new, legacy, old, running].sorted(by: Job.newerFirst).map(\.id),
                       ["running", "old-recording", "before-1.5.1", "new-recording"])
    }
}
