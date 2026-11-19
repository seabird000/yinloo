import Foundation

/// 统一转写格式（第 1 版）。本机引擎和各家云端都先转成它，再交给纪要整理和渲染。
/// 存在 results/<编号>/transcript.json；字段用下划线命名，外部工具（MCP、脚本）读起来直观。
/// 设计见项目根目录「技术路线与实现方案.md」第五节。
struct Transcript: Codable, Equatable {
    var version = 1
    /// 谁转的：tingwu、bailianASR、custom、apple、sherpa…
    var provider: String
    var model: String
    var durationMs: Int?
    var segments: [Segment]
    var speakers: [Speaker] = []
    /// 这次结果实际带了哪些信息（同一家服务不同模型可能不一样）
    var features: Features
    var warnings: [String] = []
    /// 漏转自检的结果（本机引擎才有：要读原始音频的音量）
    var coverage: Coverage.Report?

    struct Segment: Codable, Equatable {
        var id: Int
        var startMs: Int
        var endMs: Int?
        var text: String
        /// 说话人标签；nil = 这次没有区分说话人
        var speaker: String?
        /// 声道：0 = 麦克风，1 = 系统声音（线上会议录音用）；nil = 单声道
        var channel: Int?
        var words: [Word]?
    }

    struct Word: Codable, Equatable {
        var text: String
        var startMs: Int
        var endMs: Int?
    }

    struct Speaker: Codable, Equatable {
        var label: String
        var displayName: String?
    }

    struct Features: Codable, Equatable {
        var wordTimestamps = false
        var speakers = false
        var punctuation = false
        var numberNormalization = false
    }

    var text: String { segments.map(\.text).joined() }

    // MARK: 读写

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func write(to url: URL) throws { try Self.encoder.encode(self).write(to: url, options: .atomic) }
    static func read(from url: URL) throws -> Transcript { try decoder.decode(Transcript.self, from: Data(contentsOf: url)) }

    // MARK: 给现有渲染用：转成听悟的段落形状

    /// 连续同一说话人的句子并成一段；每句是一个 word（带 sentenceId），和 BailianClient 的做法一致，
    /// 所以纪要模板、说话人命名、重点标记都不用改。
    func tingwuParagraphs() -> [String: Any] {
        var paragraphs: [[String: Any]] = []
        for (i, s) in segments.enumerated() where !s.text.isEmpty {
            let spk = s.speaker ?? "1"
            var word: [String: Any] = ["text": s.text, "start": s.startMs, "sentenceId": i]
            if let e = s.endMs { word["end"] = e }
            if var last = paragraphs.last, last["speakerId"] as? String == spk {
                last["words"] = (last["words"] as? [[String: Any]] ?? []) + [word]
                paragraphs[paragraphs.count - 1] = last
            } else {
                paragraphs.append(["speakerId": spk, "words": [word]])
            }
        }
        return ["paragraphs": paragraphs]
    }

    /// 交给大模型的逐行文本：「[mm:ss] 发言人X：…」。没有说话人时省掉「发言人」。
    func promptLines() -> [String] {
        segments.filter { !$0.text.isEmpty }.map { s in
            let sec = s.startMs / 1000
            let head = String(format: "[%02d:%02d] ", sec / 60, sec % 60)
            return head + (s.speaker.map { "发言人\($0)：" } ?? "") + s.text
        }
    }

    // MARK: 从各家结果转过来

    /// 听悟 transcription.json：paragraphs[].words[]，同一 sentenceId 的词拼成一句。
    static func fromTingwu(_ t: [String: Any], model: String) -> Transcript {
        var segs: [Segment] = []
        var speakers: [String] = []
        var hasWordTimes = false
        for p in (t["paragraphs"] as? [[String: Any]]) ?? [] {
            let spk = p["speakerId"].map { "\($0)" }
            if let spk, !speakers.contains(spk) { speakers.append(spk) }
            var current: (id: Int, seg: Segment)?
            for w in (p["words"] as? [[String: Any]]) ?? [] {
                let sid = int(w["sentenceId"]) ?? -1
                let start = int(w["start"]) ?? 0
                let end = int(w["end"])
                let word = Word(text: w["text"] as? String ?? "", startMs: start, endMs: end)
                if end != nil { hasWordTimes = true }
                if current?.id == sid {
                    current!.seg.text += word.text
                    current!.seg.endMs = end ?? current!.seg.endMs
                    current!.seg.words?.append(word)
                } else {
                    if let c = current { segs.append(c.seg) }
                    current = (sid, Segment(id: segs.count, startMs: start, endMs: end, text: word.text, speaker: spk, words: [word]))
                }
            }
            if let c = current { segs.append(c.seg) }
        }
        for i in segs.indices { segs[i].id = i }
        let dur = int((t["audioInfo"] as? [String: Any])?["duration"])
        return Transcript(provider: "tingwu", model: model, durationMs: dur, segments: segs,
                          speakers: speakers.map { Speaker(label: $0) },
                          features: Features(wordTimestamps: hasWordTimes, speakers: speakers.count > 1, punctuation: true,
                                             numberNormalization: true))
    }

    /// 百炼 Fun-ASR：transcripts[0].sentences[]（begin_time、end_time、text、speaker_id、words[]）。
    static func fromFunASR(sentences: [[String: Any]], model: String, durationMs: Int? = nil) -> Transcript {
        var speakers: [String] = []
        let segs = sentences.enumerated().map { i, s -> Segment in
            let spk = int(s["speaker_id"]).map(String.init)
            if let spk, !speakers.contains(spk) { speakers.append(spk) }
            let words = (s["words"] as? [[String: Any]])?.map {
                Word(text: ($0["text"] as? String ?? "") + ($0["punctuation"] as? String ?? ""),
                     startMs: int($0["begin_time"]) ?? 0, endMs: int($0["end_time"]))
            }
            return Segment(id: i, startMs: int(s["begin_time"]) ?? 0, endMs: int(s["end_time"]), text: s["text"] as? String ?? "",
                           speaker: spk, words: words)
        }
        return Transcript(provider: "bailianASR", model: model, durationMs: durationMs, segments: segs,
                          speakers: speakers.map { Speaker(label: $0) },
                          features: Features(wordTimestamps: segs.contains { $0.words?.isEmpty == false }, speakers: !speakers.isEmpty,
                                             punctuation: true, numberNormalization: true))
    }

    /// OpenAI 兼容接口：verbose_json 的 segments[]（秒），或只有 text。
    static func fromOpenAI(_ raw: [String: Any], model: String) -> Transcript {
        var segs: [Segment] = ((raw["segments"] as? [[String: Any]]) ?? []).enumerated().map { i, s in
            Segment(id: i, startMs: Int((double(s["start"]) ?? 0) * 1000), endMs: double(s["end"]).map { Int($0 * 1000) },
                    text: s["text"] as? String ?? "")
        }
        var warnings: [String] = []
        if segs.isEmpty, let t = raw["text"] as? String {
            segs = [Segment(id: 0, startMs: 0, endMs: nil, text: t)]
            warnings.append("接口没有返回分段时间，整段放在 00:00")
        }
        return Transcript(provider: "custom", model: model, durationMs: double(raw["duration"]).map { Int($0 * 1000) }, segments: segs,
                          features: Features(punctuation: true), warnings: warnings)
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let i as Int: i
        case let d as Double: Int(d)
        case let s as String: Int(s)
        default: nil
        }
    }

    private static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: d
        case let i as Int: Double(i)
        case let s as String: Double(s)
        default: nil
        }
    }
}

// MARK: - 漏转自检

/// 「有人声却没出字」：按音量找出有声的时间，再看转写段盖住了多少。对任何引擎都适用。
/// 规则和阈值来自 M0 实测（资料/实测/M0-本机实测记录.md），tools/asrbench/coverage.py 是同一算法的脚本版。
enum Coverage {
    struct Report: Codable, Equatable {
        var voicedSec: Double
        var missedSec: Double
        var badBlocks: Int
        /// 连续漏转的时间段（毫秒），已合并，最多留 5 段
        var missedRanges: [[Int]]

        var missedRatio: Double { voicedSec > 0 ? missedSec / voicedSec : 0 }
        /// 要不要提醒用户：坏块 ≥ 3，或漏掉的有声时间 ≥ 10%（且至少 15 秒）
        var shouldWarn: Bool { badBlocks >= 3 || (missedRatio >= 0.1 && missedSec >= 15) }

        /// 写进纪要和记录页的一句话
        var notice: String {
            let mins = missedSec >= 90 ? "约 \(Int((missedSec / 60).rounded())) 分钟" : "约 \(Int(missedSec.rounded())) 秒"
            let where_ = missedRanges.prefix(3).map { "\(MarkdownRenderer.ts($0[0]))–\(MarkdownRenderer.ts($0[1]))" }
            return "\(mins)有人声但没转出文字" + (where_.isEmpty ? "" : "（多在 " + where_.joined(separator: "、") + "）")
                + "，可能是离话筒远或多人同时说话。可以换一个转写引擎重转。"
        }
    }

    /// levels：每 window 秒一个音量（RMS，0～1）。
    static func check(levels: [Float], window: Double, segments: [Transcript.Segment], pad: Double = 1) -> Report {
        guard !levels.isEmpty else { return Report(voicedSec: 0, missedSec: 0, badBlocks: 0, missedRanges: []) }
        let floor = levels.sorted()[levels.count / 10] * 1.5
        let gate = max(floor, Float(pow(10, -45.0 / 20)))
        let voiced = levels.map { $0 > gate }
        var covered = [Bool](repeating: false, count: levels.count)
        for s in segments {
            let a = max(0, Int((Double(s.startMs) / 1000 - pad) / window))
            let b = min(levels.count, Int((Double(s.endMs ?? s.startMs) / 1000 + pad) / window) + 1)
            if a < b { for k in a..<b { covered[k] = true } }
        }
        let miss = voiced.indices.map { voiced[$0] && !covered[$0] }
        // 10 秒一块：有声 ≥ 30%，其中 60% 以上没盖住
        let step = max(1, Int(10 / window))
        var bad = 0
        var ranges: [[Int]] = []
        for k in stride(from: 0, to: miss.count, by: step) {
            let e = min(k + step, miss.count)
            let v = voiced[k..<e].filter { $0 }.count
            let m = miss[k..<e].filter { $0 }.count
            if Double(v) >= Double(step) * 0.3, Double(m) / Double(max(v, 1)) > 0.6 {
                bad += 1
                let r = [Int(Double(k) * window * 1000), Int(Double(e) * window * 1000)]
                if let last = ranges.last, last[1] >= r[0] { ranges[ranges.count - 1][1] = r[1] } else { ranges.append(r) }
            }
        }
        ranges.sort { ($0[1] - $0[0]) > ($1[1] - $1[0]) }
        return Report(voicedSec: Double(voiced.filter { $0 }.count) * window, missedSec: Double(miss.filter { $0 }.count) * window,
                      badBlocks: bad, missedRanges: Array(ranges.prefix(5)).sorted { $0[0] < $1[0] })
    }
}
