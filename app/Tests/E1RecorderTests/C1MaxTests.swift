import Foundation
import XCTest
@testable import E1Recorder

/// 搜狗 C1 Max（U 盘）：认设备、读目录和 WAV 文件头、挑新录音、拷贝时修正录了一半的文件。全部用临时目录里的假数据。
final class C1MaxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("c1max-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 16 kHz、单声道、16 位的 WAV：`seconds` 秒的静音；`declared` 是文件头里写的音频长度（nil = 写对）。
    private func wav(seconds: Double, declared: UInt32? = nil) -> Data {
        let n = Int(seconds * 32000)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let data = declared ?? UInt32(n)
        d.append(contentsOf: Array("RIFF".utf8)); u32(declared == nil ? UInt32(36 + n) : 0)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(data)
        d.append(Data(count: n))
        return d
    }

    private func put(_ rel: String, _ data: Data = Data()) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testRecognizesTheDeviceByUSBNameAndVendor() {
        XCTAssertTrue(C1Max.matches(productName: "C1 Max", vendorID: 0x2207))
        XCTAssertTrue(C1Max.matches(productName: "C1 Max ", vendorID: 0x2207))
        XCTAssertFalse(C1Max.matches(productName: "C1 Max", vendorID: 0x05AC))
        XCTAssertFalse(C1Max.matches(productName: "USB Disk", vendorID: 0x2207))
        XCTAssertFalse(C1Max.matches(productName: nil, vendorID: nil))
    }

    func testDateFromFolderAndFileName() throws {
        let d = try XCTUnwrap(C1Max.date(day: "20261119", file: "17_19_17"))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 11, 19, 17, 19, 17])
        XCTAssertNil(C1Max.date(day: "2026111", file: "17_19_17"))
        XCTAssertNil(C1Max.date(day: "20261119", file: "17-19-17"))
        XCTAssertNil(C1Max.date(day: "20261319", file: "17_19_17"))
        XCTAssertNil(C1Max.date(day: "20261119", file: "25_00_00"))
    }

    func testListsRecordingsFromTheCategoryFolders() throws {
        try put("MEETING/20261119/17_19_17.wav", wav(seconds: 3))
        try put("MEETING/20261119/17_19_17.opus", Data(count: 100))      // 原始录音，不拷
        try put("INTERVIEW/20261118/09_00_00.wav", wav(seconds: 2))
        try put("MUSIC/song.wav", wav(seconds: 1))                        // 放音乐的，不算录音
        try put("MEETING/20261119/._17_19_17.wav", Data(count: 10))       // macOS 留下的隐藏文件
        try put("LOG/app1.log", Data("boot".utf8))

        XCTAssertTrue(C1Max.looksLikeC1Max(root))
        let recs = C1Max.list(root)
        XCTAssertEqual(recs.map(\.rel), ["MEETING/20261119/17_19_17.wav", "INTERVIEW/20261118/09_00_00.wav"])   // 新的在前
        XCTAssertEqual(recs.map(\.category), ["会议", "采访"])
        XCTAssertEqual(recs.map(\.durationSec), [3, 2])
        XCTAssertFalse(recs[0].timeUncertain)
    }

    func testAnyOtherDriveIsNotTakenForAC1Max() throws {
        try put("Photos/a.jpg")
        XCTAssertFalse(C1Max.looksLikeC1Max(root))
        try put("MEETING/.keep")
        XCTAssertFalse(C1Max.looksLikeC1Max(root))   // 还要有 LOG 或 STAT
    }

    func testClockResetMeansTheTimeIsUncertain() throws {
        try put("MEETING/20200101/00_00_10.wav", wav(seconds: 1))
        try put("STAT/20200101.DAT", Data(count: 4))
        let r = try XCTUnwrap(C1Max.list(root).first)
        XCTAssertTrue(r.timeUncertain)
    }

    func testPicksOnlyNewRecordingsLongEnough() {
        func rec(_ rel: String, _ sec: Int) -> C1Max.Recording {
            C1Max.Recording(rel: rel, category: "会议", created: Date(), size: Int64(sec * 32000 + 44), durationSec: sec)
        }
        let before = rec("MEETING/20261118/09_00_00.wav", 600)
        let handled = rec("MEETING/20261118/10_00_00.wav", 600)
        let queued = rec("MEETING/20261118/11_00_00.wav", 600)
        let short = rec("MEETING/20261119/08_00_00.wav", 4)
        let fresh = rec("MEETING/20261119/09_00_00.wav", 600)
        let r = C1Max.pick([fresh, short, queued, handled, before], handled: [handled.key], before: [before.key],
                           jobKeys: [queued.key], minDurationSec: 10)
        XCTAssertEqual(r.new.map(\.rel), [fresh.rel])
        XCTAssertEqual(r.tooShort.map(\.rel), [short.rel])
    }

    func testSamePathWithDifferentContentIsANewRecording() {
        // 时钟回到 2020-01-01 后，笔可能在同一秒又录一条，路径一样、大小不同
        let a = C1Max.Recording(rel: "MEETING/20200101/00_00_10.wav", category: "会议", created: nil, size: 1000, durationSec: 30)
        let b = C1Max.Recording(rel: a.rel, category: "会议", created: nil, size: 2000, durationSec: 60)
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertEqual(C1Max.pick([b], handled: [a.key], before: [], jobKeys: [], minDurationSec: 10).new.count, 1)
    }

    func testClockThatStoppedWhileUnpoweredIsCaught() throws {
        // 笔断电时时钟停走：17:51 录的，笔上记成 17:19:56，而 17:47 读笔时它还不存在
        let lastListed = try XCTUnwrap(C1Max.date(day: "20261119", file: "17_47_50"))
        let old = C1Max.Recording(rel: "MEETING/20261119/17_19_17.wav", category: "会议",
                                  created: C1Max.date(day: "20261119", file: "17_19_17"), size: 1000, durationSec: 33)
        let late = C1Max.Recording(rel: "MEETING/20261119/17_19_56.wav", category: "会议",
                                   created: C1Max.date(day: "20261119", file: "17_19_56"), size: 2000, durationSec: 36)
        let fine = C1Max.Recording(rel: "MEETING/20261119/18_05_00.wav", category: "会议",
                                   created: C1Max.date(day: "20261119", file: "18_05_00"), size: 3000, durationSec: 60)
        XCTAssertEqual(C1Max.clockBehind([fine, late, old], seen: [old.key], lastListed: lastListed), [late.key])
        // 第一次读笔：没有可比的
        XCTAssertTrue(C1Max.clockBehind([late], seen: [], lastListed: nil).isEmpty)
    }

    func testCopyDoesNotOverwriteADifferentFile() throws {
        let dir = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let t = try XCTUnwrap(C1Max.date(day: "20200101", file: "00_00_10"))
        let r = C1Max.Recording(rel: "MEETING/20200101/00_00_10.wav", category: "会议", created: t, size: 500, durationSec: 30)
        let first = C1Max.destination(for: r, in: dir)
        XCTAssertEqual(first.lastPathComponent, "C1Max_20200101_000010.wav")
        try Data(count: 400).write(to: first)            // 另一条录音占了这个名字
        XCTAssertEqual(C1Max.destination(for: r, in: dir).lastPathComponent, "C1Max_20200101_000010_2.wav")
        try Data(count: 500).write(to: first)            // 同样大小：之前拷过的就是它
        XCTAssertEqual(C1Max.destination(for: r, in: dir), first)
    }

    func testHalfWrittenRecordingIsFixedInTheCopyOnly() throws {
        // 笔断电时录到一半：文件头里的长度还是 0
        try put("MEETING/20261119/10_00_00.wav", wav(seconds: 2, declared: 0))
        let src = root.appendingPathComponent("MEETING/20261119/10_00_00.wav")
        let srcBefore = try Data(contentsOf: src)
        let info = try XCTUnwrap(C1Max.WavInfo.read(src))
        XCTAssertTrue(info.needsFix)
        XCTAssertEqual(info.dataSize, 64000)
        XCTAssertEqual(C1Max.list(root).first?.durationSec, 2)

        let dst = root.appendingPathComponent("copy.wav")
        try C1Max.copy(src, to: dst)
        let fixed = try XCTUnwrap(C1Max.WavInfo.read(dst))
        XCTAssertFalse(fixed.needsFix)
        XCTAssertEqual(fixed.declared, 64000)
        let head = try Data(contentsOf: dst).prefix(8)
        XCTAssertEqual(head.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }, 36 + 64000)
        XCTAssertEqual(try Data(contentsOf: src), srcBefore, "笔上的原文件不能动")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path + ".part"))
    }

    func testIntactRecordingIsCopiedAsIs() throws {
        try put("MEETING/20261119/11_00_00.wav", wav(seconds: 1))
        let src = root.appendingPathComponent("MEETING/20261119/11_00_00.wav")
        XCTAssertEqual(C1Max.WavInfo.read(src)?.needsFix, false)
        let dst = root.appendingPathComponent("copy.wav")
        try C1Max.copy(src, to: dst)
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
    }

    func testNotAWavFile() {
        XCTAssertNil(C1Max.WavInfo.parse(Data("OggS....OpusHead".utf8), fileSize: 16))
        XCTAssertNil(C1Max.WavInfo.parse(Data(), fileSize: 0))
    }
}
