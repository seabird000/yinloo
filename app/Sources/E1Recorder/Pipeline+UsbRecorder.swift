import Foundation

/// 通用 U 盘录音笔：插上（只读挂载，见 `UsbDisk`）→ 列出笔里的录音 → 新录音拷到「录音目录/<设备名>/年-月」→ 按「服务选项」排队转写。
/// 添加时笔里已有的录音不自动转写（免得一次扣很多费用），在设备页逐条点「转写」。和 C1 Max 的做法一样，但记录分开。
struct UsbState: Equatable {
    var disks: [UsbDiskInfo] = []                       // 插着的 USB 盘（C1 Max 除外）
    var lists: [String: [UsbRecorder.Recording]] = [:]  // 录音笔编号 → 笔里的录音
    var syncing: Set<String> = []                       // 正在读的录音笔编号
    var importing: Set<String> = []                     // 正在拷的任务编号
    var copyDone = 0
    var copyTotal = 0
    var lastSync: Date?
}

extension Pipeline {
    // MARK: 添加过的录音笔（记在本机）

    /// 截图用的预览模式记在单独的设置域里，不碰真实设置。
    var usbDefaults: UserDefaults { UIPreview.enabled ? UserDefaults(suiteName: "app.e1recorder.preview")! : .standard }

    var usbEntries: [UsbRecorder.Entry] {
        get {
            guard let d = usbDefaults.data(forKey: "usbRecorders") else { return [] }
            return (try? JSONDecoder().decode([UsbRecorder.Entry].self, from: d)) ?? []
        }
        set {
            usbDefaults.set(try? JSONEncoder().encode(newValue), forKey: "usbRecorders")
            objectWillChange.send()
            pushUsbRules()
        }
    }

    /// 告诉 `UsbDisk` 哪些盘算录音笔。
    func pushUsbRules() {
        guard !UIPreview.enabled else { return }
        UsbDisk.shared.setRules(entries: usbEntries, profiles: profileLib.all)
    }

    private func key(_ entry: String, _ what: String) -> String { "usbRec.\(entry).\(what)" }
    private func set(_ entry: String, _ what: String) -> Set<String> {
        Set(usbDefaults.stringArray(forKey: key(entry, what)) ?? [])
    }
    private func store(_ s: Set<String>, _ entry: String, _ what: String) {
        usbDefaults.set(Array(s).sorted(), forKey: key(entry, what))
    }

    func usbHandled(_ e: String) -> Set<String> { set(e, "handled") }
    func usbBefore(_ e: String) -> Set<String> { set(e, "before") }
    func usbClockOff(_ e: String) -> Set<String> { set(e, "clockOff") }

    /// 这条录音的时间不能信：时钟回到出厂时间、比现在还晚，或认出笔的时钟慢了。
    func usbTimeOff(_ r: UsbRecorder.Recording, entry: String) -> Bool {
        r.timeUncertain() || usbClockOff(entry).contains(r.key)
    }

    func usbEntry(for disk: UsbDiskInfo) -> UsbRecorder.Entry? { usbEntries.first { $0.matches(disk.identity) } }
    func usbDisk(for entry: UsbRecorder.Entry) -> UsbDiskInfo? { usb.disks.first { entry.matches($0.identity) && $0.guarded } }
    func usbProfile(for entry: UsbRecorder.Entry) -> DeviceProfile? { profileLib.profile(entry.profileId) }

    /// 插着、还没添加的 USB 盘（「添加」页列出来的）。
    var usbAddable: [UsbDiskInfo] { usb.disks.filter { usbEntry(for: $0) == nil } }

    // MARK: 插拔（UsbDisk 在主线程上调）

    func usbDisksChanged(_ snap: [UsbDiskInfo]) {
        let wasReady = Set(usb.disks.filter(\.ready).map(\.bsd))
        usb.disks = snap
        // 档案认出来、还没记过的：自动记下（名字用档案里的）
        var entries = usbEntries, added = false
        for d in snap where d.guarded && !entries.contains(where: { $0.matches(d.identity) }) {
            guard let p = profileLib.match(d.identity) else { continue }
            entries.append(UsbRecorder.Entry(id: Self.newUsbId(), name: p.name, vendorID: d.identity.vendorID, productID: d.identity.productID,
                                             serialHash: d.identity.serialHash, productName: d.identity.productName, profileId: p.id,
                                             auto: true, added: Date()))
            added = true
            Log.sync.notice("U 盘录音笔：档案认出 \(p.id, privacy: .public)")
        }
        if added { usbEntries = entries }
        // 拔掉的那台不再列录音
        let live = Set(snap.filter(\.guarded).compactMap { usbEntry(for: $0)?.id })
        usb.lists = usb.lists.filter { live.contains($0.key) }
        for d in snap where d.ready && !wasReady.contains(d.bsd) {
            Task { await syncUsb(d.bsd) }
        }
    }

    static func newUsbId() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased() }

    // MARK: 添加、改名、移除

    /// 把一块插着的盘添加成录音笔：记下它，改成只读挂载；挂好后第一次读笔，已有的录音记成「之前的」。
    func addUsbRecorder(_ disk: UsbDiskInfo, name: String) {
        let p = profileLib.match(disk.identity)
        var entries = usbEntries
        entries.append(UsbRecorder.Entry(id: Self.newUsbId(), name: UsbRecorder.safeName(name), vendorID: disk.identity.vendorID,
                                         productID: disk.identity.productID, serialHash: disk.identity.serialHash,
                                         productName: disk.identity.productName, profileId: p?.id, auto: true, added: Date()))
        usbEntries = entries
    }

    func renameUsbRecorder(_ id: String, to name: String) {
        usbEntries = usbEntries.map { var e = $0; if e.id == id { e.name = UsbRecorder.safeName(name) }; return e }
    }

    func setUsbAuto(_ id: String, _ on: Bool) {
        usbEntries = usbEntries.map { var e = $0; if e.id == id { e.auto = on }; return e }
        if on, let e = usbEntries.first(where: { $0.id == id }), let d = usbDisk(for: e), d.ready { Task { await syncUsb(d.bsd) } }
    }

    /// 移除：忘掉这支笔和它的记录（已转写的纪要和拷来的录音不动）。笔上的文件本来就没动过。
    func removeUsbRecorder(_ id: String) {
        for w in ["handled", "before", "clockOff", "listedKeys", "listedAt"] { usbDefaults.removeObject(forKey: key(id, w)) }
        usb.lists[id] = nil
        usbEntries = usbEntries.filter { $0.id != id }
    }

    // MARK: 设备档案

    func loadProfiles() {
        profileLib = DeviceProfiles.loadCached()
    }

    /// 读一次云端档案；读到新的就换上，并重新告诉 `UsbDisk`。
    func refreshProfiles() async {
        guard !UIPreview.enabled, let f = await DeviceProfiles.fetch() else { return }
        profileLib.cloud = f.profiles
        profileLib.cloudUpdated = f.updated
        profileLib.fetchedAt = Date()
        Log.sync.info("设备档案已更新：\(f.profiles.count, privacy: .public) 份")
        pushUsbRules()
    }

    /// 启动时读一次，之后每天一次；插着的录音笔每分钟看一次有没有新录音（有的笔插着线也能录）。
    func usbLoop() async {
        var lastFetch = Date.distantPast
        while true {
            if Date().timeIntervalSince(lastFetch) > 86400 { lastFetch = Date(); await refreshProfiles() }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            for d in usb.disks where d.ready { await syncUsb(d.bsd) }
        }
    }

    // MARK: 同步

    /// 读一遍笔里的录音；这支笔开着自动转写时（或 `manual`），把新录音拷过来排队。
    func syncUsb(_ bsd: String, manual: Bool = false) async {
        guard !UIPreview.enabled, let disk = usb.disks.first(where: { $0.bsd == bsd }), disk.ready, let volume = disk.path,
              let entry = usbEntry(for: disk), !usb.syncing.contains(entry.id) else { return }
        usb.syncing.insert(entry.id)
        defer { usb.syncing.remove(entry.id); usb.copyDone = 0; usb.copyTotal = 0 }
        let profile = usbProfile(for: entry).flatMap { $0.volumeMatches(volume) ? $0 : nil }
        let recs = await Task.detached(priority: .utility) { await UsbRecorder.list(volume, profile: profile) }.value
        guard usb.disks.contains(where: { $0.bsd == bsd && $0.ready }) else { return }   // 读的时候拔了

        let d = usbDefaults
        let behind = UsbRecorder.clockBehind(recs, seen: set(entry.id, "listedKeys"), lastListed: d.object(forKey: key(entry.id, "listedAt")) as? Date)
        if !behind.isEmpty {
            store(usbClockOff(entry.id).union(behind), entry.id, "clockOff")
            Log.sync.notice("U 盘录音笔：\(behind.count, privacy: .public) 条新录音的时间早于上次读笔，笔的时钟慢了")
        }
        store(Set(recs.map(\.key)), entry.id, "listedKeys")
        d.set(Date(), forKey: key(entry.id, "listedAt"))
        usb.lists[entry.id] = recs
        usb.lastSync = Date()
        if d.object(forKey: key(entry.id, "before")) == nil {
            store(Set(recs.map(\.key)), entry.id, "before")
            Log.sync.notice("U 盘录音笔第一次读：笔里已有 \(recs.count, privacy: .public) 条，不自动转写")
        }
        guard entry.auto || manual else { return }

        var handled = usbHandled(entry.id)
        let prefix = "ud:\(entry.id):"
        let jobKeys = Set(jobs.filter { $0.id.hasPrefix(prefix) }.map { String($0.id.dropFirst(prefix.count)) })
        let (fresh, short) = UsbRecorder.pick(recs, handled: handled, before: usbBefore(entry.id), jobKeys: jobKeys,
                                              minDurationSec: settings.minDurationSec)
        for r in short { handled.insert(r.key) }
        store(handled, entry.id, "handled")
        guard !fresh.isEmpty else { return }
        usb.copyTotal = fresh.count
        var added = 0
        for r in fresh.reversed() {            // 先录的先拷
            guard usb.disks.contains(where: { $0.bsd == bsd && $0.ready }) else { break }
            usb.copyDone = added
            do {
                try await importUsb(r, entry: entry, from: volume)
                added += 1
            } catch {
                Log.sync.error("U 盘录音笔拷贝失败：\(error.localizedDescription, privacy: .public)")
                let folderOK = FileManager.default.fileExists(atPath: (settings.audioFolder as NSString).deletingLastPathComponent)
                lastMessage = folderOK ? "\(entry.name) 拷贝失败：\(error.localizedDescription)"
                                       : "录音目录现在用不了（移动硬盘没接？），接上后点「立即同步」"
                break
            }
        }
        usb.copyDone = added
        if added > 0 {
            Log.sync.notice("U 盘录音笔：新增 \(added, privacy: .public) 条")
            processQueue()
        }
    }

    /// 拷一条到「录音目录/<设备名>/年-月」并排队。时间不可信时用拷过来的时间，纪要里提示核对。
    func importUsb(_ r: UsbRecorder.Recording, entry: UsbRecorder.Entry, from volume: URL) async throws {
        let uncertain = usbTimeOff(r, entry: entry.id)
        let created = uncertain ? Date() : (r.created ?? Date())
        let month = DateFormatter.cached("yyyy-MM").string(from: created)
        let dir = URL(fileURLWithPath: settings.audioFolder).appendingPathComponent("\(entry.folderName)/\(month)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = UsbRecorder.destination(name: UsbRecorder.fileName(r, device: entry.name, created: uncertain ? nil : created), size: r.size, in: dir)
        let src = volume.appendingPathComponent(r.rel)
        if !FileManager.default.fileExists(atPath: dst.path) {
            try await Task.detached(priority: .utility) { try UsbRecorder.copy(src, to: dst) }.value
        }
        let id = "ud:\(entry.id):" + r.key
        let title = uncertain ? "\(r.category)（笔上时间不准）" : "\(r.category) " + DateFormatter.cached("M月d日 HH:mm").string(from: created)
        jobs.removeAll { $0.id == id }
        jobs.insert(Job(id: id, title: title, scene: r.category, source: entry.name.contains("录音笔") ? entry.name : "\(entry.name) 录音笔", created: created,
                        durationSec: r.durationSec, marks: [], audioPath: dst.path, listenPath: nil, timeUncertain: uncertain,
                        state: .queued, updated: Date()), at: 0)
        var h = usbHandled(entry.id); h.insert(r.key); store(h, entry.id, "handled")
        save()
    }

    /// 设备页上点「转写」：这一条照转，不管它是不是添加时就在笔里。
    func transcribeUsb(_ r: UsbRecorder.Recording, entry: UsbRecorder.Entry) {
        guard let disk = usbDisk(for: entry), disk.ready, let volume = disk.path else { return }
        let id = "ud:\(entry.id):" + r.key
        guard !usb.importing.contains(id) else { return }
        usb.importing.insert(id)
        Task {
            defer { usb.importing.remove(id) }
            do {
                try await importUsb(r, entry: entry, from: volume)
                processQueue()
            } catch {
                lastMessage = "\(entry.name) 拷贝失败：\(error.localizedDescription)"
                notify("\(entry.name) 拷贝失败", error.localizedDescription, jobId: "")
            }
        }
    }

    /// 笔里一条录音现在怎样，给设备页的列表用。
    enum UsbRecState: Equatable { case job(Job.State), importing, unsupported, recording, tooShort, waiting, notTaken, removed }

    func usbState(_ r: UsbRecorder.Recording, entry: UsbRecorder.Entry) -> UsbRecState {
        let id = "ud:\(entry.id):" + r.key
        if usb.importing.contains(id) { return .importing }
        if let j = jobs.first(where: { $0.id == id }) { return .job(j.state) }
        if !r.supported { return .unsupported }
        if Date().timeIntervalSince(r.modified) <= 30 { return .recording }
        if r.durationSec < max(1, settings.minDurationSec) { return .tooShort }
        if usbHandled(entry.id).contains(r.key) { return .removed }
        if usbBefore(entry.id).contains(r.key) || !entry.auto { return .notTaken }
        return .waiting
    }

    /// 设备页、面板用的一行状态（所有 U 盘录音笔合在一起）。
    var usbStatus: DeviceStatus {
        let S = Pipeline.status
        let entries = usbEntries
        let connected = usb.disks.filter(\.guarded)
        if let d = connected.first(where: { $0.problem != nil }) { return S("出错", .problem, "出错", d.problem, nil, "") }
        if let d = connected.first(where: \.ready), let e = usbEntry(for: d) {
            let recs = usb.lists[e.id] ?? []
            let off = recs.filter { usbTimeOff($0, entry: e.id) }.count
            let warn = off > 0 ? "\(off) 条录音时间不准" : nil
            if usb.copyTotal > 0 {
                let what = "正在拷贝 \(min(usb.copyDone + 1, usb.copyTotal)) / \(usb.copyTotal)"
                return S("已连接", .ok, "\(e.name) · 只读", what, warn, what)
            }
            return S("已连接", .ok, "\(e.name) · 只读", Pipeline.countAndSync(usb.lists[e.id]?.count, usb.lastSync), warn, "")
        }
        if !connected.isEmpty { return S("连接中", .waiting, "USB 已连接", "正在以只读方式挂载…", nil, "") }
        if entries.isEmpty { return S("未添加", .idle, "未添加", "插上普通录音笔，点进来添加", nil, "") }
        return S("未连接", .idle, "已添加 \(entries.count) 台", "插上数据线即自动同步", nil, "")
    }

    var usbAnyReady: Bool { usb.disks.contains(where: \.ready) }

    /// 立即同步：插着的每支录音笔都读一遍。
    func syncAllUsb(manual: Bool) async {
        for d in usb.disks where d.ready { await syncUsb(d.bsd, manual: manual) }
    }

    /// 截图用的示例数据（-previewUsb YES 时插着一支「示例录音笔」，另有一支没插的）。
    func previewUsb() {
        guard UserDefaults.standard.bool(forKey: "previewUsb"), usb.disks.isEmpty else { return }
        let id = UsbRecorder.Identity(vendorID: 0x1234, productID: 0x5678, productName: "Voice Recorder", manufacturer: "Example", serialHash: "0000000000000000")
        if usbEntries.isEmpty {
            usbDefaults.set(try? JSONEncoder().encode([
                UsbRecorder.Entry(id: "demo1", name: "示例录音笔", vendorID: 0x1234, productID: 0x5678, serialHash: "0000000000000000",
                                  productName: "Voice Recorder", profileId: nil, auto: true, added: Date()),
                UsbRecorder.Entry(id: "demo2", name: "办公室的录音笔", vendorID: 0x2345, productID: 0x0001, serialHash: nil,
                                  productName: nil, profileId: nil, auto: false, added: Date()),
            ]), forKey: "usbRecorders")
        }
        usb.disks = [UsbDiskInfo(bsd: "disk9s1", identity: id, volumeName: "VOICE", fileSystem: "msdos", sizeBytes: 16_000_000_000,
                                 path: URL(fileURLWithPath: "/Volumes/VOICE"), readOnly: true, guarded: true),
                     UsbDiskInfo(bsd: "disk8s1", identity: .init(vendorID: 0x0781, productID: 0x5581, productName: "USB Flash"),
                                 volumeName: "工作资料", fileSystem: "exfat", sizeBytes: 64_000_000_000, path: URL(fileURLWithPath: "/Volumes/X"))]
        let base = Calendar.current.date(bySettingHour: 9, minute: 40, second: 0, of: Date())!
        let old = Date().addingTimeInterval(-7200)
        usb.lists["demo1"] = [("RECORD", 0.0, 2860, "mp3"), ("RECORD", 1, 1520, "mp3"), ("RECORD", 2, 3, "mp3"), ("VOICE", 3, 640, "wma")]
            .enumerated().map { i, r in
                let t = base.addingTimeInterval(-r.1 * 86400 - Double(i) * 3700)
                return UsbRecorder.Recording(rel: "\(r.0)/" + DateFormatter.cached("yyyyMMdd_HHmmss").string(from: t) + ".\(r.3)", category: "录音",
                                             created: t, fromName: true, modified: old, size: Int64(r.2) * 16000, durationSec: r.3 == "wma" ? 0 : r.2)
            }
        usb.lastSync = Calendar.current.date(bySettingHour: 10, minute: 58, second: 0, of: Date())
        if let first = usb.lists["demo1"]?.first, !jobs.contains(where: { $0.id == "ud:demo1:" + first.key }) {
            jobs.append(Job(id: "ud:demo1:" + first.key, title: "录音 " + DateFormatter.cached("M月d日 HH:mm").string(from: first.created!), scene: "录音",
                            source: "示例录音笔", created: first.created!, durationSec: first.durationSec, marks: [],
                            audioPath: "/tmp/preview-usb.mp3", listenPath: nil, timeUncertain: false, state: .done, updated: Date()))
        }
        var before = Set<String>(); if let l = usb.lists["demo1"] { before = [l[1].key] }
        usbDefaults.set(Array(before), forKey: "usbRec.demo1.before")
    }
}
