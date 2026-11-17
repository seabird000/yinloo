import AppKit
import SwiftUI

/// Preferences › 设备 › 语音备忘录.
struct VoiceMemosDevicePage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline

    var body: some View {
        Form {
            DeviceHeader(kind: .voiceMemos) {
                let st = pipeline.deviceStatus(.voiceMemos)
                if !pipeline.manualSync, pipeline.syncResult == nil {
                    Text(st.tag + (s.voiceMemos ? "" : " · 苹果「语音备忘录」App 里的录音")).font(.e1Sub)
                        .foregroundStyle(st.level == .problem ? Color.e1Red : Color.t2).lineLimit(1)
                }
            }
            VoiceMemosSection()
            RecentMemosSection()
        }
        .onAppear {
            if s.voiceMemos { Task { await pipeline.scanVoiceMemos(force: true) } }
        }
    }
}

/// The switch, and what the last look found.
struct VoiceMemosSection: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline

    var body: some View {
        Section {
            Toggle(isOn: $s.voiceMemos) {
                Text("自动转写新录音")
                Text("这台 Mac 上录的，以及 iPhone 上录完经 iCloud 同步过来的")
            }
            .toggleStyle(.switch)
            if s.voiceMemos {
                LabeledContent {
                    StatusTag(text: pipeline.deviceStatus(.voiceMemos).tag, color: pipeline.deviceStatus(.voiceMemos).level.color)
                } label: {
                    Text("状态")
                    Text(detail)
                }
                if pipeline.memoScan?.problem == .noAccess {
                    HStack {
                        Spacer()
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        Button("重新检查") { Task { await pipeline.scanVoiceMemos(force: true) } }
                    }
                }
            }
        } header: {
            SectionTitle("自动转写", info: "苹果「语音备忘录」里的新录音，停止录音约一分钟后自动转写，和录音笔的录音一样生成纪要。iPhone 上的录音由系统通过 iCloud 同步到这台 Mac，不用打开语音备忘录 App。\n\n只读取，不会改动或删除语音备忘录里的录音。开关打开之前录的不会自动转写（避免一次扣很多费用），需要的话在下面的列表里点「转写」。\n\n录音会拷一份到录音目录下的「语音备忘录」文件夹，纪要存到纪要目录。")
        }
        .onChange(of: s.voiceMemos) { _, on in
            if on { Task { await pipeline.scanVoiceMemos(force: true) } }
        }
    }

    private var detail: String {
        guard let scan = pipeline.memoScan else { return "正在查找语音备忘录…" }
        switch scan.problem {
        case .noAccess?:
            return "macOS 没让本应用读取语音备忘录。请在「系统设置 › 隐私与安全性 › 完全磁盘访问权限」里打开「音录」；打开后仍不行，退出本应用再打开。"
        case .notFound?:
            return "这台 Mac 上还没有语音备忘录。iPhone 上的录音要在 iPhone 和这台 Mac 的 iCloud 设置里都打开「语音备忘录」才会同步过来。"
        case .audioFolder?:
            return "录音目录现在用不了（移动硬盘没接？），接上后自动继续。"
        case .failed(let why)?:
            return why
        case nil:
            return pipeline.deviceStatus(.voiceMemos).line
                + (scan.settling > 0 ? " · \(scan.settling) 条正在录音或同步，好了就转写" : "")
        }
    }
}

/// What's in Voice Memos, newest first, and where each recording stands. Ones the switch doesn't cover can be
/// transcribed one by one.
struct RecentMemosSection: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @State private var showAll = false

    var body: some View {
        let memos = pipeline.memoList
        let done = memos.filter { pipeline.memoState($0) == .job(.done) }.count
        Section {
            if !s.voiceMemos {
                Text("打开「自动转写新录音」后，这里列出语音备忘录里的录音。").foregroundStyle(.secondary)
            } else if memos.isEmpty {
                Text(pipeline.memoScan == nil ? "正在读取…" : pipeline.memoScan?.problem != nil ? "现在读不到语音备忘录" : "语音备忘录里还没有录音")
                    .foregroundStyle(.secondary)
            }
            if s.voiceMemos {
                ForEach(showAll ? memos : Array(memos.prefix(6)), id: \.file) { m in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Pipeline.memoTitle(m)).lineLimit(1)
                            Text(DateFormatter.cached("M月d日 HH:mm").string(from: m.created)
                                 + (m.durationSec >= 0 ? " · " + MarkdownRenderer.duration(m.durationSec) : ""))
                                .font(.e1Sub).foregroundStyle(Color.t2)
                        }
                        Spacer(minLength: 8)
                        state(m)
                    }
                }
                if memos.count > 6 {
                    Button(showAll ? "收起" : "显示全部 \(memos.count) 条") { withAnimation { showAll.toggle() } }.buttonStyle(.link)
                }
            }
        } header: {
            HStack {
                SectionTitle("语音备忘录里的录音", info: "「待转写」的会自动转写；开关打开之前录的显示「转写」按钮，点了才转写这一条（按时长计费）。在语音备忘录里删到「最近删除」的不显示。")
                Spacer()
                if s.voiceMemos, !memos.isEmpty {
                    Text("\(memos.count) 条 · 已转写 \(done) 条").font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func state(_ m: VoiceMemos.Memo) -> some View {
        switch pipeline.memoState(m) {
        case .job(.done): StatusTag(text: "已转写", color: .e1Green)
        case .job(.transcribing): StatusTag(text: "转写中", color: .e1Blue)
        case .job(.queued): StatusTag(text: "排队中", color: .secondary)
        case .job(.failed): StatusTag(text: "转写失败", color: .e1Red)
        case .importing: HStack(spacing: 5) { ProgressView().controlSize(.small); Text("拷贝中").font(.e1Sub).foregroundStyle(Color.t2) }
        case .settling: StatusTag(text: "同步中", color: .orange)
        case .waiting: StatusTag(text: "待转写", color: .orange)
        case .tooShort: StatusTag(text: "太短", color: .secondary)
        case .notTaken:
            Button("转写") { pipeline.transcribeMemo(m) }
                .help("开关打开之前录的，不会自动转写；点按转写这一条")
        case .removed:
            Button("重新转写") { pipeline.transcribeMemo(m) }
                .help("这条转写过，后来从转写记录里移除了")
        }
    }
}
