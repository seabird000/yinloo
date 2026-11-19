import AppKit
import SwiftUI

/// Preferences › 设备 › 搜狗 C1 Max.
struct C1MaxDevicePage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline

    var body: some View {
        Form {
            DeviceHeader(kind: .c1Max) {
                let st = pipeline.deviceStatus(.c1Max)
                if !pipeline.manualSync, pipeline.syncResult == nil {
                    Text(([st.shortText] + [pipeline.c1.volume == nil ? nil : pipeline.c1LastSync.map { "上次同步 " + DateFormatter.cached("HH:mm").string(from: $0) }]
                        .compactMap { $0 }).joined(separator: " · ")).font(.e1Sub).foregroundStyle(st.level == .problem ? Color.e1Red : Color.t2).lineLimit(1)
                }
            }
            C1MaxSection()
            C1MaxRecordingsSection()
        }
    }
}

/// 连接状态、自动导入开关、时间提示。引导「设备」页也用（标题换成「搜狗 C1 Max」）。
struct C1MaxSection: View {
    var title = "连接"
    var compact = false
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline

    var body: some View {
        let st = pipeline.deviceStatus(.c1Max)
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if pipeline.c1.phase == .mounted, !compact {
                        Button("推出") { C1MaxDisk.shared.eject() }
                            .help("卸下录音笔的存储，之后可以直接拔线")
                    }
                    StatusTag(text: st.tag, color: st.level.color)
                }
            } label: {
                Text("USB 有线")
                Text(connectionDetail)
            }
            if !compact {
                Toggle(isOn: $s.c1MaxAuto) {
                    Text("自动转写新录音")
                    Text("插上后自动拷新录音，按「服务选项」转写")
                }
                .toggleStyle(.switch)
            }
            if pipeline.c1UncertainCount > 0 {
                Label {
                    Text("有 \(pipeline.c1UncertainCount) 条录音的时间不准：笔断电后时钟会停。请在笔的设置里重设时间；这几条按拷到 Mac 的时间记。")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                .font(.e1Sub).foregroundStyle(Color.t2)
            }
        } header: {
            SectionTitle(title, info: "插上数据线就能用，不用设置。只读取，不改动、不删除笔上的文件。\n\n第一次插上时笔里已有的录音不自动转写，要的话在下面点「转写」。")
        }
    }

    private var connectionDetail: String {
        switch pipeline.c1.phase {
        case .absent: "用数据线把 C1 Max 连到这台 Mac 就行，不用设置"
        case .mounted: (["只读，不改动笔上的文件"] + [pipeline.c1.freeBytes.map { "可用 " + formatBytes($0) }].compactMap { $0 }).joined(separator: " · ")
        default: pipeline.deviceStatus(.c1Max).line
        }
    }
}

/// 笔里的录音，新的在前，每条的状态；第一次插上时就在笔里的可以逐条转写。
struct C1MaxRecordingsSection: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @State private var showAll = false

    var body: some View {
        let recs = pipeline.c1List
        let done = recs.filter { pipeline.c1State($0) == .job(.done) }.count
        Section {
            if pipeline.c1.volume == nil {
                Text("插上 C1 Max 后，这里列出笔里的录音。").foregroundStyle(.secondary)
            } else if recs.isEmpty {
                Text(pipeline.c1Syncing ? "正在读取…" : "笔里还没有录音").foregroundStyle(.secondary)
            }
            ForEach(showAll ? recs : Array(recs.prefix(8)), id: \.key) { r in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.category + (pipeline.c1TimeOff(r) ? "（时间不准）" : " " + DateFormatter.cached("M月d日 HH:mm").string(from: r.created!)))
                            .lineLimit(1)
                        Text(MarkdownRenderer.duration(r.durationSec) + " · " + formatBytes(r.size))
                            .font(.e1Sub).foregroundStyle(Color.t2)
                    }
                    Spacer(minLength: 8)
                    state(r)
                }
            }
            if recs.count > 8 {
                Button(showAll ? "收起" : "显示全部 \(recs.count) 条") { withAnimation { showAll.toggle() } }.buttonStyle(.link)
            }
        } header: {
            HStack {
                SectionTitle("笔里的录音", info: "「待转写」的会自动转写；点「转写」只转这一条。")
                Spacer()
                if !recs.isEmpty {
                    Text("\(recs.count) 条 · 已转写 \(done) 条").font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func state(_ r: C1Max.Recording) -> some View {
        switch pipeline.c1State(r) {
        case .job(.done): StatusTag(text: "已转写", color: .e1Green)
        case .job(.transcribing): StatusTag(text: "转写中", color: .e1Blue)
        case .job(.queued): StatusTag(text: "排队中", color: .secondary)
        case .job(.failed): StatusTag(text: "转写失败", color: .e1Red)
        case .importing: HStack(spacing: 5) { ProgressView().controlSize(.small); Text("拷贝中").font(.e1Sub).foregroundStyle(Color.t2) }
        case .waiting: StatusTag(text: "待转写", color: .orange)
        case .tooShort: StatusTag(text: "太短", color: .secondary)
        case .notTaken:
            Button("转写") { pipeline.transcribeC1(r) }
                .help("第一次插上时就在笔里的，或关了自动转写时录的，点按转写这一条")
        case .removed:
            Button("重新转写") { pipeline.transcribeC1(r) }
                .help("这条转写过，后来从转写记录里移除了")
        }
    }
}
