import CryptoKit
import Foundation

/// 下载、核对、解压本机模型。只在用户点「下载」时运行，不在后台偷偷下。
///
/// - 断点续传：下到 models/.download/<包名>.part，HTTP Range 接着下；暂停、断网、退出应用都不丢已下的部分。
/// - 按顺序换地址：国内镜像打不通（404、403、连不上，且一个字节都没下到）才换 GitHub 官方。
/// - 下完核对 sha256（官方公布的值，写死在应用里），对不上就删掉。
/// - 用系统自带的 tar 解压到临时文件夹，再整个挪到位。
/// 请求里只有通用的 User-Agent 和 Referer（阿里云防盗链要），不带任何用户信息。
enum ModelDownloader {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 测试用：换成带假服务器的配置
    nonisolated(unsafe) static var configuration: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30          // 30 秒没收到数据算断了
        c.timeoutIntervalForResource = 6 * 3600
        c.httpAdditionalHeaders = ["User-Agent": "Yinloo/\(AppLinks.version)", "Referer": "https://yinloo.com/"]
        return c
    }()

    static var downloads: URL { LocalModels.root.appendingPathComponent(".download", isDirectory: true) }
    static func partURL(_ a: ModelArchive) -> URL { downloads.appendingPathComponent(a.name + ".part") }

    /// 这个包已经下了多少字节（没开始是 0）
    static func partBytes(_ a: ModelArchive) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: partURL(a).path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// 解压后的文件夹在不在（解压成功才会挪到位，所以在就是完整的）
    static func isUnpacked(_ a: ModelArchive) -> Bool {
        FileManager.default.fileExists(atPath: LocalModels.root.appendingPathComponent(a.folder).path)
    }

    /// 下载（或接着下）一个包并核对。progress 收到的是这个包已经在磁盘上的字节数。
    static func fetch(_ a: ModelArchive, sources: [URL]? = nil, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let part = partURL(a)
        if partBytes(a) > a.size { try? FileManager.default.removeItem(at: part) }
        var lastError: Error?
        for url in sources ?? a.sources {
            if partBytes(a) == a.size { break }
            let before = partBytes(a)
            do {
                try await RangeDownload(url: url, file: part, expected: a.size, progress: progress).run()
                lastError = nil
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // 这个地址下到了东西，说明它是通的，只是中途断了：交给用户「继续」，不换地址
                if partBytes(a) > before { throw error }
            }
        }
        if let lastError, partBytes(a) != a.size { throw lastError }
        guard partBytes(a) == a.size else { throw Failure(message: "下载的文件大小不对") }
        progress(a.size)
        if try sha256(of: part) != a.sha256 {
            try? FileManager.default.removeItem(at: part)
            throw Failure(message: "下载的文件校验没通过，已删除，请重新下载")
        }
    }

    /// 解压已核对的包，挪到 models/<文件夹>，删掉压缩包
    static func unpack(_ a: ModelArchive) async throws {
        let fm = FileManager.default
        let tmp = LocalModels.root.appendingPathComponent(".unpack-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xjf", partURL(a).path, "-C", tmp.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; cont.resume(throwing: error) }
        }
        let unpacked = tmp.appendingPathComponent(a.folder)
        guard status == 0, fm.fileExists(atPath: unpacked.path) else { throw Failure(message: "模型解压失败，请删除后重新下载") }
        let dest = LocalModels.root.appendingPathComponent(a.folder)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: unpacked, to: dest)
        try? fm.removeItem(at: partURL(a))
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 磁盘剩余空间（字节），拿不到时返回 nil
    static func freeSpace() -> Int64? {
        try? FileManager.default.createDirectory(at: LocalModels.root, withIntermediateDirectories: true)
        let v = try? LocalModels.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// 文件夹占多大（字节）
    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// 一次 HTTP 下载：有 .part 就带 Range 接着下；服务器不认 Range（回 200）就从头写。
final class RangeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let file: URL
    private let expected: Int64
    private let progress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private let lock = NSLock()

    init(url: URL, file: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url; self.file = file; self.expected = expected; self.progress = progress
    }

    func run() async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let h = try FileHandle(forWritingTo: file)
        written = Int64(try h.seekToEnd())
        handle = h
        defer { try? h.close() }
        var req = URLRequest(url: url)
        if written > 0 { req.setValue("bytes=\(written)-", forHTTPHeaderField: "Range") }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: ModelDownloader.configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = c
                let t = session.dataTask(with: req)
                task = t
                lock.unlock()
                t.resume()
            }
        } onCancel: {
            lock.lock(); let t = task; lock.unlock()
            t?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let r = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        // 魔搭对小文件续传时回 200 但带 Content-Range、只给后半段：有 Content-Range 就按续传处理
        let status = r.statusCode == 200 && r.value(forHTTPHeaderField: "Content-Range") != nil ? 206 : r.statusCode
        switch status {
        case 206:
            // Content-Range: bytes 起-止/总；起点必须是我们已有的长度
            let range = r.value(forHTTPHeaderField: "Content-Range") ?? ""
            let start = Int64(range.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })) ?? -1
            guard start == written else {
                failure = ModelDownloader.Failure(message: "服务器返回的续传位置不对")
                completionHandler(.cancel); return
            }
        case 200:
            // 不支持续传：从头写
            do { try handle?.truncate(atOffset: 0); written = 0 } catch { failure = error; completionHandler(.cancel); return }
        default:
            failure = ModelDownloader.Failure(message: r.statusCode == 404 || r.statusCode == 403
                                              ? "下载地址暂时不可用（\(r.statusCode)）" : "下载出错（HTTP \(r.statusCode)）")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            if written > expected { failure = ModelDownloader.Failure(message: "下载的文件比预期大"); dataTask.cancel(); return }
            progress(written)
        } catch {
            failure = ModelDownloader.Failure(message: "写入磁盘失败：\(error.localizedDescription)")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let failure { c?.resume(throwing: failure); return }
        if let e = error as? URLError, e.code == .cancelled { c?.resume(throwing: CancellationError()); return }
        if let error { c?.resume(throwing: ModelDownloader.Failure(message: "网络中断，可以点「继续」接着下（\(error.localizedDescription)）")); return }
        c?.resume()
    }
}
