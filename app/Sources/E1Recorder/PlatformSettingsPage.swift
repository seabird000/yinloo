import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 服务选项：录音变成纪要分两步，① 转文字、② 整理成纪要，每步各自选本机或云端。
/// 选了云端，那一家的访问密钥就在那一步下面填；两步用同一家时只填一次。费用统一放在最下面。
/// ① 的云端几行（CloudASRRows）、② 的几行（NoteServiceRows）和账号几行（AccountRows）引导页也用。
struct PlatformSettingsPage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    /// 正在下载苹果的中文语音模型（进度 0～1）
    @State private var installing: Double?
    @State private var installError: String?
    @ObservedObject private var models = ModelStore.shared
    @Environment(\.openSubpage) private var openSubpage

    var body: some View {
        Form {
            Section { FlowDiagram() }

            Section {
                ModeCards(selection: asrMode, options: [
                    .init(id: "local", icon: "laptopcomputer", title: "本机转写", detail: "免费，录音不出这台 Mac", tint: .e1Green),
                    .init(id: "cloud", icon: "cloud", title: "云端转写", detail: "按量付费，不占电脑"),
                ])
                if s.provider == .local { localASRRows } else { CloudASRRows() }
            } header: {
                SectionTitle("① 转文字", info: "本机转写用开源模型在这台 Mac 上转，免费，录音不上传，第一次要下载模型（约 136 MB）。云端转写把录音上传到所选平台，按量付费，要用你自己的账号。每条转完都会检查有没有漏转，漏得多会在纪要顶部提醒。")
            }

            Section {
                ModeCards(selection: noteMode, options: [
                    .init(id: "local", icon: "laptopcomputer", title: "本机大模型", detail: "免费，文字不出这台 Mac", badge: "即将支持",
                          enabled: false, tint: .e1Green),
                    .init(id: "cloud", icon: "cloud", title: "云端大模型", detail: "按量付费，1 小时几分钱"),
                ])
                if s.noteService != .local { NoteServiceRows() }
            } header: {
                SectionTitle("② 整理成纪要", info: "把逐字稿整理成摘要、要点、待办和章节。整理时只发文字，不发录音。本机大模型（在这台 Mac 上整理，不联网）还在做。整理服务没设置好或选了「先不整理」时，录音照常转写，纪要里只有逐字稿。")
            }

            Section {
                costRows
            } header: {
                SectionTitle("费用", info: "按官方价格估算：通义听悟约 ¥0.79/小时，百炼语音约 ¥0.81/小时；千问、DeepSeek 整理 1 小时录音只要几分钱。实际以各平台的账单为准，例如[阿里云费用中心](https://usercenter2.aliyun.com/home)。本月用量和预算提醒按转文字的费用算，到预算的 80% 时提醒一次。")
            }
        }
        .task { await s.refreshLocalEngine() }
    }

    /// ① 选本机还是云端：切回云端时回到上次用的平台
    private var asrMode: Binding<String> {
        Binding(get: { s.provider == .local ? "local" : "cloud" },
                set: { s.setProvider($0 == "local" ? .local : s.lastCloudProvider) })
    }

    /// ② 选本机还是云端（本机大模型还没做，卡片是灰的）。选了「先不整理」时两张卡片都不亮
    private var noteMode: Binding<String> {
        Binding(get: { s.noteService == .local ? "local" : s.noteService == .off ? "off" : "cloud" },
                set: { v in
                    if v == "cloud", s.noteService == .local || s.noteService == .off { s.noteService = s.defaultCloudNoteService }
                })
    }

    // MARK: ① 转文字

    @ViewBuilder private var localASRRows: some View {
        Picker("识别引擎", selection: $s.localEngine) {
            ForEach(LocalModels.all) { Text($0.name).tag($0.id) }
            if LocalEngines.appleSupported { Text("苹果自带").tag("apple") }
        }
        if let m = LocalModels.find(s.localEngine) {
            let st = models.state(m)
            LabeledContent {
                HStack(spacing: 8) {
                    if case .installed = st { Dot(kind: .ok) }
                    if case .downloading = st, let f = st.fraction { ProgressView(value: f).frame(width: 80) }
                    Text(st == .notInstalled ? "未下载（约 \(m.downloadSize / 1_000_000) MB）" : st.label)
                        .foregroundStyle(st.isFailure ? Color.e1Red : .secondary).lineLimit(1)
                    ModelActions(model: m)
                }
            } label: {
                Text("语音模型")
                Text(m.note)
            }
            LabeledContent("本机模型") {
                Button("管理…") { openSubpage("local-models") }
            }
        } else {
            appleModelRow
        }
    }

    // MARK: 费用

    @ViewBuilder private var costRows: some View {
        LabeledContent("① 转文字") { Text(asrCost).foregroundStyle(.secondary) }
        LabeledContent("② 整理成纪要") { Text(noteCost).foregroundStyle(.secondary) }
        if s.provider == .local {
            Text(s.noteService == .local ? "两步都在本机，不花钱。"
                 : s.noteService == .off ? "转文字在本机不花钱，现在只出逐字稿。"
                 : s.noteProblem != nil ? "转文字在本机不花钱；整理还没设置好，现在只出逐字稿。"
                 : "转文字在本机不花钱，整理每小时只要几分钱，不用设预算。")
                .font(.e1Sub).foregroundStyle(Color.t2)
        } else {
            UsageRow(slices: pipeline.monthUsageBySource, budget: s.budgetYuan)
            Picker("预算提醒", selection: $s.budgetYuan) {
                Text("不提醒").tag(0)
                ForEach([30, 50, 100, 200], id: \.self) { Text("每月 ¥\($0)").tag($0) }
            }
        }
    }

    private var asrCost: String {
        switch s.provider {
        case .local: "免费（本机）"
        case .tingwu: "约 ¥0.79/小时（通义听悟）"
        case .bailian: "约 ¥0.81/小时（百炼语音）"
        case .custom: "按该平台的价格"
        }
    }

    private var noteCost: String {
        if s.noteProblem != nil { return "暂不整理，不花钱" }
        return s.noteService.cost + (s.noteService == .tingwu || s.noteService == .local ? "" : "（\(s.noteService.shortName)）")
    }

    // MARK: 苹果自带的语音模型

    @ViewBuilder private var appleModelRow: some View {
        LabeledContent("中文语音模型") {
            if !LocalEngines.appleSupported {
                Text("需要 macOS 26 或更新").foregroundStyle(.secondary)
            } else if s.localReady {
                HStack(spacing: 6) { Dot(kind: .ok); Text("已就绪") }
            } else if let p = installing {
                HStack(spacing: 8) { ProgressView(value: p).frame(width: 90); Text("\(Int(p * 100))%").monospacedDigit() }
            } else {
                HStack(spacing: 8) {
                    if let installError { Text(installError).foregroundStyle(Color.e1Red).lineLimit(1) }
                    Button("下载（来自苹果）") { installAppleModel() }
                }
            }
        }
    }

    private func installAppleModel() {
        installing = 0
        installError = nil
        Task {
            do {
                try await LocalEngines.installAppleChinese { p in Task { @MainActor in if installing != nil { installing = p } } }
            } catch {
                installError = error.localizedDescription
            }
            installing = nil
            await s.refreshLocalEngine()
        }
    }
}

/// ① 转文字选了云端时的几行：哪个平台、识别模型、这家的访问密钥（听悟还要应用编号）。
struct CloudASRRows: View {
    @EnvironmentObject var s: AppSettings
    @State private var editingModel = false

    var body: some View {
        Picker(selection: Binding(get: { s.provider }, set: { s.setProvider($0) })) {
            Text(Provider.tingwu.info.name).tag(Provider.tingwu)
            Text(Provider.bailian.info.name).tag(Provider.bailian)
            Divider()
            Text("自定义（OpenAI 兼容）…").tag(Provider.custom)
            // 只为切换的一瞬间：本机不在这个菜单里选，免得菜单显示空白
            if s.provider == .local { Text(Provider.local.info.name).tag(Provider.local) }
        } label: {
            Text("服务平台")
            Text(s.provider.info.summary)
        }
        if s.provider == .custom {
            LabeledContent {
                HStack { Trailing(text: s.customASRModel); Button("编辑…") { editingModel = true } }
            } label: { Text("识别模型") }
            .sheet(isPresented: $editingModel) {
                EditSheet(title: "编辑识别模型", help: "该平台语音转文字的模型名，例如 gpt-transcribe、FunAudioLLM/SenseVoiceSmall。OpenAI 的 whisper-1、gpt-4o-transcribe 等 2027-02-26 停用。",
                          placeholder: "gpt-transcribe", initial: s.customASRModel,
                          validate: { $0.contains(" ") ? "模型名不能有空格" : nil }, save: { s.customASRModel = $0; s.markUntested(.custom) })
            }
        } else {
            Picker("识别模型", selection: $s.transcriptionModel) {
                ForEach(s.provider.info.models) { Text($0.label).tag($0.id) }
            }
            .disabled(s.provider.info.models.count < 2)
        }
        if let a = s.asrAccount { AccountRows(account: a, appId: s.provider == .tingwu) }
    }
}

/// ② 整理成纪要的几行：交给谁、用哪个模型、访问密钥（和 ① 同一家就不再填）、没设置好时的提示。
struct NoteServiceRows: View {
    @EnvironmentObject var s: AppSettings
    private enum Edit: String, Identifiable { case llmModel, deepseekModel; var id: String { rawValue } }
    @State private var editing: Edit?

    var body: some View {
        Picker(selection: Binding(get: { s.noteService }, set: { s.noteService = $0 })) {
            if s.provider == .tingwu {
                Text(NoteService.tingwu.name).tag(NoteService.tingwu)
                Divider()
            }
            Text(NoteService.bailian.name).tag(NoteService.bailian)
            Text(NoteService.deepseek.name).tag(NoteService.deepseek)
            Text(NoteService.custom.name + "…").tag(NoteService.custom)
            Divider()
            Text(NoteService.off.name).tag(NoteService.off)
            // 听悟只在 ① 也是听悟时可选；本机大模型还没做。存着的是它们时也给个名字，免得菜单显示空白
            if s.noteService == .local || (s.noteService == .tingwu && s.provider != .tingwu) {
                Text(s.noteService.name).tag(s.noteService)
            }
        } label: {
            Text("整理服务")
            Text(s.noteService.summary)
        }
        .sheet(item: $editing) { e in sheet(e) }
        switch s.noteService {
        case .bailian:
            Picker("整理模型", selection: $s.llmModel) {
                ForEach(PlatformInfo.llmModels) { Text($0.label).tag($0.id) }
            }
        case .deepseek:
            LabeledContent {
                HStack { Trailing(text: s.deepseekModel); Button("编辑…") { editing = .deepseekModel } }
            } label: { Text("整理模型") }
        case .custom:
            LabeledContent {
                HStack { Trailing(text: s.customLLMModel); Button("编辑…") { editing = .llmModel } }
            } label: { Text("整理模型") }
        case .tingwu, .local, .off:
            EmptyView()
        }
        if let a = s.noteAccount, s.noteService != .tingwu {
            if a == s.asrAccount {
                LabeledContent {
                    Text("和 ① 用同一个").foregroundStyle(.secondary)
                } label: {
                    Text("访问密钥")
                    Text("\(a.inSentence)的密钥，不用再填")
                }
            } else {
                AccountRows(account: a)
            }
        }
        if s.noteService == .off {
            Text("录音照常转成文字，纪要里只有逐字稿。想要摘要、要点和待办，在上面选一个大模型，填上它的访问密钥。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let why = s.noteProblem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(why)。填好之前录音照常转写，纪要里只有逐字稿。")
                    .foregroundStyle(Color.t1).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func sheet(_ e: Edit) -> some View {
        switch e {
        case .llmModel:
            EditSheet(title: "编辑整理模型", help: "这个平台上对话模型的名字，照该平台控制台里写的填，例如 Kimi、智谱、豆包各自的模型名。",
                      placeholder: "模型名", initial: s.customLLMModel,
                      validate: { $0.contains(" ") ? "模型名不能有空格" : nil }, save: { s.customLLMModel = $0; s.markUntested(.custom) })
        case .deepseekModel:
            EditSheet(title: "编辑 DeepSeek 模型", help: "一般不用改。2026-09 起官方模型名是 deepseek-flash（deepseek-chat 已停用）；DeepSeek 以后换了名字，在这里改。",
                      placeholder: DeepSeekAPI.defaultModel, initial: s.deepseekModel,
                      validate: { $0.contains(" ") ? "模型名不能有空格" : nil }, save: { s.deepseekModel = $0; s.markUntested(.deepseek) })
        }
    }
}

/// 一个云端账号的几行：访问密钥、应用编号（听悟）、接口地址、连接状态。跟在用到它的那一步下面。
struct AccountRows: View {
    let account: CloudAccount
    var appId = false
    @EnvironmentObject var s: AppSettings
    private enum Edit: String, Identifiable { case key, endpoint, appId; var id: String { rawValue } }
    @State private var editing: Edit?
    @State private var testing = false

    var body: some View {
        let a = account
        LabeledContent {
            HStack { Trailing(text: s.masked(a) ?? "未填写"); Button(s.hasKey(a) ? "修改…" : "填写…") { editing = .key } }
        } label: {
            Text("访问密钥")
            Text(.init(a.keyWhere))
        }
        .sheet(item: $editing) { e in sheet(e) }
        if appId {
            LabeledContent {
                HStack { Trailing(text: s.appId.isEmpty ? "未填写" : s.appId); Button("编辑…") { editing = .appId } }
            } label: {
                Text("应用编号")
                Text("百炼控制台 › 应用 › 通义听悟，以 tw_ 开头")
            }
        }
        switch a {
        case .aliyun:
            LabeledContent("接口地址") {
                HStack { Trailing(text: URL(string: s.endpoint)?.host ?? s.endpoint); Button("编辑…") { editing = .endpoint } }
            }
        case .custom:
            LabeledContent("接口地址") {
                HStack { Trailing(text: s.customEndpoint.replacingOccurrences(of: "https://", with: "")); Button("编辑…") { editing = .endpoint } }
            }
        case .deepseek:
            EmptyView()
        }
        LabeledContent("连接状态") {
            HStack(spacing: 8) {
                connStatus
                Button(s.connState(a).hasPrefix("failed") ? "重试" : "测试连接") {
                    Task { testing = true; await PlatformTest.run(s, only: a); testing = false }
                }
                .disabled(testing || !s.hasKey(a))
            }
        }
    }

    @ViewBuilder private var connStatus: some View {
        let st = s.connState(account)
        if !s.hasKey(account) {
            HStack(spacing: 6) { Dot(kind: .off); Text("未填写密钥").foregroundStyle(.secondary) }
        } else if testing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在测试…").foregroundStyle(.secondary) }
        } else if st == "ok" {
            HStack(spacing: 6) { Dot(kind: .ok); Text("正常") }
        } else if st.hasPrefix("failed:") {
            HStack(spacing: 6) { Dot(kind: .bad); Text(String(st.dropFirst(7))).lineLimit(1).frame(maxWidth: 220, alignment: .trailing) }
                .help(String(st.dropFirst(7)))
        } else {
            HStack(spacing: 6) { Dot(kind: .off); Text("未测试").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func sheet(_ e: Edit) -> some View {
        let a = account
        switch e {
        case .key:
            EditSheet(title: "填写\(a.inSentence)的访问密钥", help: a.keyHelp, placeholder: a.keyPlaceholder, secure: true, initial: "",
                      validate: { a.validate($0) }, save: { s.saveAPIKey($0, for: a) })
        case .appId:
            EditSheet(title: "编辑应用编号", help: "在百炼控制台 › 应用 › 通义听悟·智能纪要 › 我的应用中复制，以 tw_ 开头。",
                      placeholder: "tw_…", initial: s.appId,
                      validate: { $0.hasPrefix("tw_") ? nil : "应以 tw_ 开头" },
                      save: { s.appId = $0; s.markUntested(.aliyun) })
        case .endpoint where a == .custom:
            EditSheet(title: "编辑接口地址", help: "OpenAI 兼容接口的根地址，一般以 /v1 结尾，例如 https://api.moonshot.cn/v1。",
                      placeholder: "https://api.example.com/v1", initial: s.customEndpoint,
                      validate: { $0.hasPrefix("https://") && URL(string: $0)?.host != nil ? nil : "应以 https:// 开头" },
                      save: { s.customEndpoint = $0.hasSuffix("/") ? String($0.dropLast()) : $0; s.markUntested(.custom) })
        case .endpoint:
            EditSheet(title: "编辑接口地址", help: "一般不用改。国际站账号可改为 https://dashscope-intl.aliyuncs.com。",
                      placeholder: "https://dashscope.aliyuncs.com", initial: s.endpoint,
                      validate: { $0.hasPrefix("https://") && URL(string: $0)?.host != nil ? nil : "应以 https:// 开头" },
                      save: { s.endpoint = $0.hasSuffix("/") ? String($0.dropLast()) : $0; s.markUntested(.aliyun) })
        }
    }
}

/// 页面顶上的流程图：录音 → ① 转文字 → ② 整理成纪要 → 资料库。
/// 四格一样的结构（图标、名字、标签、现在用的是什么）；①② 用颜色标出本机（绿）还是云端（蓝），没设置好是橙色。
private struct FlowDiagram: View {
    @EnvironmentObject var s: AppSettings

    private enum Kind { case context, local, cloud, off }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                node("waveform", "录音", tag: "输入", detail: "录音笔、手机、电脑", kind: .context)
                arrow
                node("text.quote", "① 转文字", tag: s.provider == .local ? "本机" : "云端", detail: asrDetail,
                     kind: s.provider == .local ? .local : .cloud)
                arrow
                node("list.bullet.rectangle", "② 整理成纪要", tag: noteTag, detail: noteDetail, kind: noteKind)
                arrow
                node("books.vertical", "资料库", tag: "沉淀", detail: "Markdown 文件", kind: .context)
            }
            HStack(spacing: 16) {
                legend(.local, "本机：免费，不上传")
                legend(.cloud, "云端：不占电脑，按量付费")
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private var asrDetail: String {
        switch s.provider {
        case .local: LocalEngines.name(s.localEngine)
        case .custom: URL(string: s.customEndpoint)?.host ?? "自定义"
        default: s.provider.info.name
        }
    }
    private var noteKind: Kind { s.noteProblem != nil ? .off : s.noteService == .local ? .local : .cloud }
    private var noteTag: String {
        switch noteKind {
        case .off: s.noteService == .off ? "不整理" : "未设置"
        case .local: "本机"
        default: "云端"
        }
    }
    private var noteDetail: String {
        if s.noteProblem != nil { return "只出逐字稿" }
        switch s.noteService {
        case .bailian: return PlatformInfo.llmModels.first { $0.id == s.llmModel }?.label ?? s.llmModel
        case .custom: return s.customLLMModel
        default: return s.noteService.shortName
        }
    }

    private func color(_ k: Kind) -> Color {
        switch k {
        case .context: Color.t2
        case .local: Color.e1Green
        case .cloud: Color.e1Blue
        case .off: Color.orange
        }
    }

    private func node(_ icon: String, _ title: String, tag: String, detail: String, kind: Kind) -> some View {
        let c = color(kind)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(c)
                .frame(width: 30, height: 30)
                .background(Circle().fill(c.opacity(kind == .context ? 0.10 : 0.15)))
            Text(title).font(.e1Body.weight(.semibold)).foregroundStyle(Color.t1).lineLimit(1).minimumScaleFactor(0.8)
            Text(tag).font(.system(size: 10, weight: .medium)).foregroundStyle(c).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(c.opacity(kind == .context ? 0.10 : 0.14)))
            Text(detail).font(.e1Sub).foregroundStyle(Color.t2).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(shape.fill(kind == .context ? Color.clear : c.opacity(0.06)))
        .overlay(shape.strokeBorder(kind == .context ? Color.primary.opacity(0.18) : c.opacity(0.55),
                                    style: StrokeStyle(lineWidth: 1, dash: kind == .context ? [3, 3] : [])))
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.t3)
            .frame(width: 20)
    }

    private func legend(_ k: Kind, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color(k)).frame(width: 7, height: 7)
            Text(text).font(.e1Sub).foregroundStyle(Color.t2)
        }
    }
}

/// 并排的几张选择卡片（本机 / 云端……），比下拉菜单更能看出「有几种方式、各自什么代价」
struct ModeOption: Identifiable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    var badge: String? = nil
    var enabled = true
    /// 选中时的颜色：和顶上流程图一致，本机绿、云端蓝
    var tint: Color = .e1Blue
}

struct ModeCards: View {
    @Binding var selection: String
    let options: [ModeOption]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options) { o in
                let on = selection == o.id
                Button { selection = o.id } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: o.icon).foregroundStyle(on ? o.tint : Color.t2)
                            Text(o.title).font(.e1Body.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            if on { Image(systemName: "checkmark.circle.fill").foregroundStyle(o.tint) }
                        }
                        HStack(spacing: 4) {
                            if let b = o.badge {
                                Text(b).font(.system(size: 10)).foregroundStyle(Color.t2).lineLimit(1)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.t3, lineWidth: 0.5))
                            }
                            Text(o.detail).font(.e1Sub).foregroundStyle(Color.t2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? o.tint.opacity(0.08) : Color.primary.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? o.tint : Color.e1Sep, lineWidth: on ? 1.5 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!o.enabled)
                .opacity(o.enabled ? 1 : 0.5)
                .accessibilityLabel(o.title + "，" + o.detail)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
