import CryptoKit
import Foundation
import XCTest
@testable import E1Recorder

/// 假服务器：按网址给内容，支持 Range，可以在第一次请求时只给一部分就断开。
final class StubServer: URLProtocol {
    struct Route { var body: Data; var honorRange = true; var dropAfter: Int?; var partialAs200 = false }
    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var ranges: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        guard var r = Self.routes[url.absoluteString] else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var start = 0
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.ranges.append(range)
            if r.honorRange { start = Int(range.dropFirst(6).prefix(while: { $0.isNumber })) ?? 0 }
        }
        let total = r.body.count
        var headers = ["Content-Length": "\(total - start)", "Content-Type": "application/x-bzip2"]
        if start > 0 { headers["Content-Range"] = "bytes \(start)-\(total - 1)/\(total)" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: start > 0 && !r.partialAs200 ? 206 : 200, httpVersion: nil,
                                                              headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        let rest = r.body.subdata(in: start..<total)
        if let drop = r.dropAfter {
            r.dropAfter = nil
            Self.routes[url.absoluteString] = r
            client?.urlProtocol(self, didLoad: rest.prefix(drop))
            // 真实网络里先到的数据会先交给下载器，过一会儿才断；立刻报错的话系统会把这批数据一起丢掉
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        client?.urlProtocol(self, didLoad: rest)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// 模型下载：断点续传、换地址、核对、解压。全部用假服务器和临时文件夹，不联网。
final class ModelDownloadTests: XCTestCase {
    private var root: URL!
    private var savedConfig: URLSessionConfiguration!
    private let a1 = URL(string: "https://mirror.test/models/m.tar.bz2")!
    private let a2 = URL(string: "https://official.test/m.tar.bz2")!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("models-" + UUID().uuidString)
        LocalModels.rootOverride = root
        savedConfig = ModelDownloader.configuration
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        ModelDownloader.configuration = c
        StubServer.routes = [:]
        StubServer.ranges = []
    }

    override func tearDown() {
        LocalModels.rootOverride = nil
        ModelDownloader.configuration = savedConfig
        try? FileManager.default.removeItem(at: root)
    }

    /// 做一个真的 tar.bz2：里面是 m/hello.txt
    private func makeArchive(padding: Int = 20_000) throws -> (Data, ModelArchive) {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("src-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("m"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let noise = (0..<padding).map { _ in UInt8.random(in: 0...255) }   // 随机内容压不小，文件够大才能测断点
        try Data(noise).write(to: src.appendingPathComponent("m/noise.bin"))
        try Data("你好".utf8).write(to: src.appendingPathComponent("m/hello.txt"))
        let out = src.appendingPathComponent("m.tar.bz2")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cjf", out.path, "-C", src.path, "m"]
        try p.run(); p.waitUntilExit()
        let data = try Data(contentsOf: out)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, ModelArchive(name: "m.tar.bz2", size: Int64(data.count), sha256: sha, folder: "m", githubTag: "test"))
    }

    func testDownloadVerifyAndUnpack() async throws {
        let (data, a) = try makeArchive()
        StubServer.routes[a1.absoluteString] = .init(body: data)
        try await ModelDownloader.fetch(a, sources: [a1]) { _ in }
        try await ModelDownloader.unpack(a)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("m/hello.txt"), encoding: .utf8), "你好")
        XCTAssertTrue(ModelDownloader.isUnpacked(a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.partURL(a).path), "解压后删掉压缩包")
    }

    func testResumesAfterConnectionDrops() async throws {
        let (data, a) = try makeArchive()
        StubServer.routes[a1.absoluteString] = .init(body: data, dropAfter: 1_000)
        do {
            try await ModelDownloader.fetch(a, sources: [a1]) { _ in }
            XCTFail("第一次应该断在半路")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("继续"), error.localizedDescription)
        }
        XCTAssertEqual(ModelDownloader.partBytes(a), 1_000)
        try await ModelDownloader.fetch(a, sources: [a1]) { _ in }
        XCTAssertEqual(StubServer.ranges, ["bytes=1000-"], "第二次从断处接着下")
        XCTAssertEqual(try Data(contentsOf: ModelDownloader.partURL(a)), data)
    }

    func testFallsBackToNextSourceWhenMirrorMissing() async throws {
        let (data, a) = try makeArchive()
        StubServer.routes[a2.absoluteString] = .init(body: data)   // 国内镜像还没传：404
        try await ModelDownloader.fetch(a, sources: [a1, a2]) { _ in }
        XCTAssertEqual(ModelDownloader.partBytes(a), a.size)
    }

    func testDoesNotSwitchSourceAfterPartialProgress() async throws {
        let (data, a) = try makeArchive()
        StubServer.routes[a1.absoluteString] = .init(body: data, dropAfter: 2_000)
        StubServer.routes[a2.absoluteString] = .init(body: data)
        do { try await ModelDownloader.fetch(a, sources: [a1, a2]) { _ in }; XCTFail("应该停下等用户点继续") } catch {}
        XCTAssertEqual(ModelDownloader.partBytes(a), 2_000, "镜像是通的，只是断了：不换到海外地址重下")
    }

    func testServerIgnoringRangeStartsOver() async throws {
        let (data, a) = try makeArchive()
        try FileManager.default.createDirectory(at: ModelDownloader.downloads, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 700).write(to: ModelDownloader.partURL(a))   // 之前留下的一段（内容不对也没关系）
        StubServer.routes[a1.absoluteString] = .init(body: data, honorRange: false)
        try await ModelDownloader.fetch(a, sources: [a1]) { _ in }
        XCTAssertEqual(try Data(contentsOf: ModelDownloader.partURL(a)), data)
    }

    func testResumeWhenServerSays200WithContentRange() async throws {
        let (data, a) = try makeArchive()
        StubServer.routes[a1.absoluteString] = .init(body: data, dropAfter: 3_000, partialAs200: true)
        do { try await ModelDownloader.fetch(a, sources: [a1]) { _ in } } catch {}
        XCTAssertEqual(ModelDownloader.partBytes(a), 3_000)
        try await ModelDownloader.fetch(a, sources: [a1]) { _ in }
        XCTAssertEqual(try Data(contentsOf: ModelDownloader.partURL(a)), data, "魔搭式的 200 + Content-Range 也按续传拼接")
    }

    func testChecksumMismatchDeletesFile() async throws {
        let (data, good) = try makeArchive()
        let bad = ModelArchive(name: good.name, size: good.size, sha256: String(repeating: "0", count: 64), folder: "m", githubTag: "test")
        StubServer.routes[a1.absoluteString] = .init(body: data)
        do {
            try await ModelDownloader.fetch(bad, sources: [a1]) { _ in }
            XCTFail("校验应该不通过")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("校验"), error.localizedDescription)
        }
        XCTAssertEqual(ModelDownloader.partBytes(bad), 0)
    }

    func testCatalogSourcesPutMirrorFirst() {
        let s = LocalModels.xasr.archives[0].sources
        XCTAssertEqual(s.first?.host, "yinloo-download.oss-cn-beijing.aliyuncs.com")
        XCTAssertEqual(s.last?.absoluteString,
                       "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/" + LocalModels.xasr.archives[0].name)
        XCTAssertEqual(LocalModels.paraformer.archives.count, 2, "Paraformer 要模型和标点两个包")
    }
}

/// 真联网：从 GitHub 官方下标点模型（65 MB），下到一半停掉、再接着下，核对校验码并解压。
/// 只在设了 YINLOO_NET_TEST=1 时跑。
final class ModelDownloadNetworkTests: XCTestCase {
    func testRealDownloadPauseResume() async throws {
        guard ProcessInfo.processInfo.environment["YINLOO_NET_TEST"] == "1" else { throw XCTSkip("要联网，设 YINLOO_NET_TEST=1 才跑") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-net-" + UUID().uuidString)
        LocalModels.rootOverride = root
        defer { LocalModels.rootOverride = nil; try? FileManager.default.removeItem(at: root) }
        let a = LocalModels.paraformer.archives[1]
        let official = Array(a.sources.suffix(1))   // 国内镜像还没传，直接用官方地址
        let t = Task { try await ModelDownloader.fetch(a, sources: official) { _ in } }
        while ModelDownloader.partBytes(a) < 5_000_000 { try await Task.sleep(nanoseconds: 100_000_000) }
        t.cancel()
        _ = await t.result
        let paused = ModelDownloader.partBytes(a)
        XCTAssertGreaterThan(paused, 0)
        XCTAssertLessThan(paused, a.size)
        let start = Date()
        try await ModelDownloader.fetch(a, sources: official) { _ in }
        print("暂停在 \(paused / 1_000_000) MB，续传用了 \(Int(Date().timeIntervalSince(start))) 秒")
        try await ModelDownloader.unpack(a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(a.folder).appendingPathComponent("model.int8.onnx").path))
    }
}

/// 真联网：国内镜像（阿里云）上的三个包，用应用的下载器完整下一遍、核对校验码、解压。
/// 只在设了 YINLOO_MIRROR_TEST=1 时跑（每次约 415 MB 流量）。
final class ModelMirrorTests: XCTestCase {
    func testMirrorServesAllArchives() async throws {
        guard ProcessInfo.processInfo.environment["YINLOO_MIRROR_TEST"] == "1" else { throw XCTSkip("要联网，设 YINLOO_MIRROR_TEST=1 才跑") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("models-mirror-" + UUID().uuidString)
        LocalModels.rootOverride = root
        defer { LocalModels.rootOverride = nil; try? FileManager.default.removeItem(at: root) }
        for m in LocalModels.all {
            for a in m.archives {
                let mirror = Array(a.sources.prefix(1))
                XCTAssertEqual(mirror.first?.host, "yinloo-download.oss-cn-beijing.aliyuncs.com")
                let start = Date()
                try await ModelDownloader.fetch(a, sources: mirror) { _ in }   // 只用国内镜像；里面会核对 sha256
                let sec = Date().timeIntervalSince(start)
                try await ModelDownloader.unpack(a)
                print("镜像核对：\(a.folder.prefix(40))… \(a.size / 1_000_000) MB，\(Int(sec)) 秒，\(Int(Double(a.size) / 1e6 / max(sec, 0.1))) MB/秒，校验码一致，已解压")
            }
            XCTAssertTrue(m.isInstalled, "\(m.name) 解压后文件齐全")
        }
    }
}
