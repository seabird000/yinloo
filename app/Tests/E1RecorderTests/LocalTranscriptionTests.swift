import Foundation
import XCTest
@testable import E1Recorder
import LocalASRCore

/// 1.5 本机转写：统一转写格式、各家结果的转换、漏转自检、苹果引擎（有条件时）。全部用虚构数据。
final class TranscriptFormatTests: XCTestCase {
    func testTingwuWordsGroupIntoSentences() {
        let t: [String: Any] = [
            "audioInfo": ["duration": 65_000],
            "paragraphs": [
                ["speakerId": "1", "words": [
                    ["sentenceId": 1, "start": 0, "end": 400, "text": "大家"],
                    ["sentenceId": 1, "start": 400, "end": 900, "text": "好。"],
                    ["sentenceId": 2, "start": 1_200, "end": 2_000, "text": "开始吧。"],
                ]],
                ["speakerId": "2", "words": [["sentenceId": 3, "start": 2_500, "end": 3_000, "text": "好的。"]]],
            ],
        ]
        let x = Transcript.fromTingwu(t, model: "tingwu-meeting")
        XCTAssertEqual(x.segments.map(\.text), ["大家好。", "开始吧。", "好的。"])
        XCTAssertEqual(x.segments.map(\.startMs), [0, 1_200, 2_500])
        XCTAssertEqual(x.segments[0].endMs, 900)
        XCTAssertEqual(x.segments.map(\.speaker), ["1", "1", "2"])
        XCTAssertEqual(x.segments.map(\.id), [0, 1, 2])
        XCTAssertEqual(x.durationMs, 65_000)
        XCTAssertTrue(x.features.speakers)
        XCTAssertTrue(x.features.wordTimestamps)
        XCTAssertEqual(x.text, "大家好。开始吧。好的。")
    }

    func testFunASRSentences() {
        let sentences: [[String: Any]] = [
            ["sentence_id": 1, "begin_time": 100, "end_time": 1_500, "text": "下周二开会。", "speaker_id": 0,
             "words": [["begin_time": 100, "end_time": 600, "text": "下周二", "punctuation": ""],
                       ["begin_time": 600, "end_time": 1_500, "text": "开会", "punctuation": "。"]]],
            ["sentence_id": 2, "begin_time": 2_000, "end_time": 2_800, "text": "收到。", "speaker_id": 1],
        ]
        let x = Transcript.fromFunASR(sentences: sentences, model: "fun-asr")
        XCTAssertEqual(x.segments.map(\.speaker), ["0", "1"])
        XCTAssertEqual(x.segments[0].words?.map(\.text), ["下周二", "开会。"])
        XCTAssertEqual(x.speakers.map(\.label), ["0", "1"])
        XCTAssertTrue(x.features.wordTimestamps)
    }

    func testOpenAISegmentsAndTextOnly() {
        let a = Transcript.fromOpenAI(["duration": 12.5, "segments": [["start": 0.0, "end": 2.5, "text": "你好"],
                                                                     ["start": 3, "end": 4.25, "text": "再见"]]], model: "gpt-transcribe")
        XCTAssertEqual(a.segments.map(\.startMs), [0, 3_000])
        XCTAssertEqual(a.segments[1].endMs, 4_250)
        XCTAssertEqual(a.durationMs, 12_500)
        XCTAssertTrue(a.warnings.isEmpty)

        let b = Transcript.fromOpenAI(["text": "只有一整段文字"], model: "gpt-transcribe")
        XCTAssertEqual(b.segments.count, 1)
        XCTAssertFalse(b.warnings.isEmpty)
    }

    func testParagraphsMergeSameSpeakerAndKeepEverySentence() {
        let x = Transcript(provider: "apple", model: "test", segments: [
            .init(id: 0, startMs: 0, endMs: 1_000, text: "第一句。"),
            .init(id: 1, startMs: 1_000, endMs: 2_000, text: "第二句。"),
            .init(id: 2, startMs: 2_000, endMs: 3_000, text: "", speaker: nil),
        ], features: .init())
        let p = x.tingwuParagraphs()["paragraphs"] as? [[String: Any]] ?? []
        XCTAssertEqual(p.count, 1)                                     // 没有说话人 = 一个人
        XCTAssertEqual((p[0]["words"] as? [[String: Any]])?.count, 2)  // 空句子不要
        // 现有渲染读得出来
        var b = TranscriptBundle(transcription: x.tingwuParagraphs())
        b.summarization = ["title": "测试"]
        XCTAssertEqual(MarkdownRenderer.heardText(b), "第一句。第二句。")
    }

    func testPromptLines() {
        let x = Transcript(provider: "apple", model: "test", segments: [
            .init(id: 0, startMs: 65_000, endMs: nil, text: "预算批了。"),
            .init(id: 1, startMs: 70_000, endMs: nil, text: "好。", speaker: "2"),
        ], features: .init())
        XCTAssertEqual(x.promptLines(), ["[01:05] 预算批了。", "[01:10] 发言人2：好。"])
    }

    func testJSONUsesSnakeCaseAndRoundTrips() throws {
        var x = Transcript(provider: "apple", model: "m", durationMs: 1_000,
                           segments: [.init(id: 0, startMs: 0, endMs: 500, text: "嗯")], features: .init(punctuation: true))
        x.coverage = .init(voicedSec: 1, missedSec: 0, badBlocks: 0, missedRanges: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try x.write(to: url)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"start_ms\""))
        XCTAssertTrue(raw.contains("\"duration_ms\""))
        XCTAssertEqual(try Transcript.read(from: url), x)
    }
}

final class CoverageTests: XCTestCase {
    /// 30 秒全程有声（每 0.25 秒一个音量），前面加 10 秒静音当底噪
    private let levels: [Float] = Array(repeating: 0.0005, count: 40) + Array(repeating: 0.1, count: 120)

    func testFullyCoveredIsQuiet() {
        let r = Coverage.check(levels: levels, window: 0.25, segments: [.init(id: 0, startMs: 10_000, endMs: 40_000, text: "…")])
        XCTAssertEqual(r.badBlocks, 0)
        XCTAssertEqual(r.missedSec, 0)
        XCTAssertFalse(r.shouldWarn)
        XCTAssertEqual(r.voicedSec, 30, accuracy: 0.01)
    }

    func testMissingTwoThirdsWarns() {
        // 只转出了有声部分的前 10 秒
        let r = Coverage.check(levels: levels, window: 0.25, segments: [.init(id: 0, startMs: 10_000, endMs: 20_000, text: "…")])
        XCTAssertGreaterThanOrEqual(r.badBlocks, 1)
        XCTAssertEqual(r.missedSec, 19, accuracy: 0.5)   // 放宽 1 秒
        XCTAssertTrue(r.shouldWarn)
        XCTAssertEqual(r.missedRanges.first?.first, 20_000)
        XCTAssertTrue(r.notice.contains("有人声但没转出文字"))
        XCTAssertTrue(r.notice.contains("00:20"))
    }

    func testSilenceIsNotMissed() {
        let r = Coverage.check(levels: Array(repeating: 0.0003, count: 200), window: 0.25, segments: [])
        XCTAssertEqual(r.voicedSec, 0)
        XCTAssertFalse(r.shouldWarn)
    }

    func testNoticeGoesIntoTheNote() {
        var b = TranscriptBundle(transcription: ["paragraphs": [["speakerId": "1", "words": [["text": "测试内容足够长，不会被当成无内容。", "start": 0, "sentenceId": 0]]]]])
        b.notices = ["约 3 分钟有人声但没转出文字"]
        let md = MarkdownRenderer.render(meta: .init(title: "t", start: Date(timeIntervalSince1970: 0), durationSec: 60, scene: "会议",
                                                     source: "测试", organizer: "", marks: [], audioFile: nil, timeUncertain: false),
                                         results: b, template: NoteTemplate.builtIn("standard").body)
        XCTAssertTrue(md.contains("> [!warning] 约 3 分钟有人声但没转出文字"))
    }
}

/// 苹果自带引擎：只在 macOS 26 以上、中文语音模型已装好时跑。用系统合成的中文语音，不碰任何真实录音。
final class AppleEngineTests: XCTestCase {
    func testTranscribesSynthesizedChinese() async throws {
        guard #available(macOS 26, *), await LocalEngines.appleChineseReady() else {
            throw XCTSkip("这台 Mac 没有苹果的中文本机转写")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let aiff = dir.appendingPathComponent("s.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Tingting", "-o", aiff.path, "今天的周会讨论三件事。第一，新版本下个月十五号发布。第二，预算二十万已经批下来了。"]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0, FileManager.default.fileExists(atPath: aiff.path) else {
            throw XCTSkip("系统没有中文合成语音")
        }
        let t = try await AppleSpeechEngine().transcribe(aiff) { _ in }
        XCTAssertEqual(t.provider, "apple")
        XCTAssertFalse(t.segments.isEmpty)
        XCTAssertTrue(t.text.contains("周会"), t.text)
        XCTAssertTrue(t.text.contains("15") || t.text.contains("十五"), t.text)
        XCTAssertNotNil(t.coverage)
        XCTAssertEqual(t.coverage?.shouldWarn, false)
        XCTAssertGreaterThan(t.durationMs ?? 0, 5_000)
    }
}

/// 手动核对用：E1_LOCAL_ASR_FILE=<录音路径> swift test --filter AppleEngineTests/testRealFileNumbersOnly
/// 只打印数字（时长、字数、自检结果），不打印内容。平时跳过。
extension AppleEngineTests {
    func testRealFileNumbersOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["E1_LOCAL_ASR_FILE"] else { throw XCTSkip("没设 E1_LOCAL_ASR_FILE") }
        guard #available(macOS 26, *) else { throw XCTSkip("需要 macOS 26") }
        let t0 = Date()
        let t = try await AppleSpeechEngine().transcribe(URL(fileURLWithPath: path)) { _ in }
        let c = t.coverage!
        print(String(format: "REAL: 时长 %.1f 分，耗时 %.1f 秒，%d 段，%d 字；有声 %.0f 秒，漏 %.0f 秒（%.0f%%），坏块 %d，提醒 %@",
                     Double(t.durationMs ?? 0) / 60000, Date().timeIntervalSince(t0), t.segments.count, t.text.count,
                     c.voicedSec, c.missedSec, c.missedRatio * 100, c.badBlocks, c.shouldWarn ? "是" : "否"))
    }
}

/// 本机转写的切段：不丢音频、每段不超过上限、切在安静处、分批送和一次送结果一样。
final class ChunkCutterTests: XCTestCase {
    private let rate = 1_000   // 测试用低采样率，数组小

    /// 有声（±0.5 交替）里在给定秒数处插入 0.3 秒静音
    private func signal(seconds: Double, gapsAt gaps: [Double]) -> [Float] {
        var s = (0..<Int(seconds * Double(rate))).map { $0 % 2 == 0 ? Float(0.5) : -0.5 }
        for g in gaps {
            let a = Int(g * Double(rate))
            for i in a..<min(a + 300, s.count) { s[i] = 0 }
        }
        return s
    }

    private func cutAll(_ s: [Float], step: Int) -> [ChunkCutter.Chunk] {
        var c = ChunkCutter(rate: rate, maxSec: 20, searchSec: 4)
        var out: [ChunkCutter.Chunk] = []
        var i = 0
        while i < s.count { out += c.append(s[i..<min(i + step, s.count)]); i += step }
        if let last = c.finish() { out.append(last) }
        return out
    }

    func testCutsLandInSilenceAndNothingIsLost() {
        let s = signal(seconds: 50, gapsAt: [17, 35])
        let chunks = cutAll(s, step: 250)
        XCTAssertEqual(chunks.map(\.samples).flatMap { $0 }, s)              // 一个样本都不丢、不重复
        XCTAssertEqual(chunks.count, 3)
        for (k, gap) in [(1, 17.0), (2, 35.0)] {                              // 切点落在那 0.3 秒静音里
            let t = Double(chunks[k].start) / Double(rate)
            XCTAssertTrue(t >= gap && t <= gap + 0.3, "第 \(k) 刀切在 \(t) 秒")
        }
        for (a, b) in zip(chunks, chunks.dropFirst()) { XCTAssertEqual(a.start + a.samples.count, b.start) }
    }

    func testNoSilenceStillCapsLengthAndKeepsEverything() {
        let s = signal(seconds: 65, gapsAt: [])
        let chunks = cutAll(s, step: 777)
        XCTAssertEqual(chunks.map(\.samples).flatMap { $0 }, s)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count <= 20 * rate })
        XCTAssertEqual(chunks.count, 4)
    }

    func testFeedingInPiecesMatchesFeedingAtOnce() {
        let s = signal(seconds: 47, gapsAt: [9, 18.5, 30])
        XCTAssertEqual(cutAll(s, step: 13), cutAll(s, step: s.count))
    }

    func testShortRecordingIsOneChunk() {
        let chunks = cutAll(signal(seconds: 5, gapsAt: []), step: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].endMs(rate: rate), 5_000)
    }
}

/// 分句：按逐字时间切句子、标点跟前一个字、超长句在逗号处切、对不上时按字数平均分。虚构句子。
final class SentencerTests: XCTestCase {
    /// 每个字一个 token，第 k 个字在 base + k*step 毫秒
    private func tokens(_ text: String, base: Int, step: Int) -> ([String], [Int]) {
        let cs = text.filter { $0.isLetter || $0.isNumber }.map(String.init)
        return (cs, cs.indices.map { base + $0 * step })
    }

    func testSplitsAtSentenceEndWithTokenTimes() {
        let text = "今天开会。下周三交方案！"
        let (tok, ts) = tokens(text, base: 10_000, step: 300)   // 不含标点：10 个字
        let s = Sentencer.split(text: text, tokens: tok, times: ts, chunkStartMs: 10_000, chunkEndMs: 20_000)
        XCTAssertEqual(s.map(\.text), ["今天开会。", "下周三交方案！"])
        XCTAssertEqual(s[0].startMs, 10_000)
        XCTAssertEqual(s[1].startMs, 10_000 + 4 * 300)
        XCTAssertEqual(s[0].endMs, 10_000 + 4 * 300, "下一句紧跟着开始时，到下一句开头为止")
        XCTAssertEqual(s[1].endMs, 10_000 + 9 * 300 + 800, "最后一句：最后一个字之后再算 0.8 秒")
    }

    func testTokensWithPunctuationStillAlign() {
        // X-ASR 的标点本身也是 token
        let s = Sentencer.split(text: "好的，明白。", tokens: ["好", "的", "，", "明", "白", "。"],
                                times: [0, 200, 300, 2_000, 2_200, 2_300], chunkStartMs: 0, chunkEndMs: 5_000)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].startMs, 0)
        XCTAssertEqual(s[0].endMs, 3_000)
    }

    func testFallsBackToEvenSpacingWithoutTimes() {
        let s = Sentencer.split(text: "第一句。第二句。", tokens: [], times: [], chunkStartMs: 0, chunkEndMs: 6_000)
        XCTAssertEqual(s.map(\.text), ["第一句。", "第二句。"])
        XCTAssertEqual(s[1].startMs, 3_000, "6 个字平均分：第 4 个字在 3 秒")
    }

    func testLongSentenceBreaksAtComma() {
        let a = String(repeating: "甲", count: 50), b = String(repeating: "乙", count: 50)
        let s = Sentencer.split(text: a + "，" + b + "。", tokens: [], times: [], chunkStartMs: 0, chunkEndMs: 20_000)
        XCTAssertEqual(s.map(\.text), [a + "，", b + "。"])
        let none = Sentencer.split(text: String(repeating: "丙", count: 200), tokens: [], times: [],
                                   chunkStartMs: 0, chunkEndMs: 20_000)
        XCTAssertEqual(none.map(\.text.count), [80, 80, 40], "没有逗号就硬切")
    }

    func testPunctuationOnlyPieceJoinsPrevious() {
        let s = Sentencer.split(text: "结束了。。", tokens: [], times: [], chunkStartMs: 0, chunkEndMs: 1_000)
        XCTAssertEqual(s.map(\.text), ["结束了。。"])
        XCTAssertTrue(Sentencer.split(text: "  ", tokens: [], times: [], chunkStartMs: 0, chunkEndMs: 1_000).isEmpty)
    }
}

/// 防复读：只收拾明显的复读，正常的叠词和数字不动。
final class RepeatGuardTests: XCTestCase {
    func testCollapsesLongRepeats() {
        XCTAssertEqual(RepeatGuard.clean("我们" + String(repeating: "好的", count: 9) + "开始"), "我们好的好的开始")
        XCTAssertEqual(RepeatGuard.clean(String(repeating: "哈", count: 12)), "哈哈哈")
    }

    func testKeepsNormalSpeech() {
        for t in ["对对对，就是这样", "好的好的好的", "谢谢谢谢", "预算 1000000 元", "哈哈哈哈哈"] {
            XCTAssertEqual(RepeatGuard.clean(t), t)
        }
    }
}

/// 读 WAV：afconvert 转 AAC 来源时写的扩展格式 fmt 和 FLLR 填充块也要能读。
final class WAVReaderTests: XCTestCase {
    private func wav(fmtTag: UInt16, filler: Bool, samples: [Int16]) throws -> URL {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
        var fmt = le(fmtTag) + le(UInt16(1)) + le(UInt32(16_000)) + le(UInt32(32_000)) + le(UInt16(2)) + le(UInt16(16))
        if fmtTag == 0xFFFE { fmt += le(UInt16(22)) + [UInt8](repeating: 0, count: 22) }
        var body = Array("WAVE".utf8) + Array("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
        if filler { body += Array("FLLR".utf8) + le(UInt32(5)) + [0, 0, 0, 0, 0, 0] }   // 奇数长度 + 补齐字节
        let data = samples.flatMap { le($0) }
        body += Array("data".utf8) + le(UInt32(data.count)) + data
        let all = Array("RIFF".utf8) + le(UInt32(body.count)) + body
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(all).write(to: u)
        return u
    }

    func testReadsPlainAndExtensibleWithFiller() throws {
        let samples: [Int16] = [0, 16_384, -16_384, 32_767, -32_768]
        for (tag, filler) in [(UInt16(1), false), (UInt16(0xFFFE), true)] {
            let u = try wav(fmtTag: tag, filler: filler, samples: samples)
            defer { try? FileManager.default.removeItem(at: u) }
            let r = try WAVReader(url: u)
            XCTAssertEqual(r.sampleRate, 16_000)
            XCTAssertEqual(r.totalSamples, 5)
            let a = try r.read(3), b = try r.read(10), c = try r.read(10)
            XCTAssertEqual(a, [0, 0.5, -0.5])
            XCTAssertEqual(b.count, 2)
            XCTAssertEqual(b[1], -1)
            XCTAssertTrue(c.isEmpty)
        }
    }

    func testRejectsStereo() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: u) }
        var b = Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WAVEfmt ".utf8) + [16, 0, 0, 0, 1, 0, 2, 0]
        b += [0x80, 0x3E, 0, 0, 0, 0xFA, 0, 0, 4, 0, 16, 0] + Array("data".utf8) + [0, 0, 0, 0]
        try Data(b).write(to: u)
        XCTAssertThrowsError(try WAVReader(url: u))
    }
}

/// 端到端：真的起识别子程序转一段音频。要先 swift build --product yinloo-asr，并用环境变量 YINLOO_MODELS_DIR
/// 指向放着 X-ASR 模型的文件夹；没有就跳过（CI 和别人的电脑上不跑）。
final class SherpaEngineTests: XCTestCase {
    func testHelperTranscribesSampleClip() async throws {
        guard ProcessInfo.processInfo.environment["YINLOO_MODELS_DIR"] != nil, LocalModels.xasr.isInstalled else {
            throw XCTSkip("没设 YINLOO_MODELS_DIR 或里面没有 X-ASR 模型")
        }
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("yinloo-asr")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw XCTSkip("先 swift build --product yinloo-asr") }
        SherpaEngine.helperOverride = helper
        defer { SherpaEngine.helperOverride = nil }
        let clip = LocalModels.xasr.dir.appendingPathComponent("test_wavs/0.wav")
        let t = try await SherpaEngine(model: LocalModels.xasr).transcribe(clip) { _ in }
        XCTAssertFalse(t.segments.isEmpty)
        XCTAssertTrue(t.text.contains("星期三"), t.text)
        XCTAssertEqual(t.provider, "sherpa")
        XCTAssertGreaterThan(t.segments[0].startMs, 0)
    }

    func testMissingModelGivesClearError() async {
        let m = LocalModel(id: "nope", name: "测试模型", note: "", kind: "transducer", folder: "does-not-exist-\(UUID())",
                           files: ["tokens": "tokens.txt"], punct: nil, sizeMB: 1, license: "", archives: [])
        do {
            _ = try await SherpaEngine(model: m).transcribe(URL(fileURLWithPath: "/dev/null")) { _ in }
            XCTFail("应该报错")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("还没下载"), "\(error)")
        }
    }
}

/// ① 转文字和 ② 整理分开选（1.5）：旧设置怎么迁过来、换平台时 ② 怎么跟着变
final class NoteServiceTests: XCTestCase {
    func testMigrationFromOldSettings() {
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .tingwu, legacyLocalNote: nil), .tingwu)
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .bailian, legacyLocalNote: nil), .bailian)
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .custom, legacyLocalNote: nil), .custom)
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .local, legacyLocalNote: "bailian"), .bailian)
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .local, legacyLocalNote: "custom"), .custom)
        // 旧的「不整理，只要逐字稿」没有了：改成千问，没填密钥就照样只出逐字稿
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .local, legacyLocalNote: "none"), .bailian)
        XCTAssertEqual(AppSettings.migratedNoteService(provider: .local, legacyLocalNote: nil), .bailian)
    }

    func testStepTwoFollowsStepOne() {
        // 选听悟转写：默认让听悟一起整理
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .tingwu, from: .deepseek), .tingwu)
        // 离开听悟：换成同一个账号能用的大模型
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .bailian, from: .tingwu), .bailian)
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .local, from: .tingwu), .bailian)
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .custom, from: .tingwu), .custom)
        // 用户自己选过的（DeepSeek 等）不动
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .local, from: .deepseek), .deepseek)
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .bailian, from: .custom), .custom)
    }

    func testAccounts() {
        XCTAssertEqual(NoteService.tingwu.account, .aliyun)
        XCTAssertEqual(NoteService.bailian.account, .aliyun)
        XCTAssertEqual(NoteService.deepseek.account, .deepseek)
        XCTAssertEqual(NoteService.custom.account, .custom)
        XCTAssertNil(NoteService.local.account)
        // 三家的密钥在钥匙串里各有各的名字，不会互相覆盖
        XCTAssertEqual(Set(CloudAccount.allCases.map(\.keychainAccount)).count, CloudAccount.allCases.count)
        XCTAssertNil(CloudAccount.deepseek.validate("sk-" + String(repeating: "a", count: 30)))
        XCTAssertNotNil(CloudAccount.deepseek.validate("abc"))
    }

    func testModelsURLForConnectionTest() {
        let ds = DashScope(apiKey: "k", endpoint: DeepSeekAPI.base)
        func models(_ chat: String) -> String {
            let w = NoteWriter(ds: ds, chatURL: URL(string: chat)!, model: "m")
            return w.chatURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models").absoluteString
        }
        XCTAssertEqual(models(DeepSeekAPI.base + "/chat/completions"), "https://api.deepseek.com/models")
        XCTAssertEqual(models("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"),
                       "https://dashscope.aliyuncs.com/compatible-mode/v1/models")
    }
}

/// 1.5：新装默认本机转写、先不整理；老用户一律照旧（特别是从没写过 provider 键、一直靠默认值用听悟的）
final class FreshInstallDefaultsTests: XCTestCase {
    private var suite = ""
    private var d: UserDefaults!

    override func setUp() {
        suite = "yinloo.test.fresh." + UUID().uuidString
        d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        d.removePersistentDomain(forName: suite)
    }

    func testFreshInstallDefaultsToLocalWithoutNotes() {
        XCTAssertTrue(AppSettings.isFreshInstall(d))
        let s = AppSettings.initialServices(d)
        XCTAssertTrue(s.fresh)
        XCTAssertEqual(s.provider, .local)
        XCTAssertEqual(s.note, .off)
    }

    func testOldUserWithAppIdOrOnboardingStaysOnTingwu() {
        d.set("tw_DemoAppId01", forKey: "appId")
        var s = AppSettings.initialServices(d)
        XCTAssertFalse(s.fresh)
        XCTAssertEqual(s.provider, .tingwu)
        XCTAssertEqual(s.note, .tingwu)

        d.removePersistentDomain(forName: suite)
        d.set(true, forKey: "onboardingDone")
        s = AppSettings.initialServices(d)
        XCTAssertFalse(s.fresh)
        XCTAssertEqual(s.provider, .tingwu)
        XCTAssertEqual(s.note, .tingwu)
    }

    func testOldUserWithoutProviderKeyStaysOnTingwu() {
        // 1.2～1.4 每次启动都会写的几个键；provider、appId、onboardingDone 一个都没有
        d.set(true, forKey: "loginItemInitialized")
        d.set("/tmp/notes", forKey: "notesFolder")
        d.set("/tmp/audio", forKey: "audioFolder")
        let s = AppSettings.initialServices(d)
        XCTAssertFalse(s.fresh)
        XCTAssertEqual(s.provider, .tingwu)
        XCTAssertEqual(s.note, .tingwu)
        // 只剩任何一个用过的痕迹，也算老用户
        for k in AppSettings.usedBeforeKeys {
            d.removePersistentDomain(forName: suite)
            d.set("x", forKey: k)
            XCTAssertFalse(AppSettings.isFreshInstall(d), k)
        }
    }

    func testSavedChoicesAreKept() {
        d.set("bailianASR", forKey: "provider")
        var s = AppSettings.initialServices(d)
        XCTAssertEqual(s.provider, .bailian)
        XCTAssertEqual(s.note, .bailian)
        d.set("deepseek", forKey: "noteService")
        s = AppSettings.initialServices(d)
        XCTAssertEqual(s.note, .deepseek)
        // 新装第一次启动存下的结果，第二次启动（目录已经固定、不再算新装）照样是本机 + 不整理
        d.removePersistentDomain(forName: suite)
        d.set("local", forKey: "provider")
        d.set("off", forKey: "noteService")
        d.set("/tmp/notes", forKey: "notesFolder")
        s = AppSettings.initialServices(d)
        XCTAssertFalse(s.fresh)
        XCTAssertEqual(s.provider, .local)
        XCTAssertEqual(s.note, .off)
    }

    func testTranscriptOnly() {
        XCTAssertNil(NoteService.off.account)
        // 新用户在引导里试了一下云端又切回本机：没有阿里云密钥就回到「先不整理」，有就用千问
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .local, from: .tingwu, aliyunKey: false), .off)
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .local, from: .tingwu, aliyunKey: true), .bailian)
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .bailian, from: .off), .off)
        XCTAssertEqual(AppSettings.noteService(afterSwitchingTo: .tingwu, from: .off), .tingwu)
    }
}
