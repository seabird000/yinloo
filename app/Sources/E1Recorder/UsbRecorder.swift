import AVFoundation
import CryptoKit
import Foundation

/// 通用的 U 盘式录音笔：插上 USB 出现一块盘的录音笔。只读文件，不往笔上写任何东西。
/// 这里是纯逻辑（认设备、找录音、从文件名取时间、挑新录音、生成脱敏的设备描述），便于测试；
/// 挂载见 `UsbDisk`，同步见 `Pipeline+UsbRecorder`，档案的来源见 `DeviceProfiles`。
/// 搜狗 C1 Max 不走这里（它有自己的专用代码，已真机验证）。
enum UsbRecorder {
    // MARK: 认设备

    /// 系统报的一块 USB 盘是谁。序列号只存摘要，不存原文。
    struct Identity: Equatable, Hashable, Sendable, Codable {
        var vendorID: Int
        var productID: Int
        var productName: String?
        var manufacturer: String?
        var serialHash: String?

        /// 序列号的摘要（16 位十六进制）：能认出同一支笔，又看不出序列号本身。
        static func hash(serial: String?) -> String? {
            guard let s = serial?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            let d = SHA256.hash(data: Data(("yinloo-usb:" + s).utf8))
            return d.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// 用户添加过（或档案认出来）的一支录音笔。
    struct Entry: Codable, Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var vendorID: Int
        var productID: Int
        var serialHash: String?
        var productName: String?
        var profileId: String?
        var auto: Bool
        var added: Date

        /// 同一种型号、同一支笔（两边都有序列号摘要时才比）。
        func matches(_ i: Identity) -> Bool {
            guard i.vendorID == vendorID, i.productID == productID else { return false }
            if let a = serialHash, let b = i.serialHash { return a == b }
            return true
        }

        /// 放录音的文件夹名：去掉文件名里不能用的字符。
        var folderName: String { UsbRecorder.safeName(name) }
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = s.components(separatedBy: bad).joined().trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "U盘录音笔" : String(cleaned.prefix(40))
    }

    // MARK: 格式

    /// 本机转写和云端转写都能读的格式。
    static let supportedExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "flac", "aif", "aiff", "caf", "amr"]
    /// 录音笔常见、但现在转不了的格式：列出来，标「格式暂不支持」。
    static let unsupportedExtensions: Set<String> = ["wma", "opus", "ogg", "act", "dss", "ds2", "dvf", "msv"]
    /// 默认跳过的文件夹（放音乐的、系统的）。比较时不分大小写。
    static let skippedFolders: Set<String> = ["music", "musics", "song", "songs", "音乐", "system volume information",
                                              "$recycle.bin", "lost.dir", "android", "fseventsd", "trashes"]
    static let maxDepth = 6
    static let maxFiles = 20000

    // MARK: 录音

    struct Recording: Equatable, Sendable {
        let rel: String          // 相对盘根目录的路径
        let category: String     // 档案里的类别名，没有就是「录音」
        let created: Date?       // 从文件名（或修改时间）得出，笔上的时钟可能不准
        let fromName: Bool       // 时间是从文件名取的（否则是修改时间）
        let modified: Date
        let size: Int64
        let durationSec: Int
        var ext: String { (rel as NSString).pathExtension.lowercased() }
        var supported: Bool { UsbRecorder.supportedExtensions.contains(ext) }
        /// 同一路径的文件可能被覆盖，所以带上大小。
        var key: String { rel + "#" + String(size) }
        /// 2024 年以前的（时钟回到出厂时间）或比现在还晚一天以上的，时间不可信。
        func timeUncertain(now: Date = Date()) -> Bool {
            guard let c = created else { return true }
            return Calendar.current.component(.year, from: c) < 2024 || c > now.addingTimeInterval(86400)
        }
    }

    /// 盘里的音频文件（只走一遍目录，不读内容）。有档案就只看档案里的文件夹和格式。
    struct RawFile: Equatable, Sendable { let rel: String; let size: Int64; let modified: Date }

    static func scan(_ volume: URL, profile: DeviceProfile?) -> [RawFile] {
        let fm = FileManager.default
        let exts = profile?.extensions.map { Set($0.map { $0.lowercased() }) } ?? supportedExtensions.union(unsupportedExtensions)
        let skip = skippedFolders.union((profile?.exclude ?? []).map { $0.lowercased() })
        let roots = (profile?.audioRoots ?? []).isEmpty ? [""] : profile!.audioRoots!
        var out: [RawFile] = []
        func walk(_ rel: String, depth: Int) {
            guard depth <= maxDepth, out.count < maxFiles else { return }
            let url = rel.isEmpty ? volume : volume.appendingPathComponent(rel, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return }
            for n in names.sorted() where !n.hasPrefix(".") {
                let childRel = rel.isEmpty ? n : rel + "/" + n
                let child = volume.appendingPathComponent(childRel)
                guard let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
                if v.isDirectory == true {
                    if !skip.contains(n.lowercased()) { walk(childRel, depth: depth + 1) }
                } else if exts.contains((n as NSString).pathExtension.lowercased()) {
                    out.append(RawFile(rel: childRel, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
                    if out.count >= maxFiles { return }
                }
            }
        }
        for r in roots { walk(r, depth: 0) }
        return out
    }

    /// 走一遍目录、读出时长，新的在前。
    static func list(_ volume: URL, profile: DeviceProfile?) async -> [Recording] {
        var out: [Recording] = []
        for f in scan(volume, profile: profile) {
            let ext = (f.rel as NSString).pathExtension.lowercased()
            let dur = supportedExtensions.contains(ext) ? await duration(volume.appendingPathComponent(f.rel), ext: ext) : 0
            let t = date(rel: f.rel, pattern: profile?.timeFromName)
            let top = f.rel.split(separator: "/").first.map(String.init) ?? ""
            let cat = profile?.categories?[top] ?? "录音"
            out.append(Recording(rel: f.rel, category: cat, created: t ?? f.modified, fromName: t != nil, modified: f.modified,
                                 size: f.size, durationSec: dur))
        }
        return out.sorted { ($0.created ?? .distantPast, $0.rel) > ($1.created ?? .distantPast, $1.rel) }
    }

    static func duration(_ url: URL, ext: String) async -> Int {
        if ext == "wav", let info = C1Max.WavInfo.read(url), info.byteRate > 0 { return Int(info.dataSize / Int64(info.byteRate)) }
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return 0 }
        return max(0, Int(CMTimeGetSeconds(d)))
    }

    // MARK: 时间

    /// 没有档案时试的几种文件名（只看文件名和它上一层文件夹），越具体的越靠前。
    static let commonPatterns = [
        "yyyyMMdd/HH_mm_ss", "yyyyMMdd/HHmmss",
        "yyyy-MM-dd HH-mm-ss", "yyyy-MM-dd_HH-mm-ss", "yyyy-MM-dd-HH-mm-ss", "yyyy-MM-dd HH.mm.ss",
        "yyyyMMdd_HHmmss", "yyyyMMdd-HHmmss", "yyyyMMddHHmmss", "yyyyMMdd_HHmm", "yyyyMMdd-HHmm",
        "yyMMdd_HHmmss", "yyMMdd-HHmmss", "yyMMdd_HHmm", "yyMMdd-HHmm",
    ]

    /// 从路径（不含扩展名，最后两层）里按格式取时间；给了档案格式就只用它，否则依次试常见格式。认不出就是 nil。
    static func date(rel: String, pattern: String?) -> Date? {
        let noExt = (rel as NSString).deletingPathExtension
        let tail = noExt.split(separator: "/").suffix(2).joined(separator: "/")
        for p in pattern.map({ [$0] }) ?? commonPatterns {
            if let d = date(tail, pattern: p) { return d }
        }
        return nil
    }

    /// 占位只认 yyyy、yy、MM、dd、HH、mm、ss；格式不对返回 nil（档案校验也用它）。
    static func regex(for pattern: String) -> (NSRegularExpression, [String])? {
        guard !pattern.isEmpty, pattern.count <= 40 else { return nil }
        var re = "(?<![0-9])", order: [String] = []
        var rest = Substring(pattern)
        while !rest.isEmpty {
            if let tok = ["yyyy", "yy", "MM", "dd", "HH", "mm", "ss"].first(where: { rest.hasPrefix($0) }) {
                guard !order.contains(tok), !(tok == "yy" && order.contains("yyyy")) else { return nil }
                re += tok == "yyyy" ? "([0-9]{4})" : "([0-9]{2})"
                order.append(tok)
                rest = rest.dropFirst(tok.count)
            } else {
                let c = rest.first!
                guard !c.isLetter else { return nil }
                re += NSRegularExpression.escapedPattern(for: String(c))
                rest = rest.dropFirst()
            }
        }
        re += "(?![0-9])"
        let need: Set<String> = ["MM", "dd", "HH", "mm"]
        guard need.isSubset(of: order), order.contains("yyyy") || order.contains("yy"),
              let r = try? NSRegularExpression(pattern: re) else { return nil }
        return (r, order)
    }

    static func date(_ s: String, pattern: String) -> Date? {
        guard let (re, order) = regex(for: pattern) else { return nil }
        let ns = s as NSString
        // 取最后一处匹配（文件名里的时间一般在后面）
        guard let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        var v: [String: Int] = [:]
        for (i, tok) in order.enumerated() { v[tok] = Int(ns.substring(with: m.range(at: i + 1))) }
        var c = DateComponents()
        c.year = v["yyyy"] ?? v["yy"].map { 2000 + $0 }
        c.month = v["MM"]; c.day = v["dd"]; c.hour = v["HH"]; c.minute = v["mm"]; c.second = v["ss"] ?? 0
        guard let mo = c.month, (1...12).contains(mo), let d = c.day, (1...31).contains(d), let h = c.hour, (0...23).contains(h),
              let mi = c.minute, (0...59).contains(mi), (0...59).contains(c.second!) else { return nil }
        guard let date = Calendar.current.date(from: c), Calendar.current.component(.day, from: date) == d else { return nil }
        return date
    }

    // MARK: 挑新录音

    /// 自动导入哪些：能转的格式、没处理过、不是添加时就在笔里的、还没有转写记录的、不是刚改过的（可能还在写）、不太短的。
    /// 太短的单独列出（记成处理过）。
    static func pick(_ recs: [Recording], handled: Set<String>, before: Set<String>, jobKeys: Set<String>,
                     minDurationSec: Int, now: Date = Date()) -> (new: [Recording], tooShort: [Recording]) {
        let fresh = recs.filter {
            $0.supported && !handled.contains($0.key) && !before.contains($0.key) && !jobKeys.contains($0.key)
                && now.timeIntervalSince($0.modified) > 30
        }
        let minSec = max(1, minDurationSec)
        return (fresh.filter { $0.durationSec >= minSec }, fresh.filter { $0.durationSec < minSec })
    }

    /// 时钟停走（断电后接着走）的认法：上次读笔时还没有、时间却早于上次读笔（留一分钟余量）。
    static func clockBehind(_ recs: [Recording], seen: Set<String>, lastListed: Date?) -> Set<String> {
        guard let lastListed else { return [] }
        let limit = lastListed.addingTimeInterval(-60)
        return Set(recs.filter { !seen.contains($0.key) && $0.fromName && ($0.created.map { $0 < limit } ?? false) }.map(\.key))
    }

    // MARK: 拷到 Mac

    /// 「设备名_20261120_143005.mp3」；认不出时间的用原路径。
    static func fileName(_ r: Recording, device: String, created: Date?) -> String {
        let base = safeName(device).replacingOccurrences(of: " ", with: "")
        if let c = created { return base + "_" + DateFormatter.cached("yyyyMMdd_HHmmss").string(from: c) + "." + r.ext }
        return base + "_" + r.rel.replacingOccurrences(of: "/", with: "_")
    }

    /// 目标文件夹里不重名的位置。已有同样大小的同名文件就直接用它（之前拷过）。
    static func destination(name: String, size: Int64, in dir: URL) -> URL {
        let fm = FileManager.default
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let s = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if s == size { return url }
            url = dir.appendingPathComponent("\(stem)_\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return url
    }

    /// 先拷成 .part 再改名；WAV 文件头长度不对的在拷来的那份上改正（笔上的原文件不动）。
    static func copy(_ src: URL, to dst: URL) throws {
        if src.pathExtension.lowercased() == "wav" { return try C1Max.copy(src, to: dst) }
        let fm = FileManager.default
        let part = dst.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        try fm.copyItem(at: src, to: part)
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: part, to: dst)
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    // MARK: 脱敏的设备描述

    /// 名字的「样子」：数字换成 #，英文字母、空格和 _-. 以外的字符换成 *（连续的只留一个）。
    static func shape(_ s: String) -> String {
        var out = ""
        for ch in s {
            let c: Character = ch.isASCII && ch.isNumber ? "#" : (ch.isASCII && (ch.isLetter || " _-.".contains(ch))) ? ch : "*"
            if c == "*", out.last == "*" { continue }
            out.append(c)
        }
        return String(out.prefix(40))
    }

    /// 给用户看、由用户自己拷贝发给我们的设备描述。不含序列号、卷名、录音内容，文件夹和文件名只给「样子」。
    static func describe(identity: Identity, fileSystem: String?, capacityBytes: Int64?, files: [Recording]) -> String {
        var dirs: [String: (count: Int, names: [String: Int], exts: [String: Int])] = [:]
        for f in files {
            let parts = f.rel.split(separator: "/").map(String.init)
            let dir = parts.dropLast().map(shape).joined(separator: "/")
            let name = shape((parts.last.map { ($0 as NSString).deletingPathExtension }) ?? "")
            var e = dirs[dir] ?? (0, [:], [:])
            e.count += 1
            e.names[name, default: 0] += 1
            e.exts[f.ext, default: 0] += 1
            dirs[dir] = e
        }
        let layout: [[String: Any]] = dirs.sorted { $0.value.count > $1.value.count }.prefix(20).map { k, v in
            ["folder": k.isEmpty ? "(根目录)" : k, "files": v.count,
             "namePatterns": v.names.sorted { $0.value > $1.value }.prefix(3).map(\.key),
             "extensions": v.exts]
        }
        var obj: [String: Any] = [
            "about": "音录 · U 盘录音笔设备描述（已脱敏，不含序列号、卷名和录音内容）",
            "vendorID": String(format: "0x%04X", identity.vendorID),
            "productID": String(format: "0x%04X", identity.productID),
            "recordings": files.count,
            "layout": layout,
        ]
        if let n = identity.productName { obj["productName"] = n }
        if let m = identity.manufacturer { obj["manufacturer"] = m }
        if let f = fileSystem { obj["fileSystem"] = f }
        if let c = capacityBytes { obj["capacityGB"] = Int((Double(c) / 1e9).rounded()) }
        let named = files.filter(\.fromName).count
        obj["timeFromFileName"] = "\(named)/\(files.count)"
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }
}
