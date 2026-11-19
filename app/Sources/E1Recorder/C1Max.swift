import Foundation

/// 搜狗 C1 Max：插上 USB 就是一块 U 盘（FAT32），录音按「类别/日期/时刻」存放：
/// `MEETING/20261119/17_19_17.wav`（降噪后的单声道 16 kHz，转写用这个）和同名 `.opus`（4 声道原始录音，标签里带序列号）。
/// 这里只读文件，不往笔上写任何东西。挂载（只读）见 `C1MaxDisk`，同步流程见 `Pipeline+C1Max`。
enum C1Max {
    /// 录音所在的类别文件夹和界面上的叫法。MUSIC 是放音乐的，不算录音。
    static let categories: [(folder: String, name: String)] = [
        ("MEETING", "会议"), ("INTERVIEW", "采访"), ("LECTURE", "讲座"), ("MEMO", "备忘"),
    ]

    /// 系统报的 USB 产品名和厂商号（芯片厂 Rockchip）。挂载之前就能认出来。
    static func matches(productName: String?, vendorID: Int?) -> Bool {
        productName?.trimmingCharacters(in: .whitespaces) == "C1 Max" && vendorID == 0x2207
    }

    /// 挂上之后再核对一次目录：有 MEETING，还有 LOG 或 STAT。
    static func looksLikeC1Max(_ volume: URL) -> Bool {
        let fm = FileManager.default
        func dir(_ name: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: volume.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
        }
        return dir("MEETING") && (dir("LOG") || dir("STAT"))
    }

    struct Recording: Equatable, Sendable {
        let rel: String          // 相对 U 盘根目录的路径，如 "MEETING/20261119/17_19_17.wav"
        let category: String     // 会议、采访、讲座、备忘
        let created: Date?       // 由文件夹和文件名得出（笔上的时钟，可能不准）
        let size: Int64
        let durationSec: Int
        /// 同一路径的文件可能被笔覆盖（时钟回到 2020-01-01 后又在同一秒开始录），所以带上大小。
        var key: String { rel + "#" + String(size) }
        /// 笔的时钟断电后从 2020-01-01 起算：2024 年以前的时间不可信。
        var timeUncertain: Bool { created.map { Calendar.current.component(.year, from: $0) < 2024 } ?? true }
    }

    /// 「20261119」+「17_19_17」→ 当地时间。认不出就是 nil。
    static func date(day: String, file: String) -> Date? {
        let d = day.compactMap(\.wholeNumberValue)
        let t = file.split(separator: "_").map { Int($0) }
        guard day.count == 8, d.count == 8, t.count == 3, let h = t[0], let m = t[1], let s = t[2] else { return nil }
        var c = DateComponents()
        c.year = d[0...3].reduce(0) { $0 * 10 + $1 }
        c.month = d[4] * 10 + d[5]
        c.day = d[6] * 10 + d[7]
        c.hour = h; c.minute = m; c.second = s
        guard (1...12).contains(c.month!), (1...31).contains(c.day!), (0...23).contains(h), (0...59).contains(m), (0...59).contains(s) else { return nil }
        return Calendar.current.date(from: c)
    }

    /// 笔里的录音（只看 .wav），新的在前。读不了的文件跳过。
    static func list(_ volume: URL) -> [Recording] {
        let fm = FileManager.default
        var out: [Recording] = []
        for (folder, name) in categories {
            let base = volume.appendingPathComponent(folder, isDirectory: true)
            guard let days = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for day in days where !day.hasPrefix(".") {
                let dayURL = base.appendingPathComponent(day, isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(atPath: dayURL.path) else { continue }
                for f in files where !f.hasPrefix(".") && f.lowercased().hasSuffix(".wav") {
                    let url = dayURL.appendingPathComponent(f)
                    guard let info = WavInfo.read(url), info.byteRate > 0 else { continue }
                    let stem = (f as NSString).deletingPathExtension
                    out.append(Recording(rel: "\(folder)/\(day)/\(f)", category: name, created: date(day: day, file: stem),
                                         size: info.fileSize, durationSec: Int(info.dataSize / Int64(info.byteRate))))
                }
            }
        }
        return out.sorted { ($0.created ?? .distantPast, $0.rel) > ($1.created ?? .distantPast, $1.rel) }
    }

    /// 自动导入哪些：没处理过、不是第一次插上时就在笔里的、还没有转写记录的、不太短的。太短的单独列出（记成处理过）。
    static func pick(_ recs: [Recording], handled: Set<String>, before: Set<String>, jobKeys: Set<String>,
                     minDurationSec: Int) -> (new: [Recording], tooShort: [Recording]) {
        let fresh = recs.filter { !handled.contains($0.key) && !before.contains($0.key) && !jobKeys.contains($0.key) }
        let minSec = max(1, minDurationSec)
        return (fresh.filter { $0.durationSec >= minSec }, fresh.filter { $0.durationSec < minSec })
    }

    /// 笔的时钟断电时停走、再通电接着走（这台的电池坏了），断电多久就慢多久，年份却是对的。
    /// 认法：上次读笔时还没有、时间却早于上次读笔（留一分钟余量）的录音，时钟一定慢了。
    static func clockBehind(_ recs: [Recording], seen: Set<String>, lastListed: Date?) -> Set<String> {
        guard let lastListed else { return [] }
        let limit = lastListed.addingTimeInterval(-60)
        return Set(recs.filter { !seen.contains($0.key) && ($0.created.map { $0 < limit } ?? false) }.map(\.key))
    }

    /// 拷到 Mac 上的文件名：C1Max_20261119_171917.wav；认不出时间的用原路径。
    static func fileName(_ r: Recording) -> String {
        if let c = r.created { return "C1Max_" + DateFormatter.cached("yyyyMMdd_HHmmss").string(from: c) + ".wav" }
        return "C1Max_" + r.rel.replacingOccurrences(of: "/", with: "_")
    }

    /// 目标文件夹里不重名的位置。已有同样大小的同名文件就直接用它（之前拷过）。
    static func destination(for r: Recording, in dir: URL) -> URL {
        let fm = FileManager.default
        let name = fileName(r)
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if size == r.size { return url }
            url = dir.appendingPathComponent("\(stem)_\(n).\(ext)")
            n += 1
        }
        return url
    }

    /// 把笔上的录音拷到 `dst`（先拷成 .part 再改名，拔线不会留下半截文件）。笔断电时录了一半的文件，
    /// 文件头里的长度可能是 0，就在拷过来的那份上按实际长度改正；笔上的原文件不动。
    static func copy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let part = dst.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        try fm.copyItem(at: src, to: part)
        do {
            if let info = WavInfo.read(part), info.needsFix { try info.fix(part) }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: part, to: dst)
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    /// WAV 文件头里要用的几项。
    struct WavInfo: Equatable {
        let fileSize: Int64
        let byteRate: Int
        let dataOffset: Int64      // 音频数据从哪一字节开始
        let declared: UInt32       // 文件头里写的音频长度
        /// 实际的音频长度：文件头里写的不对（0、溢出、比文件还长）就按文件实际长度算。
        var dataSize: Int64 {
            let avail = max(0, fileSize - dataOffset)
            return declared == 0 || declared == .max || Int64(declared) > avail ? avail : Int64(declared)
        }
        var needsFix: Bool { Int64(declared) != dataSize && dataSize > 0 }

        static func read(_ url: URL) -> WavInfo? {
            guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd(), (try? h.seek(toOffset: 0)) != nil,
                  let head = try? h.read(upToCount: 4096) else { return nil }
            return parse(head, fileSize: Int64(size))
        }

        /// 走一遍 RIFF 块：fmt 里取每秒字节数，data 块的位置和长度。
        static func parse(_ d: Data, fileSize: Int64) -> WavInfo? {
            let b = [UInt8](d)
            func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
            func tag(_ i: Int) -> String { String(decoding: b[i..<i + 4], as: UTF8.self) }
            guard b.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
            var i = 12
            var rate = 0
            while i + 8 <= b.count {
                let id = tag(i), len = Int(u32(i + 4))
                if id == "fmt ", i + 16 <= b.count { rate = Int(u32(i + 16)) }
                if id == "data" {
                    guard rate > 0 else { return nil }
                    return WavInfo(fileSize: fileSize, byteRate: rate, dataOffset: Int64(i + 8), declared: u32(i + 4))
                }
                guard len >= 0, len < 1 << 20 else { return nil }
                i += 8 + len + (len & 1)
            }
            return nil
        }

        /// 按实际长度改写 RIFF 和 data 两处长度。
        func fix(_ url: URL) throws {
            let h = try FileHandle(forUpdating: url)
            defer { try? h.close() }
            func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
            let data = UInt32(clamping: dataSize)
            try h.seek(toOffset: 4)
            h.write(le(UInt32(clamping: dataOffset - 8 + Int64(data))))
            try h.seek(toOffset: UInt64(dataOffset - 4))
            h.write(le(data))
        }
    }
}
