import Foundation
import Security
import ServiceManagement

// MARK: - Transcription platforms

/// Only platforms that actually work are offered. Both run on Alibaba Cloud Bailian and share one API key.
enum Provider: String, CaseIterable, Identifiable, Codable {
    case tingwu
    case bailian = "bailianASR"
    case custom
    /// 1.5：在这台 Mac 上转写，录音不上传（引擎见 LocalASR.swift）
    case local
    var id: String { rawValue }
    var info: PlatformInfo { PlatformInfo.catalog[self]! }
}

struct ModelOption: Identifiable, Hashable {
    let id: String          // value sent to the API ("" = follow the console configuration)
    let label: String
}

struct PlatformInfo {
    let name: String
    let summary: String
    let needsAppId: Bool
    let models: [ModelOption]
    let consoleURL: URL

    static let catalog: [Provider: PlatformInfo] = [
        .tingwu: .init(name: "通义听悟", summary: "转写、说话人区分、摘要、待办与章节一次完成", needsAppId: true,
                       models: [.init(id: "fun-asr", label: "Fun-ASR 大模型"), .init(id: "cn", label: "中文通用"),
                                .init(id: "multilingual", label: "多语种混合"), .init(id: "", label: "跟随控制台")],
                       consoleURL: URL(string: "https://bailian.console.aliyun.com/?tab=app#/app/app-market/tingwu/tingwu-meeting-summary")!),
        .bailian: .init(name: "百炼语音", summary: "Fun-ASR 大模型转写，支持热词和说话人区分", needsAppId: false,
                        models: [.init(id: "fun-asr", label: "Fun-ASR 大模型"), .init(id: "paraformer-v2", label: "Paraformer v2")],
                        consoleURL: URL(string: "https://bailian.console.aliyun.com/")!),
        .custom: .init(name: "自定义", summary: "任意 OpenAI 兼容接口：自己填写地址、密钥和模型", needsAppId: false,
                       models: [], consoleURL: URL(string: "https://platform.openai.com/docs/api-reference/audio")!),
        .local: .init(name: "本机转写", summary: "在这台 Mac 上转写，录音不上传", needsAppId: false,
                      models: [.init(id: "x-asr", label: "X-ASR"), .init(id: "paraformer-zh", label: "Paraformer"),
                               .init(id: "apple", label: "苹果自带")], consoleURL: URL(string: "https://yinloo.com")!),
    ]

    /// Language models that turn a Bailian transcript into a note.
    /// 2026-11 核对：qwen3.8-flash 是百炼当前推荐的便宜档，qwen3.7-plus 更好；老的三个名字还能用，标「旧」留着，
    /// 免得已经选了它们的用户界面上变空白。
    static let llmModels: [ModelOption] = [.init(id: "qwen3.8-flash", label: "千问 3.8 Flash"), .init(id: "qwen3.7-plus", label: "千问 3.7 Plus"),
                                           .init(id: "qwen-plus", label: "千问 Plus（旧）"), .init(id: "qwen-max", label: "千问 Max（旧）"),
                                           .init(id: "qwen-turbo", label: "千问 Turbo（旧）")]
}

/// 云端账号：一家一个访问密钥，都存在同一个钥匙串条目里。① 转文字和 ② 整理可能用同一家，也可能各用各的。
enum CloudAccount: String, CaseIterable, Identifiable {
    case aliyun, deepseek, custom
    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .aliyun: Keychain.account
        case .deepseek: Keychain.deepseekAccount
        case .custom: Keychain.customAccount
        }
    }
    var name: String {
        switch self {
        case .aliyun: "阿里云百炼"
        case .deepseek: "DeepSeek"
        case .custom: "自定义平台"
        }
    }
    /// 放进中文句子里用：英文名两边加空格（「还没填写 DeepSeek 的访问密钥」）
    var inSentence: String { name.first?.isASCII == true ? " \(name) " : name }
    /// 访问密钥在哪里创建（可以点）
    var keyWhere: String {
        switch self {
        case .aliyun: "在[百炼控制台](https://bailian.console.aliyun.com/?tab=model#/api-key) › 密钥管理中创建，以 sk- 开头"
        case .deepseek: "在[DeepSeek 开放平台](https://platform.deepseek.com/api_keys) › API keys 中创建，以 sk- 开头"
        case .custom: "该平台的 API Key"
        }
    }
    /// 填密钥窗口里的说明（纯文字）
    var keyHelp: String {
        switch self {
        case .aliyun: "在百炼控制台 › 密钥管理中创建，以 sk- 开头。转写（通义听悟、百炼语音）和千问整理用同一个。只保存在本机钥匙串。"
        case .deepseek: "在 DeepSeek 开放平台（platform.deepseek.com）› API keys 中创建，以 sk- 开头。只保存在本机钥匙串。"
        case .custom: "自定义平台的 API Key，只保存在本机钥匙串，和其他平台的密钥分开存放。"
        }
    }
    var keyPlaceholder: String { self == .custom ? "API Key" : "sk-…" }
    func validate(_ k: String) -> String? {
        switch self {
        case .custom: k.count >= 8 ? nil : "密钥太短"
        default: k.hasPrefix("sk-") && k.count >= 20 ? nil : "应以 sk- 开头"
        }
    }
}

/// ② 整理成纪要交给谁。大模型只收到逐字稿的文字，不收到录音。
enum NoteService: String, CaseIterable, Identifiable {
    /// 通义听悟转写时一起出摘要、待办、章节（只在 ① 选听悟时可选）
    case tingwu
    case bailian
    case deepseek
    /// 任意 OpenAI 兼容接口（Kimi、智谱、豆包等），和 ① 的自定义平台共用地址和密钥
    case custom
    /// 本机大模型（llama.cpp），还没做
    case local
    /// 先不整理，只出逐字稿（1.5 新装的默认：不预设云端服务）
    case off
    var id: String { rawValue }

    var name: String {
        switch self {
        case .tingwu: "通义听悟（转写时一起整理）"
        case .bailian: "阿里云百炼 · 千问"
        case .deepseek: "DeepSeek"
        case .custom: "其他（OpenAI 兼容）"
        case .local: "本机大模型"
        case .off: "先不整理，只出逐字稿"
        }
    }
    var shortName: String {
        switch self {
        case .tingwu: "通义听悟"
        case .bailian: "千问"
        case .deepseek: "DeepSeek"
        case .custom: "自定义"
        case .local: "本机大模型"
        case .off: "不整理"
        }
    }
    var summary: String {
        switch self {
        case .tingwu: "听悟同时出摘要、要点、待办和章节，不用另配"
        case .bailian: "和百炼语音、通义听悟用同一个阿里云密钥"
        case .deepseek: "要一个 DeepSeek 的访问密钥"
        case .custom: "Kimi、智谱、豆包等 OpenAI 兼容接口都可以填这里"
        case .local: "在这台 Mac 上整理，文字不出电脑"
        case .off: "纪要里只有逐字稿，以后随时能换成大模型整理"
        }
    }
    var account: CloudAccount? {
        switch self {
        case .tingwu, .bailian: .aliyun
        case .deepseek: .deepseek
        case .custom: .custom
        case .local, .off: nil
        }
    }
    /// 1 小时录音整理一次大约多少钱（按官方价格估算，2026-11）
    var cost: String {
        switch self {
        case .tingwu: "含在听悟的费用里"
        case .bailian: "约 2～6 分钱/小时"
        case .deepseek: "约 3～6 分钱/小时"
        case .custom: "按该平台的价格"
        case .local, .off: "免费"
        }
    }
}

enum DeepSeekAPI {
    static let base = "https://api.deepseek.com"
    /// 2026-09 起官方模型名是 deepseek-flash（deepseek-chat 已停用，deepseek-v4-pro 也转到它）
    static let defaultModel = "deepseek-flash"
}

enum AppLinks {
    static let website = URL(string: "https://yinloo.com")!
    /// 下载新版走官网安装页：国内自动给阿里云的下载地址（GitHub 在国内常打不开），海外给 GitHub。
    static let download = URL(string: "https://yinloo.com/install#download")!
    static let repo = URL(string: "https://github.com/seabird000/yinloo")!
    static let releases = URL(string: "https://github.com/seabird000/yinloo/releases")!
    static let issues = URL(string: "https://github.com/seabird000/yinloo/issues/new")!
    static let license = URL(string: "https://github.com/seabird000/yinloo/blob/main/LICENSE")!
    /// 检查更新先读这里（阿里云北京，发版时更新，单独设公共读），读不到再读 GitHub。见 UpdateCheck。
    static let latestCN = URL(string: "https://yinloo-download.oss-cn-beijing.aliyuncs.com/latest.json")!
    static let latestAPI = URL(string: "https://api.github.com/repos/seabird000/yinloo/releases/latest")!
    static let buildMonth = "2026 年 11 月"
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
}

// MARK: - Note templates

enum TemplateChoice: Equatable {
    case builtin(String)
    case custom(String)

    init(raw: String) {
        if raw.hasPrefix("custom:") { self = .custom(String(raw.dropFirst(7))) }
        else { self = .builtin(raw.hasPrefix("builtin:") ? String(raw.dropFirst(8)) : "standard") }
    }
    var raw: String {
        switch self { case .builtin(let id): return "builtin:" + id; case .custom(let p): return "custom:" + p }
    }
}

// MARK: - Settings

/// Everything the user can change. Nothing is tied to one Mac: paths default to folders under the
/// current home, the API key lives in the Keychain, and the rest exports/imports as JSON.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    /// UI previews read the real settings but write to a throwaway domain, so stray typing can't change them.
    private let d: UserDefaults = UIPreview.enabled ? AppSettings.previewDefaults : .standard
    private static let previewDefaults: UserDefaults = {
        let d = UserDefaults(suiteName: "app.e1recorder.preview")!
        d.removePersistentDomain(forName: "app.e1recorder.preview")
        // -previewFresh YES：当作全新安装（不抄真实设置），看新用户第一次打开时的引导
        if UserDefaults.standard.bool(forKey: "previewFresh") { return d }
        for (k, v) in UserDefaults.standard.dictionaryRepresentation() { d.set(v, forKey: k) }
        return d
    }()

    @Published var provider: Provider { didSet { d.set(provider.rawValue, forKey: "provider") } }
    @Published var appId: String { didSet { d.set(appId, forKey: "appId") } }
    @Published var endpoint: String { didSet { d.set(endpoint, forKey: "endpoint") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var transcriptionModel: String { didSet { d.set(transcriptionModel, forKey: "transcriptionModel") } }
    @Published var llmModel: String { didSet { d.set(llmModel, forKey: "llmModel") } }
    /// 自定义平台（OpenAI 兼容）：接口根地址、语音识别模型、整理纪要的对话模型。密钥单独存钥匙串。
    @Published var customEndpoint: String { didSet { d.set(customEndpoint, forKey: "customEndpoint") } }
    @Published var customASRModel: String { didSet { d.set(customASRModel, forKey: "customASRModel") } }
    @Published var customLLMModel: String { didSet { d.set(customLLMModel, forKey: "customLLMModel") } }
    /// 本机转写用哪个引擎（"x-asr"、"paraformer-zh"、"apple"）
    @Published var localEngine: String {
        didSet { d.set(localEngine, forKey: "localEngine"); if oldValue != localEngine { Task { await refreshLocalEngine() } } }
    }
    /// ② 整理成纪要交给谁，和 ① 转文字分开选
    @Published var noteService: NoteService {
        didSet { d.set(noteService.rawValue, forKey: "noteService"); if oldValue != noteService { refreshOverallConn() } }
    }
    @Published var deepseekModel: String { didSet { d.set(deepseekModel, forKey: "deepseekModel") } }
    /// 每个云端账号上次连接测试的结果（"untested"、"ok"、"failed:原因"）
    @Published var connStates: [String: String] { didSet { d.set(connStates, forKey: "connStates") } }
    /// 本机引擎是否可用（苹果引擎：中文语音模型已装好）。异步检查，见 refreshLocalEngine()
    @Published var localReady = false
    @Published private(set) var maskedCustomKey: String?
    @Published private(set) var maskedDeepSeekKey: String?
    /// Menu bar icon style: "mic" (像素话筒), "bars" (声波), "pen" (录音笔). See MenuBarIcon.styles.
    @Published var menuIcon: String { didSet { d.set(menuIcon, forKey: "menuIcon") } }
    /// Open notes in Obsidian when they live inside an Obsidian vault.
    @Published var openInObsidian: Bool { didSet { d.set(openInObsidian, forKey: "openInObsidian") } }
    /// Monthly budget in yuan for the cost estimate (0 = no reminder).
    @Published var budgetYuan: Int { didSet { d.set(budgetYuan, forKey: "budgetYuan") } }
    /// Hotwords, one per line: names, companies, jargon.
    @Published var hotwords: String { didSet { d.set(hotwords, forKey: "hotwords") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    /// Names typed for speakers before, offered again next time.
    @Published var knownSpeakers: [String] { didSet { d.set(knownSpeakers, forKey: "knownSpeakers") } }
    /// WiFi networks the pen has been on (BSSID → network name), learned over USB and from heartbeats.
    @Published var knownNetworks: [String: String] { didSet { d.set(knownNetworks, forKey: "knownNetworks") } }
    /// What the user calls each network as a place, e.g. "Office-5G" → "公司". Only named networks count as places.
    @Published var placeNames: [String: String] { didSet { d.set(placeNames, forKey: "placeNames") } }

    func learnNetwork(bssid: String, ssid: String) {
        let b = bssid.lowercased()
        guard !b.isEmpty, !ssid.isEmpty, knownNetworks[b] != ssid else { return }
        knownNetworks[b] = ssid
    }

    /// Place for a recording: the strongest access point heard while recording that belongs to a known network.
    func place(for bssids: [String]?) -> String? {
        // A bare network name means nothing to a reader (and tells others which network you use), so only
        // networks the user has named become places.
        for b in bssids ?? [] {
            if let ssid = knownNetworks[b.lowercased()], let name = placeNames[ssid], !name.isEmpty { return name }
        }
        return nil
    }
    /// WiFi mailbox (Aliyun OSS): the pen uploads with an upload-only key, this Mac reads with a read/delete key.
    @Published var wifiEnabled: Bool { didSet { d.set(wifiEnabled, forKey: "wifiEnabled") } }
    @Published var ossEndpoint: String { didSet { d.set(ossEndpoint, forKey: "ossEndpoint") } }
    @Published var ossBucket: String { didSet { d.set(ossBucket, forKey: "ossBucket") } }
    /// How often the Mac checks the WiFi mailbox, in minutes.
    @Published var wifiIntervalMin: Int { didSet { d.set(wifiIntervalMin, forKey: "wifiIntervalMin") } }
    @Published private(set) var penKeyStored = false
    @Published private(set) var macKeyStored = false

    /// Everything the Mac needs to read the mailbox.
    var wifiReady: Bool { wifiEnabled && !ossBucket.isEmpty && !ossEndpoint.isEmpty && macKeyStored }

    func macOSS() -> OSSClient? {
        guard let id = Keychain.read(account: WifiKeys.macId), let sec = Keychain.read(account: WifiKeys.macSecret), !ossBucket.isEmpty else { return nil }
        return OSSClient(endpoint: ossEndpoint, bucket: ossBucket, keyId: id, secret: sec)
    }

    func penOSS() -> OSSClient? {
        guard let id = Keychain.read(account: WifiKeys.penId), let sec = Keychain.read(account: WifiKeys.penSecret), !ossBucket.isEmpty else { return nil }
        return OSSClient(endpoint: ossEndpoint, bucket: ossBucket, keyId: id, secret: sec)
    }

    func saveWifiKey(pen: Bool, id: String, secret: String) {
        Keychain.write(id.trimmingCharacters(in: .whitespacesAndNewlines), account: pen ? WifiKeys.penId : WifiKeys.macId)
        Keychain.write(secret.trimmingCharacters(in: .whitespacesAndNewlines), account: pen ? WifiKeys.penSecret : WifiKeys.macSecret)
        refreshMaskedKey()
    }

    var hotwordList: [String] {
        hotwords.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// Result of the last connection test: "untested", "ok", or "failed:<reason>". Reset whenever credentials change.
    @Published var connState: String { didSet { d.set(connState, forKey: "connState") } }
    @Published var notesFolder: String { didSet { d.set(notesFolder, forKey: "notesFolder") } }
    @Published var audioFolder: String { didSet { d.set(audioFolder, forKey: "audioFolder") } }
    @Published var template: TemplateChoice { didSet { d.set(template.raw, forKey: "template") } }
    @Published var organizer: String { didSet { d.set(organizer, forKey: "organizer") } }
    @Published var minDurationSec: Int { didSet { d.set(minDurationSec, forKey: "minDurationSec") } }
    @Published var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    /// What a note is saved as: "md" (Markdown, for Obsidian and other note apps), "docx" (Word) or "pdf".
    @Published var noteFormat: String { didSet { d.set(noteFormat, forKey: "noteFormat") } }
    /// Keep this Mac's copy of each recording after its note is written (the pen's own recording is never touched).
    @Published var keepAudio: Bool { didSet { d.set(keepAudio, forKey: "keepAudio") } }
    /// Transcribe new Voice Memos recordings (made on this Mac, or on iPhone and synced here by iCloud) automatically.
    /// Turning it on starts from that moment, so recordings made before are never billed by surprise.
    @Published var voiceMemos: Bool {
        didSet {
            d.set(voiceMemos, forKey: "voiceMemos")
            if voiceMemos && !oldValue { voiceMemosSince = Date() }
        }
    }
    @Published var voiceMemosSince: Date? { didSet { d.set(voiceMemosSince, forKey: "voiceMemosSince") } }
    /// 搜狗 C1 Max 插上后自动拷新录音并转写（第一次插上时笔里已有的不算，要的话在设备页逐条点「转写」）。
    @Published var c1MaxAuto: Bool { didSet { d.set(c1MaxAuto, forKey: "c1MaxAuto") } }
    @Published private(set) var maskedKey: String?

    private init() {
        let home = NSHomeDirectory()
        let defaultNotes = home + "/Documents/E1录音纪要"
        // 新装默认本机转写、先不整理；老用户（哪怕从没写过 provider 键、一直靠默认值用听悟）照旧。
        // 必须在下面固定目录之前判断（那一步会写 notesFolder），新装的结果马上存下，第二次启动就不再靠猜。
        let start = Self.initialServices(d)
        if start.fresh {
            d.set(start.provider.rawValue, forKey: "provider")
            d.set(start.note.rawValue, forKey: "noteService")
        }
        let savedProvider = start.provider
        provider = savedProvider
        appId = d.string(forKey: "appId") ?? ""
        endpoint = d.string(forKey: "endpoint") ?? "https://dashscope.aliyuncs.com"
        model = d.string(forKey: "model") ?? "tingwu-meeting"
        transcriptionModel = d.string(forKey: "transcriptionModel") ?? "fun-asr"
        llmModel = d.string(forKey: "llmModel") ?? "qwen3.8-flash"
        customEndpoint = d.string(forKey: "customEndpoint") ?? "https://api.openai.com/v1"
        // OpenAI 旧的转写模型（whisper-1 等）2027-02-26 关停，新装默认用 gpt-transcribe；已保存的值不动
        customASRModel = d.string(forKey: "customASRModel") ?? "gpt-transcribe"
        customLLMModel = d.string(forKey: "customLLMModel") ?? "gpt-4o-mini"
        localEngine = d.string(forKey: "localEngine") ?? LocalModels.xasr.id
        noteService = start.note
        deepseekModel = d.string(forKey: "deepseekModel") ?? DeepSeekAPI.defaultModel
        connStates = d.dictionary(forKey: "connStates") as? [String: String] ?? [:]
        menuIcon = MenuBarIcon.normalized(d.string(forKey: "menuIcon"))   // 1.4.0: the old default "ring" became "mic"
        openInObsidian = d.object(forKey: "openInObsidian") as? Bool ?? true
        budgetYuan = d.object(forKey: "budgetYuan") as? Int ?? 50
        hotwords = d.string(forKey: "hotwords") ?? ""
        onboardingDone = d.bool(forKey: "onboardingDone") || d.string(forKey: "appId") != nil
        knownSpeakers = d.stringArray(forKey: "knownSpeakers") ?? []
        knownNetworks = d.dictionary(forKey: "knownNetworks") as? [String: String] ?? [:]
        placeNames = d.dictionary(forKey: "placeNames") as? [String: String] ?? [:]
        wifiEnabled = d.bool(forKey: "wifiEnabled")
        ossEndpoint = d.string(forKey: "ossEndpoint") ?? "oss-cn-beijing.aliyuncs.com"
        ossBucket = d.string(forKey: "ossBucket") ?? ""
        wifiIntervalMin = d.object(forKey: "wifiIntervalMin") as? Int ?? 1
        connState = d.string(forKey: "connState") ?? "untested"
        // Pin the folders on first launch so a later change of the defaults never moves anyone's notes.
        let notes = d.string(forKey: "notesFolder") ?? defaultNotes, audio = d.string(forKey: "audioFolder") ?? home + "/Music/E1录音"
        d.set(notes, forKey: "notesFolder"); d.set(audio, forKey: "audioFolder")
        notesFolder = notes
        audioFolder = audio
        if let raw = d.string(forKey: "template") {
            template = TemplateChoice(raw: raw)
        } else if let legacy = d.string(forKey: "templatePath"), !legacy.isEmpty {
            template = .custom(legacy)
        } else {
            template = .builtin("standard")
        }
        organizer = d.string(forKey: "organizer") ?? NSFullUserName()
        minDurationSec = d.object(forKey: "minDurationSec") as? Int ?? 10
        autoSync = d.object(forKey: "autoSync") as? Bool ?? true
        noteFormat = d.string(forKey: "noteFormat") ?? "md"
        keepAudio = d.object(forKey: "keepAudio") as? Bool ?? true
        voiceMemos = d.bool(forKey: "voiceMemos")
        voiceMemosSince = d.object(forKey: "voiceMemosSince") as? Date
        c1MaxAuto = d.object(forKey: "c1MaxAuto") as? Bool ?? true
        // 1.5 以前只有一个总的连接状态：正常的话，当时用到的账号都算测过
        if connStates.isEmpty, connState == "ok" { for a in accountsInUse { connStates[a.rawValue] = "ok" } }
        if UIPreview.enabled {
            // Screenshot aid: -previewNoKey YES shows the app before any key is filled in.
            let none = UserDefaults.standard.bool(forKey: "previewNoKey")
            maskedKey = none ? nil : "sk-" + String(repeating: "•", count: 10) + "AbCd"; maskedCustomKey = maskedKey
            maskedDeepSeekKey = none || UserDefaults.standard.bool(forKey: "previewNoDeepSeekKey") ? nil : maskedKey
            penKeyStored = !none; macKeyStored = !none
            // -previewProvider tingwu|local… / -previewNoteService deepseek|off…：截图时直接看某种选择（只在内存里）
            if let p = UserDefaults.standard.string(forKey: "previewProvider").flatMap(Provider.init(rawValue:)) { provider = p }
            if let n = UserDefaults.standard.string(forKey: "previewNoteService").flatMap(NoteService.init(rawValue:)) { noteService = n }
            if Demo.on { Demo.apply(to: self) }
            return
        }
        refreshMaskedKey()
        // Launch at login is on by default; ask macOS once, then respect the user's choice.
        if !d.bool(forKey: "loginItemInitialized") {
            d.set(true, forKey: "loginItemInitialized")
            try? SMAppService.mainApp.register()
        }
    }

    /// 1.5 以前转写和整理绑在一起：从旧设置推出 ② 用谁（本机转写时旧的「不整理」也改成千问，没密钥就只出逐字稿）
    nonisolated static func migratedNoteService(provider: Provider, legacyLocalNote: String?) -> NoteService {
        switch provider {
        case .tingwu: .tingwu
        case .bailian: .bailian
        case .custom: .custom
        case .local: legacyLocalNote == "custom" ? .custom : .bailian
        }
    }

    /// 这些键只要有一个，就说明这台 Mac 上打开过音录（或改名前的 E1录音助手）。1.2.0 起每次启动都会写
    /// loginItemInitialized、notesFolder、audioFolder，所以老用户哪怕从没碰过转写设置，也一定有几个。
    /// 宁可把新用户认成老用户（默认还是听悟，引导里一点就能换），也不能把老用户的转写悄悄换成本机。
    nonisolated static let usedBeforeKeys = [
        "onboardingDone", "appId", "provider", "noteService", "localEngine", "localNote", "lastCloudProvider",
        "endpoint", "model", "transcriptionModel", "llmModel", "customEndpoint", "customASRModel", "customLLMModel",
        "deepseekModel", "connState", "connStates", "notesFolder", "audioFolder", "template", "templatePath",
        "organizer", "hotwords", "loginItemInitialized", "menuIcon", "budgetYuan", "autoSync", "minDurationSec",
        "noteFormat", "keepAudio", "openInObsidian", "knownSpeakers", "knownNetworks", "placeNames",
        "wifiEnabled", "ossBucket", "ossEndpoint", "wifiIntervalMin", "voiceMemos", "voiceMemosSince",
        "removedRecordings", "lastUpdateCheck", "dismissedUpdate", "budgetAlertMonth",
    ]

    /// 全新安装：上面的键一个都没有
    nonisolated static func isFreshInstall(_ d: UserDefaults) -> Bool {
        !usedBeforeKeys.contains { d.object(forKey: $0) != nil }
    }

    /// 启动时 ① ② 用谁。存过的照用；没存过的，新装是「本机转写 + 先不整理」，老用户是以前的默认（听悟，② 跟着 ① 走）。
    nonisolated static func initialServices(_ d: UserDefaults) -> (provider: Provider, note: NoteService, fresh: Bool) {
        let fresh = isFreshInstall(d)
        let provider = Provider(rawValue: d.string(forKey: "provider") ?? "") ?? (fresh ? .local : .tingwu)
        let note = NoteService(rawValue: d.string(forKey: "noteService") ?? "")
            ?? (fresh ? .off : migratedNoteService(provider: provider, legacyLocalNote: d.string(forKey: "localNote")))
        return (provider, note, fresh)
    }

    /// 自定义平台的接口根地址（去掉末尾的 /）
    var customBase: String { customEndpoint.hasSuffix("/") ? String(customEndpoint.dropLast()) : customEndpoint }

    /// ① 换平台时 ② 跟着给个合适的默认：听悟转写就让听悟一起整理；离开听悟时改成同一个账号能用的大模型
    /// （换到本机转写又没有阿里云密钥时，改成先不整理）；其他情况不动
    nonisolated static func noteService(afterSwitchingTo p: Provider, from current: NoteService, aliyunKey: Bool = true) -> NoteService {
        if p == .tingwu { return .tingwu }
        if current == .tingwu {
            if p == .custom { return .custom }
            return p == .local && !aliyunKey ? .off : .bailian
        }
        return current
    }

    /// ② 从「不整理」切到「用大模型整理」时先选谁：听悟转写就让听悟一起整理，否则千问
    var defaultCloudNoteService: NoteService { provider == .tingwu ? .tingwu : .bailian }

    /// ① 转文字用的云端账号；本机转写为 nil
    var asrAccount: CloudAccount? {
        switch provider {
        case .tingwu, .bailian: .aliyun
        case .custom: .custom
        case .local: nil
        }
    }
    /// ② 整理用的云端账号；本机大模型为 nil
    var noteAccount: CloudAccount? { noteService.account }
    /// 现在的设置用到的云端账号（去重，① 在前）
    var accountsInUse: [CloudAccount] {
        var a: [CloudAccount] = []
        for x in [asrAccount, noteAccount].compactMap({ $0 }) where !a.contains(x) { a.append(x) }
        return a
    }

    func masked(_ a: CloudAccount) -> String? {
        switch a {
        case .aliyun: maskedKey
        case .deepseek: maskedDeepSeekKey
        case .custom: maskedCustomKey
        }
    }
    func hasKey(_ a: CloudAccount) -> Bool { masked(a) != nil }

    /// ① 转文字的密钥有没有填（本机转写不要密钥 → true）
    var hasAPIKey: Bool { asrAccount.map(hasKey) ?? true }

    /// ① 转文字还缺什么；nil = 可以转写。缺了就不转写（录音排队等着）。
    var setupProblem: String? {
        if provider == .local {
            return localReady ? nil : LocalEngines.notReadyReason(localEngine) + "，录音暂不转写"
        }
        if let a = asrAccount, !hasKey(a) { return "还没填写\(a.inSentence)的访问密钥，录音暂不转写" }
        if provider.info.needsAppId && appId.isEmpty { return "还没填写应用编号，录音暂不转写" }
        if provider == .custom && (customEndpoint.isEmpty || customASRModel.isEmpty) { return "自定义平台的地址或识别模型没填完" }
        return nil
    }

    /// ② 整理成纪要还缺什么；nil = 能整理。缺了也照常转写，只是纪要里只有逐字稿。
    var noteProblem: String? {
        switch noteService {
        case .local: return "本机大模型还没做好"
        case .off: return "没选整理服务"
        case .tingwu: return provider == .tingwu ? nil : "通义听悟只能在转文字也用听悟时整理"
        default: break
        }
        if let a = noteAccount, !hasKey(a) { return "还没填写\(a.inSentence)的访问密钥" }
        if noteService == .custom && (customEndpoint.isEmpty || customLLMModel.isEmpty) { return "自定义平台的地址或整理模型没填完" }
        if noteService == .deepseek && deepseekModel.isEmpty { return "DeepSeek 的模型名没填" }
        return nil
    }

    var isConfigured: Bool { setupProblem == nil }

    /// 某个账号上次连接测试的结果
    func connState(_ a: CloudAccount) -> String { connStates[a.rawValue] ?? "untested" }
    /// 账号的密钥、地址改了：这个账号和总的连接状态都要重新测
    func markUntested(_ a: CloudAccount?) {
        if let a { connStates[a.rawValue] = "untested" }
        connState = "untested"
    }
    /// 换了平台或整理服务后，总的连接状态按现在用到的账号重新算（不联网）
    func refreshOverallConn() {
        let states = accountsInUse.map { connState($0) }
        if let f = states.first(where: { $0.hasPrefix("failed:") }) { connState = f }
        else { connState = states.allSatisfy { $0 == "ok" } ? "ok" : "untested" }
    }

    /// Switches platform and keeps the model choice valid for it.
    /// 上次用的云端转写平台：从「本机」切回「云端」时回到它
    var lastCloudProvider: Provider {
        if provider != .local { return provider }
        return Provider(rawValue: d.string(forKey: "lastCloudProvider") ?? "").flatMap { $0 == .local ? nil : $0 } ?? .tingwu
    }

    func setProvider(_ p: Provider) {
        guard p != provider else { return }
        if provider != .local { d.set(provider.rawValue, forKey: "lastCloudProvider") }
        provider = p
        noteService = Self.noteService(afterSwitchingTo: p, from: noteService, aliyunKey: hasKey(.aliyun))
        if p == .local {
            Task { await refreshLocalEngine() }
        } else if let first = p.info.models.first, !p.info.models.contains(where: { $0.id == transcriptionModel }) {
            transcriptionModel = first.id
        }
        refreshOverallConn()
    }

    /// 重新检查本机引擎（启动时、打开服务选项时、下载完中文模型后）
    func refreshLocalEngine() async {
        let ready = await LocalEngines.isReady(localEngine)
        if ready != localReady { localReady = ready }
    }

    func refreshMaskedKey() {
        func mask(_ k: String?) -> String? {
            guard let k else { return nil }
            return k.count > 10 ? String(k.prefix(3)) + String(repeating: "•", count: 10) + String(k.suffix(4)) : String(repeating: "•", count: 10)
        }
        maskedKey = mask(Keychain.read())
        maskedCustomKey = mask(Keychain.read(account: Keychain.customAccount))
        maskedDeepSeekKey = mask(Keychain.read(account: Keychain.deepseekAccount))
        penKeyStored = Keychain.read(account: WifiKeys.penId) != nil && Keychain.read(account: WifiKeys.penSecret) != nil
        macKeyStored = Keychain.read(account: WifiKeys.macId) != nil && Keychain.read(account: WifiKeys.macSecret) != nil
    }

    /// 保存某个云端账号的访问密钥（只进钥匙串）
    @discardableResult
    func saveAPIKey(_ key: String, for a: CloudAccount) -> Bool {
        let ok = Keychain.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: a.keychainAccount)
        refreshMaskedKey()
        markUntested(a)
        return ok
    }

    func deleteAPIKey() {
        Keychain.delete()
        refreshMaskedKey()
    }

    /// Text of the template currently in use.
    var templateText: String {
        switch template {
        case .builtin(let id): return NoteTemplate.builtIn(id).body
        case .custom(let p): return (try? String(contentsOfFile: p, encoding: .utf8)) ?? NoteTemplate.builtIn("standard").body
        }
    }

    // MARK: launch at login
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { Log.app.error("开机启动设置失败：\(error.localizedDescription, privacy: .public)") }
            objectWillChange.send()
        }
    }

    // MARK: export / import (never includes the API key)
    struct Exported: Codable {
        var provider: String; var appId: String; var endpoint: String; var model: String
        var transcriptionModel: String?; var llmModel: String?; var template: String?
        var customEndpoint: String?; var customASRModel: String?; var customLLMModel: String?; var menuIcon: String?
        var openInObsidian: Bool?; var budgetYuan: Int?; var hotwords: String?
        var wifiEnabled: Bool?; var ossEndpoint: String?; var ossBucket: String?; var wifiIntervalMin: Int?
        var knownSpeakers: [String]?; var placeNames: [String: String]?; var knownNetworks: [String: String]?
        var noteFormat: String?; var keepAudio: Bool?; var voiceMemos: Bool?
        var localEngine: String?; var localNote: String?; var noteService: String?; var deepseekModel: String?
        var notesFolder: String; var audioFolder: String
        var organizer: String; var minDurationSec: Int; var autoSync: Bool
    }

    func exportConfig(to url: URL) throws {
        var tpl = template
        if case .custom(let p) = template { tpl = .custom(tildify(p)) }
        let e = Exported(provider: provider.rawValue, appId: appId, endpoint: endpoint, model: model,
                         transcriptionModel: transcriptionModel, llmModel: llmModel, template: tpl.raw,
                         customEndpoint: customEndpoint, customASRModel: customASRModel, customLLMModel: customLLMModel, menuIcon: menuIcon,
                         openInObsidian: openInObsidian, budgetYuan: budgetYuan, hotwords: hotwords,
                         wifiEnabled: wifiEnabled, ossEndpoint: ossEndpoint, ossBucket: ossBucket, wifiIntervalMin: wifiIntervalMin,
                         knownSpeakers: knownSpeakers, placeNames: placeNames, knownNetworks: knownNetworks,
                         noteFormat: noteFormat, keepAudio: keepAudio, voiceMemos: voiceMemos,
                         localEngine: localEngine, localNote: nil, noteService: noteService.rawValue, deepseekModel: deepseekModel,
                         notesFolder: tildify(notesFolder), audioFolder: tildify(audioFolder),
                         organizer: organizer, minDurationSec: minDurationSec, autoSync: autoSync)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(e).write(to: url)
    }

    /// Secrets an imported configuration still needs on this Mac (they never travel in the file).
    var missingSecrets: [String] {
        var m: [String] = []
        for a in accountsInUse where !hasKey(a) { m.append(a.inSentence + "的访问密钥") }
        if wifiEnabled || !ossBucket.isEmpty {
            if !penKeyStored { m.append("WiFi 录音笔用的钥匙") }
            if !macKeyStored { m.append("WiFi Mac 用的钥匙") }
        }
        return m
    }

    func importConfig(from url: URL) throws {
        let e = try JSONDecoder().decode(Exported.self, from: Data(contentsOf: url))
        provider = Provider(rawValue: e.provider) ?? .tingwu
        appId = e.appId; endpoint = e.endpoint; model = e.model
        transcriptionModel = e.transcriptionModel ?? "fun-asr"
        llmModel = e.llmModel ?? "qwen-plus"
        if let v = e.localEngine { localEngine = v }
        noteService = e.noteService.flatMap(NoteService.init(rawValue:))
            ?? Self.migratedNoteService(provider: provider, legacyLocalNote: e.localNote)
        if let v = e.deepseekModel { deepseekModel = v }
        if let v = e.customEndpoint { customEndpoint = v }
        if let v = e.customASRModel { customASRModel = v }
        if let v = e.customLLMModel { customLLMModel = v }
        if let v = e.menuIcon { menuIcon = MenuBarIcon.normalized(v) }
        if let v = e.openInObsidian { openInObsidian = v }
        if let v = e.budgetYuan { budgetYuan = v }
        if let v = e.hotwords { hotwords = v }
        if let v = e.wifiEnabled { wifiEnabled = v }
        if let v = e.ossEndpoint { ossEndpoint = v }
        if let v = e.ossBucket { ossBucket = v }
        if let v = e.wifiIntervalMin { wifiIntervalMin = v }
        if let v = e.noteFormat { noteFormat = v }
        if let v = e.keepAudio { keepAudio = v }
        if let v = e.voiceMemos { voiceMemos = v }   // on a new Mac it starts from now, never from the old Mac's date
        if let v = e.knownSpeakers { knownSpeakers = Array(Set(knownSpeakers + v)).sorted() }
        if let v = e.placeNames { placeNames.merge(v) { _, new in new } }
        if let v = e.knownNetworks { knownNetworks.merge(v) { old, _ in old } }
        connState = "untested"; connStates = [:]
        if let t = e.template {
            var c = TemplateChoice(raw: t)
            if case .custom(let p) = c { c = .custom(untildify(p)) }
            template = c
        }
        notesFolder = untildify(e.notesFolder); audioFolder = untildify(e.audioFolder)
        organizer = e.organizer; minDurationSec = e.minDurationSec; autoSync = e.autoSync
    }

    /// Paths are exported relative to the home folder so they work under another user name.
    private func tildify(_ p: String) -> String {
        let h = NSHomeDirectory()
        return p.hasPrefix(h) ? "~" + p.dropFirst(h.count) : p
    }

    private func untildify(_ p: String) -> String {
        p.hasPrefix("~") ? NSHomeDirectory() + p.dropFirst(1) : p
    }
}

/// All secrets (the platform key, the custom-platform key and the two WiFi AccessKeys) live in ONE Keychain item,
/// so a freshly built copy of the app asks for Keychain access once instead of once per key.
/// The item is read once per launch and kept in memory.
enum Keychain {
    static let service = "E1Recorder"
    static let account = "bailian-api-key"
    static let customAccount = "custom-api-key"
    static let deepseekAccount = "deepseek-api-key"
    private static let bundleAccount = "all-keys"
    private static var cache: [String: String]?

    static func read(account: String = account) -> String? {
        load()[account].flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func write(_ value: String, account: String = account) -> Bool {
        var d = load()
        d[account] = value
        cache = d
        return save(d)
    }

    static func delete(account: String = account) {
        var d = load()
        d.removeValue(forKey: account)
        cache = d
        save(d)
    }

    private static func load() -> [String: String] {
        if let c = cache { return c }
        var dict: [String: String] = [:]
        if let json = rawRead(bundleAccount),
           let d = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) {
            dict = d
        } else {
            // One-time move from the separate items older versions used.
            for a in [account, customAccount, WifiKeys.penId, WifiKeys.penSecret, WifiKeys.macId, WifiKeys.macSecret] {
                if let v = rawRead(a) { dict[a] = v }
            }
            if !dict.isEmpty, save(dict) { for a in dict.keys { rawDelete(a) } }
        }
        cache = dict
        return dict
    }

    @discardableResult
    private static func save(_ d: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(d), let json = String(data: data, encoding: .utf8) else { return false }
        return rawWrite(json, bundleAccount)
    }

    // MARK: raw Keychain access

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func rawRead(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func rawWrite(_ value: String, _ account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "音录 访问密钥"
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func rawDelete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
