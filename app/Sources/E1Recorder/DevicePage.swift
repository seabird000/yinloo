import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Preferences › 设备: every device in one list (its state at a glance), rules that apply to all of them,
/// and a page per device behind each row.
struct DevicePage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.openSubpage) private var openSubpage

    var body: some View {
        Form {
            Section {
                ForEach(DeviceKind.allCases) { d in
                    DeviceListRow(kind: d) { openSubpage(d.subpage) }
                }
            } header: {
                SectionTitle("我的设备", info: "录音从这些设备来。点一台设备进去看它的详细状态和设置。")
            }

            Section {
                Picker("最短时长", selection: $s.minDurationSec) {
                    ForEach([0, 5, 10, 30, 60], id: \.self) { Text($0 == 0 ? "不限" : "\($0) 秒").tag($0) }
                }
            } header: {
                SectionTitle("所有设备", info: "比这更短的录音不转写，误触、试录不会扣费。对每台设备都生效。")
            }
        }
    }
}

/// One device in the list: icon, name, a status line, a tag, and the way into its page.
struct DeviceListRow: View {
    @EnvironmentObject var pipeline: Pipeline
    let kind: DeviceKind
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        let st = pipeline.deviceStatus(kind)
        Button(action: open) {
            HStack(spacing: 12) {
                DeviceIcon(kind: kind, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name).foregroundStyle(Color.t1)
                    Text(st.line).font(.e1Sub).foregroundStyle(st.level == .problem ? Color.e1Red : Color.t2).lineLimit(1)
                }
                Spacer(minLength: 8)
                StatusTag(text: st.tag, color: st.level.color)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.name)，\(st.tag)，\(st.line)")
    }
}

/// The top card of a device's page: icon, name, live status, and its 立即同步.
struct DeviceHeader<Status: View>: View {
    @EnvironmentObject var pipeline: Pipeline
    let kind: DeviceKind
    @ViewBuilder let status: () -> Status

    var body: some View {
        Section {
            HStack(spacing: 12) {
                DeviceIcon(kind: kind, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name)
                    HStack(spacing: 6) {
                        status()
                        if pipeline.manualSync {
                            Text("· " + (pipeline.syncPhase ?? "同步中") + "…").font(.e1Sub).foregroundStyle(Color.t2)
                        } else if let r = pipeline.syncResult {
                            Text("· 完成，\(r)").font(.e1Sub).foregroundStyle(Color.e1Green)
                        }
                    }
                }
                Spacer()
                Button { Task { await pipeline.syncDevice(kind) } } label: {
                    if pipeline.manualSync || (kind == .e1 && pipeline.isCopying) {
                        HStack(spacing: 5) { ProgressView().controlSize(.small); Text((pipeline.syncPhase ?? "同步中") + "…") }
                    } else { Text(kind.syncVerb) }
                }
                .disabled(!pipeline.canSync(kind) || pipeline.manualSync || pipeline.isCopying || (kind == .voiceMemos && !pipeline.settings.voiceMemos))
            }
            .padding(.vertical, 4)
        }
    }
}

/// Preferences › 设备 › 搜狗 E1 录音笔.
struct E1DevicePage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @State private var showGuide = false

    var body: some View {
        let pen = pipeline.penConnected ? pipeline.pen : nil
        Form {
            DeviceHeader(kind: .e1) {
                PenStatusLine()
                if !pipeline.manualSync, pipeline.syncResult == nil, !pipeline.isCopying, let t = pipeline.lastSync {
                    Text("· 上次同步 " + DateFormatter.cached("HH:mm").string(from: t)).font(.e1Sub).foregroundStyle(Color.t2)
                }
            }

            Section {
                let snap = pipeline.penSnapshot
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    InfoTile(icon: AnyView(BatteryIcon(level: snap?.battery)), value: snap?.battery.map { "\($0)%" } ?? "—",
                             label: "剩余电量" + ((snap?.charging ?? false) ? " · 充电中" : ""))
                    InfoTile(symbol: "internaldrive", value: snap?.freeBytes.map(formatBytes) ?? "—", label: "可用空间")
                    InfoTile(symbol: "clock", value: snap.map { clockText($0.clockStatus) } ?? "—", label: "时间状态 · 联网对时")
                    InfoTile(symbol: "waveform", value: snap?.recordingCount.map { "\($0) 条" } ?? "—", label: "笔内录音")
                    InfoTile(symbol: "number", value: snap?.sn.map { "…" + $0.suffix(6) } ?? "—", label: "序列号码")
                    InfoTile(symbol: "cpu", value: snap?.firmware.flatMap { $0.isEmpty ? nil : $0 } ?? "—", label: "固件版本")
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("设备信息")
                    Spacer()
                    if let src = pipeline.penSnapshot?.source {
                        Text("来自 " + src).font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent {
                    pen != nil ? StatusTag(text: "已连接", color: .e1Green) : StatusTag(text: "未连接", color: .secondary)
                } label: {
                    Text("USB 有线")
                }
                LabeledContent {
                    wifiTag
                } label: {
                    Text("WiFi 无线"); Text(wifiSubtitle)
                }
            } header: {
                SectionTitle("连接方式", info: "两种方式可以同时用：插着数据线走 USB；拔掉后录音笔连上 WiFi 自动上传，这台 Mac 开着时取回并转写。")
            }

            WifiSyncSection(showGuide: $showGuide)

            Section {
                Toggle("自动同步", isOn: $s.autoSync).toggleStyle(.switch)
                Picker(selection: $s.wifiIntervalMin) {
                    ForEach([1, 5, 15, 30], id: \.self) { Text("每 \($0) 分钟").tag($0) }
                } label: {
                    Text("WiFi 检查")
                }
            } header: {
                SectionTitle("同步", info: "自动同步：插上数据线就拷新录音。WiFi 检查：这台 Mac 多久去云存储取一次录音笔传上来的录音。")
            }

            PenComponentsSection(onSetUpWifi: { showGuide = true })

            PenRecordingsSection()

            PlacesSection()

            DeadFeaturesSection()
        }
    }

    @ViewBuilder private var wifiTag: some View {
        if !s.wifiReady { StatusTag(text: "未设置", color: .secondary) }
        else if pipeline.wifiError != nil { StatusTag(text: "出错", color: .e1Red) }
        else if pipeline.wifiOnline { StatusTag(text: "在线", color: .e1Green) }
        else if pipeline.wifiStatus != nil { StatusTag(text: "离线", color: .secondary) }
        else { StatusTag(text: "等待心跳", color: .orange) }
    }

    private var wifiSubtitle: String {
        if !s.wifiReady { return "录音笔连上 WiFi 自动上传，需要先在下面设置" }
        if let e = pipeline.wifiError { return e }
        let checked = pipeline.lastWifiCheck.map { " · 上次检查 " + DateFormatter.cached("HH:mm").string(from: $0) } ?? ""
        guard let w = pipeline.wifiStatus, let d = w.seen else { return "还没收到录音笔的心跳" + checked }
        return (w.isOnline ? "在线 · \(w.ssid.isEmpty ? "WiFi" : w.ssid) · 心跳 \(relativeTime(d))" : "最后在线 \(relativeTime(d))") + checked
    }

    private func clockText(_ status: String) -> String {
        ["synced": "已校准", "rtc_ok": "时钟正常", "estimated": "估计时间"][status] ?? "未安装"
    }
}

/// The pen's WiFi mailbox (an Aliyun OSS bucket and two keys). Only the pen's WiFi sync uses it, so it lives on
/// the pen's page.
struct WifiSyncSection: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @Binding var showGuide: Bool
    enum Edit: String, Identifiable { case bucket, ossEndpoint; var id: String { rawValue } }
    @State private var editing: Edit?
    @State private var editingPenKey = false
    @State private var editingMacKey = false
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        Section {
            LabeledContent("存储空间") {
                HStack { Trailing(text: s.ossBucket.isEmpty ? "未填写" : s.ossBucket); Button("编辑…") { editing = .bucket } }
            }
            LabeledContent("地域节点") {
                HStack { Trailing(text: s.ossEndpoint.isEmpty ? "未填写" : s.ossEndpoint); Button("编辑…") { editing = .ossEndpoint } }
            }
            LabeledContent("录音笔用钥匙") {
                HStack { Trailing(text: s.penKeyStored ? "已存入钥匙串" : "未填写"); Button(s.penKeyStored ? "修改…" : "填写…") { editingPenKey = true } }
            }
            LabeledContent("Mac 用钥匙") {
                HStack { Trailing(text: s.macKeyStored ? "已存入钥匙串" : "未填写"); Button(s.macKeyStored ? "修改…" : "填写…") { editingMacKey = true } }
            }
            LabeledContent("连接测试") {
                HStack(spacing: 8) {
                    if testing { ProgressView().controlSize(.small) }
                    else if let r = result {
                        if r.isEmpty { HStack(spacing: 6) { Dot(kind: .ok); Text("两把钥匙都正常") } }
                        else { HStack(spacing: 6) { Dot(kind: .bad); Text(r).lineLimit(1).frame(maxWidth: 200, alignment: .trailing) } }
                    }
                    Button("测试") {
                        Task {
                            testing = true
                            result = UIPreview.enabled ? "" : (await pipeline.testWifi() ?? "")
                            if result == "" { s.wifiEnabled = true }
                            testing = false
                        }
                    }
                    .disabled(testing || s.ossBucket.isEmpty || !s.penKeyStored || !s.macKeyStored)
                }
            }
            Toggle("启用 WiFi 同步", isOn: $s.wifiEnabled).toggleStyle(.switch)
        } header: {
            HStack {
                SectionTitle("WiFi 同步", info: "用你阿里云账号里的一个存储空间当信箱：录音笔连上 WiFi 后把新录音传上去，这台 Mac 取回、转写后清空。录音笔的钥匙只能上传，Mac 的钥匙只能读取和删除。")
                Spacer()
                Button("设置步骤…") { showGuide = true }.buttonStyle(.link).font(.callout)
            }
        }
        .sheet(item: $editing) { e in
            switch e {
            case .bucket:
                EditSheet(title: "存储空间名称", help: "阿里云 OSS 里为 WiFi 同步建的存储空间（Bucket）名称。", placeholder: "存储空间名称",
                          initial: s.ossBucket, validate: { $0.range(of: "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", options: .regularExpression) != nil ? nil : "只能用小写字母、数字和短横线，3–63 个字符" },
                          save: { s.ossBucket = $0 })
            case .ossEndpoint:
                EditSheet(title: "地域节点", help: "存储空间所在地域的访问域名，例如 oss-cn-beijing.aliyuncs.com。", placeholder: "oss-cn-beijing.aliyuncs.com",
                          initial: s.ossEndpoint, validate: { $0.hasSuffix(".aliyuncs.com") && !$0.contains("/") ? nil : "应形如 oss-cn-beijing.aliyuncs.com" },
                          save: { s.ossEndpoint = $0 })
            }
        }
        .sheet(isPresented: $editingPenKey) { KeyPairSheet(pen: true) }
        .sheet(isPresented: $editingMacKey) { KeyPairSheet(pen: false) }
        .sheet(isPresented: $showGuide) {
            VStack(spacing: 0) {
                WifiGuideView()
                HStack { Spacer(); Button("完成") { showGuide = false }.keyboardShortcut(.defaultAction) }.padding(16)
            }
            .frame(width: 600, height: 720)
        }
    }
}
