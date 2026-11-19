import Foundation

/// 本机转写能用的 sherpa-onnx 模型。模型不随应用分发（一个一两百兆），用户在服务选项里点「下载」，放在
/// ~/Library/Application Support/E1Recorder/models/<文件夹>/。
///
/// M0 实测（2026-11-18）：和听悟比，X-ASR 20.5%、Paraformer 2023 + 标点 20.4%；盲听 120 处分歧，52:43、
/// 按字 155:161，打平。X-ASR 错字少、会漏一些话，Paraformer 反之。默认 X-ASR：小一半、自带标点、许可清楚。
///
/// 下载的是 sherpa-onnx 官方发布的压缩包原样，sha256 用官方公布的值；国内镜像放的是一模一样的副本。
///
/// 再分发许可（2026-11-19 核对原始许可证）：X-ASR 是 Apache-2.0（模型卡和 GitHub 仓库都写明）；Paraformer 和
/// 标点模型在魔搭的模型页标 Apache-2.0，FunASR 仓库另有《FunASR 模型开源协议》1.1，同样允许复制和分享，要求注明
/// 出处、作者并保留模型名。所以三个都可以放国内镜像；署名和许可证全文在 Resources/licenses/models-NOTICE.txt，
/// 「关于」页有链接。哪个模型以后不能放镜像了，把它的 mirrored 改成 false，就只从 GitHub 官方下。
struct ModelArchive: Sendable, Equatable {
    /// 文件名（国内镜像和官方用同一个名字）
    let name: String
    let size: Int64
    let sha256: String
    /// 解压出来的顶层文件夹
    let folder: String
    /// 官方发布页上的标签（asr-models、punctuation-models）
    let githubTag: String
    /// 许可允许再分发、放在了国内镜像上；false 就只从官方地址下
    var mirrored = true

    /// 按顺序试：国内镜像 → GitHub 官方
    var sources: [URL] {
        (mirrored ? LocalModels.mirrors.map { $0.appendingPathComponent(name) } : [])
            + [URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/\(githubTag)/\(name)")!]
    }
}

struct LocalModel: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let note: String
    /// "transducer" 或 "paraformer"（见 yinloo-asr）
    let kind: String
    let folder: String
    /// 角色 → 文件名（transducer：encoder、decoder、joiner、tokens；paraformer：model、tokens）
    let files: [String: String]
    /// 标点模型（模型自己不出标点时）：文件夹和文件名
    let punct: (folder: String, file: String)?
    /// 解压后大约多大
    let sizeMB: Int
    let license: String
    /// 要下载的压缩包（Paraformer 有两个：模型和标点）
    let archives: [ModelArchive]
    var downloadSize: Int64 { archives.reduce(0) { $0 + $1.size } }

    static func == (a: LocalModel, b: LocalModel) -> Bool { a.id == b.id }

    var dir: URL { LocalModels.root.appendingPathComponent(folder, isDirectory: true) }

    /// 子程序要的「角色 → 绝对路径」
    var paths: [String: String] { files.mapValues { dir.appendingPathComponent($0).path } }
    var punctPath: String? {
        punct.map { LocalModels.root.appendingPathComponent($0.folder).appendingPathComponent($0.file).path }
    }

    var isInstalled: Bool {
        let fm = FileManager.default
        return paths.values.allSatisfy { fm.fileExists(atPath: $0) } && (punctPath.map { fm.fileExists(atPath: $0) } ?? true)
    }
}

enum LocalModels {
    static let xasr = LocalModel(
        id: "x-asr", name: "X-ASR", note: "中英混说，自带标点，错字少",
        kind: "transducer", folder: "sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03",
        files: ["encoder": "encoder-epoch-99-avg-1.int8.onnx", "decoder": "decoder-epoch-99-avg-1.onnx",
                "joiner": "joiner-epoch-99-avg-1.int8.onnx", "tokens": "tokens.txt"],
        punct: nil, sizeMB: 175, license: "Apache-2.0（上海交通大学等）",
        archives: [.init(name: "sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03.tar.bz2", size: 136_396_739,
                         sha256: "5d02c36d7b44e886b7c8f0d8e051f8713acab96c264bb6ef9e718be39a6a2224",
                         folder: "sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03", githubTag: "asr-models")])

    static let paraformer = LocalModel(
        id: "paraformer-zh", name: "Paraformer", note: "漏字少，标点另用一个模型加",
        kind: "paraformer", folder: "sherpa-onnx-paraformer-zh-2023-09-14",
        files: ["model": "model.int8.onnx", "tokens": "tokens.txt"],
        punct: ("sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8", "model.int8.onnx"),
        sizeMB: 325, license: "FunASR（阿里巴巴达摩院）",
        archives: [.init(name: "sherpa-onnx-paraformer-zh-2023-09-14.tar.bz2", size: 234_051_698,
                         sha256: "9c49fd9c6fb63de8e18c1054cf3d100f804741b7e608e187923cd8ff09fa9f03",
                         folder: "sherpa-onnx-paraformer-zh-2023-09-14", githubTag: "asr-models"),
                   .init(name: "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2", size: 64_717_756,
                         sha256: "c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1",
                         folder: "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8", githubTag: "punctuation-models")])

    static let all = [xasr, paraformer]

    static func find(_ id: String) -> LocalModel? { all.first { $0.id == id } }

    /// 国内镜像（按顺序）。放的是和官方一模一样的压缩包，下完用同一个 sha256 核对。
    /// 阿里云 yinloo-download 开了防盗链，请求要带 Referer（见 ModelDownloader）。
    static let mirrors: [URL] = [URL(string: "https://yinloo-download.oss-cn-beijing.aliyuncs.com/models")!]

    /// 测试用：指到临时文件夹
    nonisolated(unsafe) static var rootOverride: URL?

    /// 模型放哪。测试可以用环境变量 YINLOO_MODELS_DIR 指到别处
    static var root: URL {
        if let rootOverride { return rootOverride }
        if let p = ProcessInfo.processInfo.environment["YINLOO_MODELS_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("E1Recorder/models", isDirectory: true)
    }
}
