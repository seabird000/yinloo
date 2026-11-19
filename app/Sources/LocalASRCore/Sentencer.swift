import Foundation

/// 一句话：开始、结束（毫秒，整段录音里的绝对时间）和文字。
public struct TimedText: Codable, Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public init(startMs: Int, endMs: Int, text: String) { self.startMs = startMs; self.endMs = endMs; self.text = text }
}

/// 把一段（最长 20 秒）识别结果切成句子，每句带开始、结束时间。
///
/// 时间来自模型给的逐 token 时间戳（X-ASR 这类 transducer 都给）：只拿「字母、数字、汉字」对齐，
/// 标点和空格跟着前一个字。对不上（数量不一样，或模型不给时间戳）时，按字数在这一段里平均分。
public enum Sentencer {
    static let enders: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "…"]
    static let breaks: Set<Character> = ["，", ",", "、", "：", ":"]
    /// 句子最后一个字之后最多再算多长（毫秒）。后面是长时间静音时，句子不会一直延到下一句
    static let tailMs = 800

    public static func split(text: String, tokens: [String], times: [Int], chunkStartMs: Int, chunkEndMs: Int,
                             maxChars: Int = 80) -> [TimedText] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let at = charTimes(chars, tokens: tokens, times: times, start: chunkStartMs, end: chunkEndMs)

        // 先按句末标点切，再把超长的句子在逗号处（没有逗号就硬切）切短
        var ranges: [Range<Int>] = []
        var s = 0
        for i in chars.indices where enders.contains(chars[i]) {
            ranges.append(s..<(i + 1)); s = i + 1
        }
        if s < chars.count { ranges.append(s..<chars.count) }
        ranges = ranges.flatMap { shorten($0, chars, maxChars) }

        var out: [(Range<Int>, String)] = []
        for r in ranges {
            let t = String(chars[r]).trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            if !t.contains(where: isContent), !out.isEmpty {
                out[out.count - 1].1 += t    // 只有标点：并到上一句
                out[out.count - 1].0 = out[out.count - 1].0.lowerBound..<r.upperBound
                continue
            }
            out.append((r, t))
        }
        return out.enumerated().map { k, item in
            let (r, t) = item
            let first = r.first(where: { isContent(chars[$0]) }) ?? r.lowerBound
            let last = r.last(where: { isContent(chars[$0]) }) ?? r.upperBound - 1
            let start = at[first]
            let next = k + 1 < out.count ? at[out[k + 1].0.first(where: { isContent(chars[$0]) }) ?? out[k + 1].0.lowerBound] : chunkEndMs
            let end = max(min(next, at[last] + tailMs, chunkEndMs), start + 200)
            return TimedText(startMs: start, endMs: end, text: t)
        }
    }

    static func isContent(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// 每个字的时间（毫秒）
    static func charTimes(_ chars: [Character], tokens: [String], times: [Int], start: Int, end: Int) -> [Int] {
        let content = chars.indices.filter { isContent(chars[$0]) }
        var tokTimes: [Int] = []
        if tokens.count == times.count {
            for (tok, t) in zip(tokens, times) {
                for c in tok where isContent(c) { tokTimes.append(t) }
            }
        }
        var at = [Int](repeating: start, count: chars.count)
        if !content.isEmpty && tokTimes.count == content.count {
            for (k, i) in content.enumerated() { at[i] = tokTimes[k] }
        } else {
            for (k, i) in content.enumerated() { at[i] = start + (end - start) * k / max(content.count, 1) }
        }
        // 标点、空格跟前一个字
        var prev = start
        for i in chars.indices {
            if isContent(chars[i]) { prev = at[i] } else { at[i] = prev }
        }
        return at
    }

    static func shorten(_ r: Range<Int>, _ chars: [Character], _ maxChars: Int) -> [Range<Int>] {
        guard r.count > maxChars else { return [r] }
        // 在前 maxChars 个字里找最后一个逗号；太靠前（不到一半）就不用它
        let limit = r.lowerBound + maxChars
        if let cut = (r.lowerBound + maxChars / 2..<limit).last(where: { breaks.contains(chars[$0]) }) {
            return [r.lowerBound..<(cut + 1)] + shorten((cut + 1)..<r.upperBound, chars, maxChars)
        }
        return [r.lowerBound..<limit] + shorten(limit..<r.upperBound, chars, maxChars)
    }
}

/// 防复读：模型在噪声里偶尔会把一个词连着吐十几遍。同一个 1～8 字的片段连续出现太多次时只留几次。
/// 正常说话里的「对对对」「好的好的」不动；纯数字不动（「100000」不是复读）。
public enum RepeatGuard {
    public static func clean(_ s: String) -> String {
        let c = Array(s)
        var out: [Character] = []
        var i = 0
        outer: while i < c.count {
            for len in 1...8 where i + len * 2 <= c.count {
                let unit = c[i..<(i + len)]
                if unit.allSatisfy({ $0.isNumber || $0.isWhitespace }) { continue }
                var n = 1
                while i + (n + 1) * len <= c.count && c[(i + n * len)..<(i + (n + 1) * len)] == unit { n += 1 }
                // 单字连续 7 次以上留 3 次（「哈哈哈」），多字连续 5 次以上留 2 次
                let (limit, keep) = len == 1 ? (6, 3) : (4, 2)
                if n > limit {
                    for _ in 0..<keep { out.append(contentsOf: unit) }
                    i += n * len
                    continue outer
                }
            }
            out.append(c[i]); i += 1
        }
        return String(out)
    }
}
