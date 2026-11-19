import Foundation
import XCTest
@testable import E1Recorder

/// 检查更新：先读阿里云的 latest.json，读不到再问 GitHub。用 ModelDownloadTests 里的假服务器，不联网。
final class UpdateCheckTests: XCTestCase {
    private let cn = URL(string: "https://mirror.test/latest.json")!
    private let gh = URL(string: "https://api.test/repos/x/y/releases/latest")!
    private var session: URLSession!

    private var sources: [UpdateCheck.Source] {
        [UpdateCheck.Source(url: cn, key: "version"),
         UpdateCheck.Source(url: gh, key: "tag_name", accept: "application/vnd.github+json")]
    }

    override func setUp() {
        StubServer.routes = [:]
        StubServer.ranges = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubServer.self]
        session = URLSession(configuration: c)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        StubServer.routes = [:]
    }

    private func serve(_ url: URL, _ body: String) {
        StubServer.routes[url.absoluteString] = .init(body: Data(body.utf8))
    }

    func testReadsAliyunFirst() async {
        serve(cn, #"{"version": "1.5.0", "date": "2026-11-20", "dmg": "Yinloo-1.5.0.dmg", "sha256": "", "notes": "本机转写"}"#)
        serve(gh, #"{"tag_name": "v1.4.0"}"#)
        let v = await UpdateCheck.latest(sources: sources, session: session)
        XCTAssertEqual(v, "1.5.0", "阿里云读到了就用它，不再问 GitHub")
    }

    func testFallsBackToGitHubWhenAliyunMissing() async {
        serve(gh, #"{"tag_name": "v1.5.0", "name": "音录 1.5.0"}"#)   // 阿里云上还没传 latest.json：404
        let v = await UpdateCheck.latest(sources: sources, session: session)
        XCTAssertEqual(v, "1.5.0")
    }

    func testFallsBackWhenAliyunVersionMalformed() async {
        serve(cn, #"{"version": "latest"}"#)
        serve(gh, #"{"tag_name": "v1.5.1"}"#)
        let v = await UpdateCheck.latest(sources: sources, session: session)
        XCTAssertEqual(v, "1.5.1", "版本号格式不对当没读到，接着问 GitHub")
    }

    func testStripsLeadingV() {
        XCTAssertEqual(UpdateCheck.version(from: Data(#"{"tag_name": "v1.5.0"}"#.utf8), key: "tag_name"), "1.5.0")
        XCTAssertEqual(UpdateCheck.version(from: Data(#"{"tag_name": " V1.5.0\n"}"#.utf8), key: "tag_name"), "1.5.0")
        XCTAssertEqual(UpdateCheck.version(from: Data(#"{"version": "1.5"}"#.utf8), key: "version"), "1.5")
        XCTAssertNil(UpdateCheck.version(from: Data(#"{"version": 1.5}"#.utf8), key: "version"), "不是字符串")
        XCTAssertNil(UpdateCheck.version(from: Data(#"{"tag_name": "v1.5.0"}"#.utf8), key: "version"), "字段名不对")
    }

    func testErrorPagesGiveNil() async {
        // 运营商劫持、OSS 出错页、GitHub 限流：都是 200 但内容不对
        serve(cn, "<html><body><h1>403 Forbidden</h1></body></html>")
        serve(gh, #"{"message": "API rate limit exceeded", "documentation_url": "https://docs.github.com/rest"}"#)
        let v = await UpdateCheck.latest(sources: sources, session: session)
        XCTAssertNil(v)
        XCTAssertNil(UpdateCheck.version(from: Data(#"{"version": "1.5.0-beta"}"#.utf8), key: "version"))
        XCTAssertNil(UpdateCheck.version(from: Data(#"{"version": "<html>"}"#.utf8), key: "version"))
        XCTAssertNil(UpdateCheck.version(from: Data(), key: "version"))
    }

    func testBothUnreachableGivesNil() async {
        let v = await UpdateCheck.latest(sources: sources, session: session)   // 两边都 404
        XCTAssertNil(v)
    }

    func testIsNewerComparesNumerically() {
        XCTAssertTrue(UpdateCheck.isNewer("1.5.0", than: "1.4.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.2"), "按数字比，不按字母")
        XCTAssertFalse(UpdateCheck.isNewer("1.5.0", than: "1.5.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.4.0", than: "1.5.0"))
    }

    func testDefaultSourcesPutAliyunFirst() {
        XCTAssertEqual(UpdateCheck.sources.map(\.url), [AppLinks.latestCN, AppLinks.latestAPI])
        XCTAssertEqual(UpdateCheck.sources.first?.url.host, "yinloo-download.oss-cn-beijing.aliyuncs.com")
        XCTAssertEqual(UpdateCheck.sources.map(\.key), ["version", "tag_name"])
    }

    /// 发版时传到阿里云的 latest.json（app/release/）：应用能读出版本号，字段齐全
    func testReleaseLatestJSONIsReadable() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("release/latest.json")
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(UpdateCheck.version(from: data, key: "version"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["version", "date", "dmg", "sha256", "notes"])
        XCTAssertEqual(obj["dmg"] as? String, "Yinloo-\(obj["version"] as? String ?? "").dmg")
    }

    /// 「关于」页脚列出内置的第三方组件（链接到包里的许可证文件，测试环境里没有这些文件，只核对文字）
    @MainActor func testAboutFooterListsBundledComponents() {
        XCTAssertEqual(String(AboutPage.credits.characters),
                       "MIT 许可 · 内置 adb（Apache-2.0）、sherpa-onnx（Apache-2.0，编入的组件）、ONNX Runtime（MIT，第三方声明）。"
                       + "本机转写模型下载后使用：X-ASR（上海交通大学等，Apache-2.0）、Paraformer 和标点模型（阿里巴巴达摩院 FunASR），见模型声明。")
        XCTAssertEqual(AboutPage.credits.runs.first?.link, AppLinks.license)
    }

    /// 「关于」页链接的声明文件都在 Resources/licenses 里，build.sh 也把它们拷进应用包
    func testLicenseFilesAreBundled() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let build = try String(contentsOf: app.appendingPathComponent("build.sh"), encoding: .utf8)
        for name in ["sherpa-onnx-LICENSE", "sherpa-onnx-ThirdPartyNotices", "onnxruntime-LICENSE", "onnxruntime-ThirdPartyNotices", "models-NOTICE"] {
            let file = app.appendingPathComponent("Resources/licenses/\(name).txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), name)
            XCTAssertTrue(build.contains("Resources/licenses/\(name).txt"), name)
        }
        let models = try String(contentsOf: app.appendingPathComponent("Resources/licenses/models-NOTICE.txt"), encoding: .utf8)
        for m in LocalModels.all { for a in m.archives { XCTAssertTrue(models.contains(a.name), a.name) } }
    }
}
