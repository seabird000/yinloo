import Foundation

/// 搜狗 C1 Max：插上 USB（只读挂载，见 `C1MaxDisk`）→ 列出笔里的录音 → 新录音拷到录音目录 → 按「服务选项」的设置排队转写。
/// 第一次插上时笔里已有的录音不自动转写（免得一次扣很多费用），在设备页逐条点「转写」。
struct C1Status: Equatable {
    enum Phase: Equatable { case absent, mounting, mounted, unmounted, ejected, problem(String) }
    var phase: Phase = .absent
    var volume: URL?
    var freeBytes: Int64?
    var notC1 = false                  // 挂上了，但目录不像 C1 Max
}

extension Pipeline {
    // MARK: 记在本机的

    /// 已经拷过（或判定太短、或从转写记录里移除）的录音：不再自动拷。
    var c1Handled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "c1MaxHandled") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "c1MaxHandled") }
    }
    /// 第一次插上时笔里已有的录音。
    var c1Before: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "c1MaxBefore") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "c1MaxBefore") }
    }
    /// 时间确定不准的录音（笔的时钟慢了）。
    var c1ClockOff: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "c1MaxClockOff") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "c1MaxClockOff") }
    }
    /// 这条录音的时间不能信：2024 年以前（时钟回到了 2020-01-01），或者认出笔的时钟慢了。
    func c1TimeOff(_ r: C1Max.Recording) -> Bool { r.timeUncertain || c1ClockOff.contains(r.key) }

    /// 插过 C1 Max：菜单栏面板从此列出它。
    var c1EverSeen: Bool {
        get { UserDefaults.standard.bool(forKey: "c1MaxSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "c1MaxSeen") }
    }

    // MARK: 插拔（C1MaxDisk 在主线程上调）

    func c1Attached() {
        if c1.phase != .mounted { c1.phase = .mounting }
        if !c1EverSeen { c1EverSeen = true; objectWillChange.send() }
    }

    func c1Mounted(_ url: URL) {
        let again = c1.volume == url && c1.phase == .mounted
        c1.phase = .mounted
        c1.volume = url
        c1.freeBytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
        if !c1EverSeen { c1EverSeen = true }
        if !again { Task { await syncC1Max() } }
    }

    func c1Unmounted() {
        c1.phase = .unmounted
        c1.volume = nil
    }

    func c1Detached() {
        c1 = C1Status()
        c1List = []
        c1CopyDone = 0; c1CopyTotal = 0
    }

    func c1Ejected() {
        c1 = C1Status(phase: .ejected)
        c1List = []
    }

    func c1Failed(_ why: String) {
        c1.phase = .problem(why)
    }

    // MARK: 同步

    /// 读一遍笔里的录音；自动导入打开时（或 `manual`），把新录音拷过来排队。
    func syncC1Max(manual: Bool = false) async {
        guard let volume = c1.volume, !c1Syncing, !UIPreview.enabled else { return }
        c1Syncing = true
        defer { c1Syncing = false; c1CopyDone = 0; c1CopyTotal = 0 }
        let (ok, recs) = await Task.detached(priority: .utility) { (C1Max.looksLikeC1Max(volume), C1Max.list(volume)) }.value
        c1.notC1 = !ok
        guard ok else {
            Log.sync.error("C1 Max 的存储里没有录音文件夹")
            return
        }
        // 上次读笔时还没有、时间却更早的：笔的时钟慢了
        let d = UserDefaults.standard
        let behind = C1Max.clockBehind(recs, seen: Set(d.stringArray(forKey: "c1MaxListedKeys") ?? []),
                                       lastListed: d.object(forKey: "c1MaxListedAt") as? Date)
        if !behind.isEmpty {
            c1ClockOff.formUnion(behind)
            Log.sync.notice("C1 Max：\(behind.count, privacy: .public) 条新录音的时间早于上次读笔，笔的时钟慢了")
        }
        d.set(recs.map(\.key), forKey: "c1MaxListedKeys")
        d.set(Date(), forKey: "c1MaxListedAt")
        c1List = recs
        if case .problem = c1.phase { c1.phase = .mounted }
        c1.freeBytes = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
        if UserDefaults.standard.object(forKey: "c1MaxBefore") == nil {
            // 第一次插上：笔里已有的先不动
            c1Before = Set(recs.map(\.key))
            Log.sync.notice("C1 Max 第一次插上：笔里已有 \(recs.count, privacy: .public) 条，不自动转写")
        }
        c1LastSync = Date()
        guard settings.c1MaxAuto || manual else { return }

        var handled = c1Handled
        let jobKeys = Set(jobs.filter { $0.id.hasPrefix("c1:") }.map { String($0.id.dropFirst(3)) })
        let (fresh, short) = C1Max.pick(recs, handled: handled, before: c1Before, jobKeys: jobKeys, minDurationSec: settings.minDurationSec)
        for r in short { handled.insert(r.key) }
        c1Handled = handled
        guard !fresh.isEmpty else { return }
        c1CopyTotal = fresh.count
        var added = 0
        for r in fresh.reversed() {            // 先录的先拷
            guard c1.volume == volume else { break }   // 中途拔了
            c1CopyDone = added
            do {
                try await importC1(r, from: volume)
                added += 1
            } catch {
                Log.sync.error("C1 Max 拷贝失败：\(error.localizedDescription, privacy: .public)")
                lastMessage = "C1 Max 拷贝失败：\(error.localizedDescription)"
                let folderOK = FileManager.default.fileExists(atPath: (settings.audioFolder as NSString).deletingLastPathComponent)
                c1.phase = .problem(folderOK ? "拷贝失败：\(error.localizedDescription)"
                                             : "录音目录现在用不了（移动硬盘没接？），接上后点「立即同步」")
                break
            }
        }
        c1CopyDone = added
        if added > 0 {
            Log.sync.notice("C1 Max：新增 \(added, privacy: .public) 条")
            processQueue()
        }
    }

    /// 拷一条到「录音目录/搜狗C1Max/年-月」并排队。笔上的时间不可信时，用拷过来的时间，纪要里提示核对。
    func importC1(_ r: C1Max.Recording, from volume: URL) async throws {
        let uncertain = c1TimeOff(r)
        let created = uncertain ? Date() : r.created!
        let month = DateFormatter.cached("yyyy-MM").string(from: created)
        let dir = URL(fileURLWithPath: settings.audioFolder).appendingPathComponent("\(DeviceKind.c1Max.folderName)/\(month)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = C1Max.destination(for: r, in: dir)
        let src = volume.appendingPathComponent(r.rel)
        if !FileManager.default.fileExists(atPath: dst.path) {
            try await Task.detached(priority: .utility) { try C1Max.copy(src, to: dst) }.value
        }
        let id = "c1:" + r.key
        let title = uncertain ? "\(r.category)（笔上时间不准）" : "\(r.category) " + DateFormatter.cached("M月d日 HH:mm").string(from: created)
        jobs.removeAll { $0.id == id }
        jobs.insert(Job(id: id, title: title, scene: r.category, source: "搜狗 C1 Max 录音笔", created: created,
                        durationSec: r.durationSec, marks: [], audioPath: dst.path, listenPath: nil, timeUncertain: uncertain,
                        state: .queued, updated: Date()), at: 0)
        c1Handled.insert(r.key)
        save()
    }

    /// 设备页上点「转写」：这一条照转，不管它是不是第一次插上时就在笔里。
    func transcribeC1(_ r: C1Max.Recording) {
        guard let volume = c1.volume, !c1Importing.contains(r.key) else { return }
        c1Importing.insert(r.key)
        Task {
            defer { c1Importing.remove(r.key) }
            do {
                try await importC1(r, from: volume)
                processQueue()
            } catch {
                lastMessage = "C1 Max 拷贝失败：\(error.localizedDescription)"
                notify("C1 Max 拷贝失败", error.localizedDescription, jobId: "")
            }
        }
    }

    /// 笔里一条录音现在怎样，给设备页的列表用。
    enum C1RecState: Equatable { case job(Job.State), importing, tooShort, waiting, notTaken, removed }

    func c1State(_ r: C1Max.Recording) -> C1RecState {
        if c1Importing.contains(r.key) { return .importing }
        if let j = jobs.first(where: { $0.id == "c1:" + r.key }) { return .job(j.state) }
        if r.durationSec < max(1, settings.minDurationSec) { return .tooShort }
        if c1Handled.contains(r.key) { return .removed }
        if c1Before.contains(r.key) || !settings.c1MaxAuto { return .notTaken }
        return .waiting
    }

    /// 时间不可信的录音有几条。
    var c1UncertainCount: Int { c1List.filter { c1TimeOff($0) }.count }

    var c1Status: DeviceStatus {
        let S = Pipeline.status
        switch c1.phase {
        case .absent: return S("未连接", .idle, "未连接", "插上数据线即自动同步", nil, "")
        case .ejected: return S("已推出", .idle, "已推出", "可以拔下数据线了", nil, "")
        case .mounting: return S("连接中", .waiting, "USB 已连接", "正在以只读方式挂载…", nil, "")
        case .unmounted: return S("已卸下", .waiting, "USB 已连接", "存储已卸下，重新插上后继续", nil, "")
        case .problem(let why): return S("出错", .problem, "出错", why, nil, "")
        case .mounted:
            if c1.notC1 { return S("出错", .problem, "出错", "存储里没有 C1 Max 的录音文件夹", nil, "") }
            let warn = c1UncertainCount > 0 ? "\(c1UncertainCount) 条录音时间不准" : nil
            if c1CopyTotal > 0 {
                let what = "正在拷贝 \(min(c1CopyDone + 1, c1CopyTotal)) / \(c1CopyTotal)"
                return S("已连接", .ok, "USB 已连接 · 只读", what, warn, what)
            }
            return S("已连接", .ok, "USB 已连接 · 只读", Pipeline.countAndSync(c1List.count, c1LastSync), warn, "")
        }
    }

    /// 截图用的示例数据（-previewC1 YES 时插着，否则未连接）。
    func previewC1() {
        guard UserDefaults.standard.bool(forKey: "previewC1") else { return }
        guard c1.phase != .mounted else { return }
        c1 = C1Status(phase: .mounted, volume: URL(fileURLWithPath: "/Volumes/NO NAME"), freeBytes: 29_300_000_000)
        let base = Calendar.current.date(bySettingHour: 10, minute: 2, second: 0, of: Date())!
        c1List = [("MEETING", "会议", 0.0, 3126), ("INTERVIEW", "采访", 1, 1840), ("MEETING", "会议", 2, 6), ("MEMO", "备忘", 3, 95)]
            .enumerated().map { i, r in
                let t = base.addingTimeInterval(-r.2 * 86400 - Double(i) * 3700)
                let day = DateFormatter.cached("yyyyMMdd").string(from: t), tm = DateFormatter.cached("HH_mm_ss").string(from: t)
                return C1Max.Recording(rel: "\(r.0)/\(day)/\(tm).wav", category: r.1, created: t, size: Int64(r.3) * 32000 + 44, durationSec: r.3)
            }
        c1LastSync = Calendar.current.date(bySettingHour: 10, minute: 58, second: 0, of: Date())
        if let first = c1List.first, !jobs.contains(where: { $0.id == "c1:" + first.key }) {
            jobs.append(Job(id: "c1:" + first.key, title: "会议 " + DateFormatter.cached("M月d日 HH:mm").string(from: first.created!), scene: "会议",
                            source: "搜狗 C1 Max 录音笔", created: first.created!, durationSec: first.durationSec, marks: [],
                            audioPath: "/tmp/preview-c1.wav", listenPath: nil, timeUncertain: false, state: .done, updated: Date()))
        }
    }
}
