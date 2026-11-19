import Foundation

/// 本机模型的下载状态，给服务选项页和「本机模型」页用。同一时间只下一个模型。
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum State: Equatable {
        case notInstalled
        /// 下了一部分，暂停着（退出应用再打开也是这个状态）
        case paused(done: Int64, total: Int64)
        case downloading(done: Int64, total: Int64, bytesPerSec: Double)
        case unpacking
        case installed(bytes: Int64)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    private var running: (id: String, task: Task<Void, Never>)?

    init() { refresh() }

    func state(_ m: LocalModel) -> State { states[m.id] ?? .notInstalled }
    var isBusy: Bool { running != nil }

    /// 按磁盘上的实际情况重算（启动时、删除后）
    func refresh() {
        for m in LocalModels.all where running?.id != m.id {
            states[m.id] = previewState(m) ?? diskState(m)
        }
    }

    /// 截图用：-previewModel downloading|paused|installed 让 X-ASR 显示成这个状态（只在内存里，不碰磁盘）
    private func previewState(_ m: LocalModel) -> State? {
        guard UIPreview.enabled, m == LocalModels.xasr, let v = UserDefaults.standard.string(forKey: "previewModel") else { return nil }
        switch v {
        case "downloading": return .downloading(done: m.downloadSize * 37 / 100, total: m.downloadSize, bytesPerSec: 4_200_000)
        case "paused": return .paused(done: m.downloadSize * 37 / 100, total: m.downloadSize)
        case "installed": return .installed(bytes: Int64(m.sizeMB) * 1_000_000)
        default: return nil
        }
    }

    private func diskState(_ m: LocalModel) -> State {
        if m.isInstalled { return .installed(bytes: m.archives.reduce(0) { $0 + ModelDownloader.size(of: LocalModels.root.appendingPathComponent($1.folder)) }) }
        let done = doneBytes(m)
        return done > 0 ? .paused(done: done, total: m.downloadSize) : .notInstalled
    }

    /// 已经解压好的包算全部，没解压的算已下的部分
    private func doneBytes(_ m: LocalModel) -> Int64 {
        m.archives.reduce(0) { $0 + (ModelDownloader.isUnpacked($1) ? $1.size : ModelDownloader.partBytes($1)) }
    }

    func download(_ m: LocalModel) {
        guard running == nil else { return }
        // 磁盘：压缩包 + 解压后，再留 10%
        let need = Int64(Double(m.downloadSize + Int64(m.sizeMB) * 1_000_000) * 1.1) - doneBytes(m)
        if let free = ModelDownloader.freeSpace(), free < need {
            states[m.id] = .failed("磁盘空间不够：还要约 \(need / 1_000_000) MB，只剩 \(free / 1_000_000) MB")
            return
        }
        let total = m.downloadSize
        states[m.id] = .downloading(done: doneBytes(m), total: total, bytesPerSec: 0)
        let task = Task { [weak self] in
            let meter = SpeedMeter()
            do {
                for a in m.archives where !ModelDownloader.isUnpacked(a) {
                    let base = m.archives.prefix { $0 != a }.reduce(Int64(0)) { $0 + $1.size }
                    do {
                        try await ModelDownloader.fetch(a) { bytes in
                            let speed = meter.add(base + bytes)
                            Task { @MainActor in self?.progress(m, base + bytes, total, speed) }
                        }
                    } catch let e as ModelDownloader.Failure where e.message.contains("校验") {
                        try await ModelDownloader.fetch(a) { _ in }   // 校验没过：已删掉，自动重下一次
                    }
                    self?.states[m.id] = .unpacking
                    try await ModelDownloader.unpack(a)
                }
                self?.finish(m, nil)
            } catch is CancellationError {
                self?.finish(m, nil)
            } catch {
                self?.finish(m, error.localizedDescription)
            }
        }
        running = (m.id, task)
    }

    func pause(_ m: LocalModel) {
        guard running?.id == m.id else { return }
        running?.task.cancel()
    }

    func delete(_ m: LocalModel) {
        if running?.id == m.id { running?.task.cancel() }
        let fm = FileManager.default
        // 别的模型还要用的包（以后可能共用标点模型）不删
        let shared = Set(LocalModels.all.filter { $0.id != m.id && $0.isInstalled }.flatMap { $0.archives.map(\.folder) })
        for a in m.archives where !shared.contains(a.folder) {
            try? fm.removeItem(at: LocalModels.root.appendingPathComponent(a.folder))
            try? fm.removeItem(at: ModelDownloader.partURL(a))
        }
        states[m.id] = .notInstalled
        Task { await AppSettings.shared.refreshLocalEngine() }
    }

    private func progress(_ m: LocalModel, _ done: Int64, _ total: Int64, _ speed: Double) {
        guard running?.id == m.id, case .downloading = states[m.id] ?? .notInstalled else { return }
        states[m.id] = .downloading(done: done, total: total, bytesPerSec: speed)
    }

    private func finish(_ m: LocalModel, _ error: String?) {
        running = nil
        states[m.id] = error.map { .failed($0) } ?? diskState(m)
        Task { await AppSettings.shared.refreshLocalEngine() }
    }
}

/// 最近 5 秒的平均速度
private final class SpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(Date, Int64)] = []
    func add(_ bytes: Int64) -> Double {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 5 }
        guard let first = samples.first, now.timeIntervalSince(first.0) > 0.5 else { return 0 }
        return Double(bytes - first.1) / now.timeIntervalSince(first.0)
    }
}

extension ModelStore.State {
    /// 给界面的一句话
    var label: String {
        func mb(_ b: Int64) -> String { b >= 1_000_000_000 ? String(format: "%.1f GB", Double(b) / 1e9) : "\(b / 1_000_000) MB" }
        switch self {
        case .notInstalled: return "未下载"
        case .paused(let d, let t): return "已暂停 · \(mb(d)) / \(mb(t))"
        case .downloading(let d, let t, let s):
            let speed = s > 0 ? " · \(mb(Int64(s)))/秒" : ""
            return "\(Int(Double(d) / Double(max(t, 1)) * 100))% · \(mb(d)) / \(mb(t))" + speed
        case .unpacking: return "正在解压…"
        case .installed(let b): return "已安装 · \(mb(b))"
        case .failed(let e): return e
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var fraction: Double? {
        switch self {
        case .downloading(let d, let t, _), .paused(let d, let t): return Double(d) / Double(max(t, 1))
        case .unpacking: return 1
        default: return nil
        }
    }
}
