import Foundation

/// New recordings in Apple's Voice Memos, transcribed like the pen's: found, copied to the audio folder, queued.
extension Pipeline {
    /// What the last look at Voice Memos found, for Preferences › 设备.
    struct MemoScan: Equatable {
        var at: Date
        var total = 0            // recordings Voice Memos lists (not counting 最近删除)
        var before = 0           // of those, made before the switch was turned on
        var settling = 0         // still being recorded or still arriving from iPhone
        var problem: Problem?
        enum Problem: Equatable { case noAccess, notFound, audioFolder, failed(String) }
    }

    /// Voice Memos recordings already taken (or removed from the list afterwards): never taken again automatically.
    var memoHandled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "voiceMemosHandled") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "voiceMemosHandled") }
    }

    /// Looks at Voice Memos. With the switch on, new recordings are taken; with it off (`force` from the device
    /// page), the list is only refreshed. Skips the work when nothing in Voice Memos' folder changed and nothing is
    /// waiting to settle.
    func scanVoiceMemos(force: Bool = false) async {
        guard !memoScanning, !UIPreview.enabled else { return }
        let auto = settings.voiceMemos
        guard auto || force else { return }
        memoScanning = true
        lastMemoScan = Date()
        defer { memoScanning = false }
        let sig = VoiceMemos.signature()
        if !force, sig != nil, sig == memoSignature, memoSizes.isEmpty, memoScan?.problem == nil { return }

        let memos: [VoiceMemos.Memo]
        do {
            memos = try await Task.detached(priority: .utility) { try VoiceMemos.list() }.value
        } catch {
            let p: MemoScan.Problem
            switch error as? VoiceMemos.Problem {
            case .noAccess?: p = .noAccess
            case .notFound?: p = .notFound
            case .unreadable(let why)?: p = .failed(why)
            case nil: p = .failed(error.localizedDescription)
            }
            if memoScan?.problem != p { Log.sync.error("读取语音备忘录失败：\(String(describing: p), privacy: .public)") }
            memoScan = MemoScan(at: Date(), problem: p)
            memoList = []
            return
        }
        memoSignature = sig
        let live = memos.filter { !$0.deleted }
        memoList = live.sorted { $0.created > $1.created }
        let since = settings.voiceMemosSince ?? Date()
        var scan = MemoScan(at: Date(), total: live.count, before: live.filter { $0.created < since }.count)
        guard auto else { memoSizes = [:]; memoScan = scan; return }
        if settings.voiceMemosSince == nil { settings.voiceMemosSince = since }

        var handled = memoHandled
        // Recordings already in the list count as handled too (e.g. after the handled list was reset).
        for j in jobs where j.id.hasPrefix("vm:") { handled.insert(String(j.id.dropFirst(3))) }
        let files = await Task.detached(priority: .utility) { VoiceMemos.fileStates(live.map(\.file)) }.value
        let (ready, settling) = VoiceMemos.pick(live, since: since, handled: handled, minDurationSec: settings.minDurationSec,
                                                files: files, lastSizes: memoSizes, now: Date())
        memoSizes = settling
        scan.settling = settling.count

        var added = 0
        for m in ready {
            do {
                if try await importMemo(m) { added += 1 }
            } catch {
                // Audio folder on a drive that isn't plugged in, disk full…: keep it waiting and try again next round.
                memoSizes[m.file] = files[m.file]?.size
                scan.settling = memoSizes.count
                scan.problem = .audioFolder
                Log.sync.error("语音备忘录拷贝失败：\(error.localizedDescription, privacy: .public)")
                break
            }
        }
        memoScan = scan
        if added > 0 {
            Log.sync.notice("语音备忘录：新增 \(added, privacy: .public) 条")
            processQueue()
        }
    }

    /// Copies one recording into the audio folder and queues it. False when it turned out too short to transcribe.
    @discardableResult
    func importMemo(_ m: VoiceMemos.Memo) async throws -> Bool {
        let month = DateFormatter.cached("yyyy-MM").string(from: m.created)
        let dir = URL(fileURLWithPath: settings.audioFolder).appendingPathComponent("\(DeviceKind.voiceMemos.folderName)/\(month)", isDirectory: true)
        let dst = dir.appendingPathComponent(((m.file as NSString).deletingPathExtension) + ".m4a")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: dst.path) { try await VoiceMemos.export(m.file, to: dst) }
        } catch {
            try? FileManager.default.removeItem(at: dst)
            throw error
        }
        var duration = m.durationSec
        if duration < 0 {
            duration = await VoiceMemos.duration(of: dst)
            if duration < max(1, settings.minDurationSec) {
                try? FileManager.default.removeItem(at: dst)
                memoHandled.insert(m.file)
                return false
            }
        }
        jobs.removeAll { $0.id == "vm:\(m.file)" }
        jobs.insert(Job(id: "vm:\(m.file)", title: Self.memoTitle(m), scene: "会议", source: "语音备忘录", created: m.created,
                        durationSec: duration, marks: [], audioPath: dst.path, listenPath: nil, timeUncertain: false,
                        state: .queued, updated: Date()), at: 0)
        memoHandled.insert(m.file)
        save()
        return true
    }

    static func memoTitle(_ m: VoiceMemos.Memo) -> String {
        m.title.isEmpty ? "语音备忘录 " + DateFormatter.cached("M月d日 HH:mm").string(from: m.created) : m.title
    }

    /// 「转写」 on a recording the switch doesn't cover (made before it was turned on, removed from the list, or with
    /// the switch off): the user asked for this one, so it goes regardless.
    func transcribeMemo(_ m: VoiceMemos.Memo) {
        guard !memoImporting.contains(m.file) else { return }
        memoImporting.insert(m.file)
        Task {
            defer { memoImporting.remove(m.file) }
            if UIPreview.enabled { try? await Task.sleep(nanoseconds: 800_000_000); return }
            do {
                if try await importMemo(m) { processQueue() } else { lastMessage = "这条录音太短，不转写" }
            } catch {
                lastMessage = "语音备忘录拷贝失败：\(error.localizedDescription)"
                notify("语音备忘录拷贝失败", error.localizedDescription, jobId: "")
            }
        }
    }

    /// Where one Voice Memos recording stands, for the device page's list.
    enum MemoState: Equatable { case job(Job.State), importing, settling, tooShort, waiting, notTaken, removed }

    func memoState(_ m: VoiceMemos.Memo) -> MemoState {
        if memoImporting.contains(m.file) { return .importing }
        if let j = jobs.first(where: { $0.id == "vm:\(m.file)" }) { return .job(j.state) }
        if memoHandled.contains(m.file) { return .removed }
        if m.durationSec >= 0 && m.durationSec < max(1, settings.minDurationSec) { return .tooShort }
        if settings.voiceMemos, m.created >= (settings.voiceMemosSince ?? .distantFuture) {
            return memoSizes[m.file] != nil ? .settling : .waiting
        }
        return .notTaken
    }
}
