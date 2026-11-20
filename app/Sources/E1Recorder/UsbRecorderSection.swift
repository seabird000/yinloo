import AppKit
import SwiftUI

/// Preferences › 设备 › U 盘录音笔：添加过的录音笔、插着那台的录音。
struct UsbRecorderDevicePage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @State private var adding = false
    @State private var renaming: UsbRecorder.Entry?
    @State private var describing: UsbRecorder.Entry?
    @State private var removing: UsbRecorder.Entry?

    var body: some View {
        let entries = pipeline.usbEntries
        Form {
            DeviceHeader(kind: .usbDisk) {
                let st = pipeline.deviceStatus(.usbDisk)
                if !pipeline.manualSync, pipeline.syncResult == nil {
                    Text(st.shortText).font(.e1Sub).foregroundStyle(st.level == .problem ? Color.e1Red : Color.t2).lineLimit(1)
                }
            }

            Section {
                if entries.isEmpty {
                    Text("还没有添加。用数据线把录音笔连到这台 Mac，等它在访达里出现，再点右上角「添加…」。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(entries) { e in entryRow(e) }
            } header: {
                HStack {
                    SectionTitle("我的录音笔", info: "插上 USB 就出现一个盘的录音笔都可以接。添加一次，以后插上就自动以只读方式挂载、拷新录音、按「服务选项」转写。只读取，不改动、不删除笔上的文件。\n\n添加时笔里已有的录音不自动转写，要的话在下面点「转写」。\n\n我们适配过的型号插上会自动认出，不用添加。")
                    Spacer()
                    Button("添加…") { adding = true }.font(.callout)
                }
            }

            ForEach(entries.filter { pipeline.usbDisk(for: $0) != nil }) { e in
                UsbRecordingsSection(entry: e)
            }

            if entries.contains(where: { $0.profileId == nil }) {
                Section {
                    Text("录音笔用的是通用方式：在整个盘里找录音，时间按文件名或文件的修改时间算。时间不对、找漏了，可以在那支笔的「…」里点「生成设备描述」发给我们，我们给它做专门的适配，以后插上自动认出。")
                        .font(.e1Sub).foregroundStyle(Color.t2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $adding) { UsbAddSheet() }
        .sheet(item: $renaming) { e in
            EditSheet(title: "录音笔名字", help: "显示在设备列表和纪要来源里，也用作录音文件夹的名字。", placeholder: "录音笔名字",
                      initial: e.name, validate: { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "名字不能为空" : nil },
                      save: { pipeline.renameUsbRecorder(e.id, to: $0) })
        }
        .sheet(item: $describing) { e in UsbDescribeSheet(entry: e) }
        .confirmationDialog("移除「\(removing?.name ?? "")」？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) { if let e = removing { pipeline.removeUsbRecorder(e.id) }; removing = nil }
        } message: {
            Text("只是让音录忘掉这支笔：已经拷来的录音和纪要都留着，笔上的文件也不动。再插上要重新添加。")
        }
    }

    @ViewBuilder private func entryRow(_ e: UsbRecorder.Entry) -> some View {
        let disk = pipeline.usbDisk(for: e)
        LabeledContent {
            HStack(spacing: 8) {
                Toggle("自动转写", isOn: Binding(get: { e.auto }, set: { pipeline.setUsbAuto(e.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .help("插上后自动拷新录音，按「服务选项」转写")
                tag(disk)
                Menu {
                    Button("改名…") { renaming = e }
                    Button("生成设备描述…") { describing = e }.disabled(disk?.ready != true)
                    if let d = disk, d.path != nil { Button("推出") { UsbDisk.shared.eject(d.bsd) } }
                    Divider()
                    Button("移除…", role: .destructive) { removing = e }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        } label: {
            Text(e.name)
            Text(detail(e, disk))
        }
    }

    @ViewBuilder private func tag(_ d: UsbDiskInfo?) -> some View {
        if let d {
            if d.problem != nil { StatusTag(text: "出错", color: .e1Red) }
            else if d.ready { StatusTag(text: "已连接", color: .e1Green) }
            else { StatusTag(text: "连接中", color: .orange) }
        } else {
            StatusTag(text: "未连接", color: .secondary)
        }
    }

    private func detail(_ e: UsbRecorder.Entry, _ d: UsbDiskInfo?) -> String {
        let origin = e.profileId != nil && pipeline.profileLib.profile(e.profileId) != nil ? "已认出型号" : "通用方式"
        guard let d else { return origin + " · " + (e.auto ? "插上自动转写" : "自动转写已关") }
        if let p = d.problem { return p }
        if !d.ready { return "正在以只读方式挂载…" }
        let free = d.path.flatMap { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity }
        return (["只读", origin] + [free.map { "可用 " + formatBytes(Int64($0)) }].compactMap { $0 }).joined(separator: " · ")
    }
}

/// 插着那支录音笔里的录音，新的在前，每条的状态；添加时就在笔里的可以逐条转写。
struct UsbRecordingsSection: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    let entry: UsbRecorder.Entry
    @State private var showAll = false

    var body: some View {
        let recs = pipeline.usb.lists[entry.id] ?? []
        let done = recs.filter { pipeline.usbState($0, entry: entry) == .job(.done) }.count
        let off = recs.filter { pipeline.usbTimeOff($0, entry: entry.id) }.count
        Section {
            if recs.isEmpty {
                Text(pipeline.usb.syncing.contains(entry.id) ? "正在读取…" : "笔里没有找到录音").foregroundStyle(.secondary)
            }
            if off > 0 {
                Label {
                    Text("有 \(off) 条录音的时间不准（笔的时钟可能没设好或断电后停了）。请在笔的设置里重设时间；这几条按拷到 Mac 的时间记。")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                .font(.e1Sub).foregroundStyle(Color.t2)
            }
            ForEach(showAll ? recs : Array(recs.prefix(8)), id: \.key) { r in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(r)).lineLimit(1)
                        Text(([r.durationSec > 0 ? MarkdownRenderer.duration(r.durationSec) : nil, formatBytes(r.size), r.ext.uppercased()]
                            .compactMap { $0 }).joined(separator: " · "))
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
                SectionTitle("\(entry.name)里的录音", info: "「待转写」的会自动转写；点「转写」只转这一条。wma、opus 等格式暂时转不了。")
                Spacer()
                if !recs.isEmpty {
                    Text("\(recs.count) 条 · 已转写 \(done) 条").font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func title(_ r: UsbRecorder.Recording) -> String {
        if pipeline.usbTimeOff(r, entry: entry.id) { return r.category + "（时间不准）" }
        return r.category + " " + DateFormatter.cached("M月d日 HH:mm").string(from: r.created ?? r.modified)
    }

    @ViewBuilder private func state(_ r: UsbRecorder.Recording) -> some View {
        switch pipeline.usbState(r, entry: entry) {
        case .job(.done): StatusTag(text: "已转写", color: .e1Green)
        case .job(.transcribing): StatusTag(text: "转写中", color: .e1Blue)
        case .job(.queued): StatusTag(text: "排队中", color: .secondary)
        case .job(.failed): StatusTag(text: "转写失败", color: .e1Red)
        case .importing: HStack(spacing: 5) { ProgressView().controlSize(.small); Text("拷贝中").font(.e1Sub).foregroundStyle(Color.t2) }
        case .unsupported: StatusTag(text: "格式暂不支持", color: .secondary)
        case .recording: StatusTag(text: "刚写入", color: .secondary)
        case .waiting: StatusTag(text: "待转写", color: .orange)
        case .tooShort: StatusTag(text: "太短", color: .secondary)
        case .notTaken:
            Button("转写") { pipeline.transcribeUsb(r, entry: entry) }
                .help("添加时就在笔里的，或关了自动转写时录的，点按转写这一条")
        case .removed:
            Button("重新转写") { pipeline.transcribeUsb(r, entry: entry) }
                .help("这条转写过，后来从转写记录里移除了")
        }
    }
}

/// 「添加…」：列出插着、还没添加的 USB 盘，看一眼里面有几条录音，选一个、起个名字。
struct UsbAddSheet: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    @State private var picked: String?
    @State private var name = ""
    @State private var counts: [String: Int] = [:]

    var body: some View {
        let disks = pipeline.usbAddable
        VStack(alignment: .leading, spacing: 14) {
            Text("添加 U 盘录音笔").font(.headline)
            Text("用数据线把录音笔连到这台 Mac，它在访达里出现后会列在下面。添加后音录会把它改成只读挂载（访达里会消失一下再出现），以后插上自动同步。")
                .font(.e1Sub).foregroundStyle(Color.t2).fixedSize(horizontal: false, vertical: true)
            if disks.isEmpty {
                Text("现在没有插着的 USB 盘。").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                List(disks, selection: $picked) { d in
                    HStack {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.label)
                            Text(sub(d)).font(.e1Sub).foregroundStyle(Color.t2)
                        }
                    }
                    .tag(d.bsd)
                }
                .frame(minHeight: 120)
                .onChange(of: picked) { _, id in
                    guard let d = disks.first(where: { $0.bsd == id }) else { return }
                    name = pipeline.profileLib.match(d.identity)?.name ?? d.identity.productName ?? d.label
                }
            }
            if picked != nil {
                LabeledContent("名字") { TextField("录音笔名字", text: $name).textFieldStyle(.roundedBorder).frame(width: 220) }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加") {
                    if let d = disks.first(where: { $0.bsd == picked }) { pipeline.addUsbRecorder(d, name: name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: disks.map(\.bsd)) { await count(disks) }
    }

    private func sub(_ d: UsbDiskInfo) -> String {
        var parts: [String] = []
        if let n = d.identity.productName, n != d.label { parts.append(n) }
        if let s = d.sizeBytes { parts.append(formatBytes(s)) }
        if d.path == nil { parts.append("没挂上") }
        else if let c = counts[d.bsd] { parts.append(c == 0 ? "没找到录音" : "约 \(c) 个录音文件") }
        else { parts.append("正在看…") }
        if pipeline.profileLib.match(d.identity) != nil { parts.append("已适配的型号") }
        return parts.joined(separator: " · ")
    }

    /// 看一眼里面有几个音频文件（只走目录，不读内容）。
    private func count(_ disks: [UsbDiskInfo]) async {
        for d in disks where counts[d.bsd] == nil {
            guard let path = d.path else { continue }
            let n = await Task.detached(priority: .utility) { UsbRecorder.scan(path, profile: nil).count }.value
            counts[d.bsd] = n
        }
    }
}

/// 「生成设备描述」：脱敏的描述先给用户看全文，用户自己拷贝、发给我们。
struct UsbDescribeSheet: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.dismiss) private var dismiss
    let entry: UsbRecorder.Entry
    @State private var text = "正在生成…"
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备描述").font(.headline)
            Text("下面是这支录音笔的描述，用来帮我们给它做专门的适配。不含序列号、卷名和录音内容；文件夹和文件名只保留「样子」（数字换成 #，中文换成 *）。看过没问题再拷贝，贴到 GitHub 的问题页发给我们。")
                .font(.e1Sub).foregroundStyle(Color.t2).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 280)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("打开 GitHub 问题页") { NSWorkspace.shared.open(AppLinks.issues) }
                Spacer()
                Button(copied ? "已拷贝" : "拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await build() }
    }

    private func build() async {
        guard let d = pipeline.usbDisk(for: entry) else { text = "录音笔没插着。"; return }
        let recs: [UsbRecorder.Recording]
        if let r = pipeline.usb.lists[entry.id] { recs = r }
        else if let p = d.path { recs = await Task.detached { await UsbRecorder.list(p, profile: nil) }.value }
        else { recs = [] }
        text = UsbRecorder.describe(identity: d.identity, fileSystem: d.fileSystem, capacityBytes: d.sizeBytes, files: recs)
    }
}
