import AppKit
import SwiftUI

/// Menu bar panel (控制中心式). Width 300; layout and states follow 菜单栏面板 + 控件状态复查表.
struct MenuPanel: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @ObservedObject private var recorder = MacRecorder.shared
    @Environment(\.openWindow) private var openWindow
    /// The device row opened to show its details and actions (one at a time, like Control Center).
    @State private var expanded: DeviceKind? = UIPreview.enabled ? DeviceKind(rawValue: UserDefaults.standard.string(forKey: "previewExpand") ?? "") : nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UpdateBanner()
            VStack(spacing: 0) {
                ForEach(pipeline.panelDevices) { PanelDeviceRow(kind: $0, expanded: $expanded) }
            }
            .padding(.horizontal, 8)

            HStack(spacing: 0) {
                Button { Task { await pipeline.syncNow() } } label: { syncLabel }
                    .buttonStyle(BigRoundStyle(active: syncActive))
                    .disabled(!pipeline.canSyncNow || syncActive)
                    .frame(maxWidth: .infinity)
                Button(action: importAudio) {
                    BigLabel(symbol: "square.and.arrow.up.fill", title: "上传音频", sub: "本机文件")
                }
                .buttonStyle(BigRoundStyle(active: false))
                .frame(maxWidth: .infinity)
                Button { Task { await recorder.toggle() } } label: {
                    if recorder.isRecording {
                        BigLabel(symbol: "stop.fill", title: "停止录音", sub: recorder.elapsedText, monoSub: true)
                    } else if let n = recorder.note {
                        BigLabel(symbol: "mic.fill", title: "开始录音", sub: n, subColor: recorder.noteIsError ? .e1Red : nil)
                    } else if !recorder.hasMicrophone {
                        BigLabel(symbol: "mic.slash.fill", title: "开始录音", sub: "未接麦克风")
                    } else {
                        BigLabel(symbol: "mic.fill", title: "开始录音", sub: recorder.micName.isEmpty ? "Mac 麦克风" : recorder.micName)
                    }
                }
                .buttonStyle(BigRoundStyle(active: recorder.isRecording, activeColor: .e1Red, level: recorder.isRecording ? CGFloat(recorder.level) : 0))
                .frame(maxWidth: .infinity)
                .help(recorder.isRecording ? "停止并转写" : recorder.hasMicrophone ? "用「\(recorder.micName)」录音，停止后自动转写成纪要" : "没有检测到麦克风，点按查看可以接什么")
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)

            PanelSeparator()
            HStack {
                Text("最近转写").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.t2)
                Spacer()
                if !settings.isConfigured {
                    Button("未设置转写平台 ›") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "welcome"); MenuPanelWindow.close() }.buttonStyle(.e1Link)
                } else {
                    CloudStatusButton()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)

            let recent = pipeline.recentJobs
            if recent.isEmpty {
                VStack(spacing: 2) {
                    Text("还没有转写记录").font(.e1Body).foregroundStyle(Color.t2)
                    Text("设备里的新录音、上传的音频转写后显示在这里").font(.e1Sub).foregroundStyle(Color.t2)
                }
                .frame(maxWidth: .infinity).frame(height: 58)
            } else {
                ForEach(recent) { JobRow(job: $0) }
            }

            PanelSeparator()
            FoldersMenuItem()
            PanelMenuItem(title: "偏好…", shortcut: "⌘ ,", action: showSettings).keyboardShortcut(",", modifiers: .command)
            PanelSeparator()
            PanelMenuItem(title: "退出", shortcut: "⌘ Q") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 10).padding(.bottom, 8)
        .frame(width: 300)
        .background(PanelWindowReader())
        .task {
            // Opening the panel refreshes: WiFi mailbox and pen heartbeat, then the cloud connection.
            await pipeline.syncWifi(force: true)
            await pipeline.checkCloud()
        }
        .onAppear {
            // UI preview: open the preferences next to the panel so both can be checked
            if UIPreview.enabled && !UIPreview.panelOnly && !UIPreview.openedSettings {
                UIPreview.openedSettings = true
                switch UserDefaults.standard.string(forKey: "previewSection") {
                case "welcome": openWindow(id: "welcome")
                case "speakers": if let j = pipeline.jobs.first(where: { pipeline.canNameSpeakers($0) }) { openWindow(id: "speakers", value: j.id) }
                default: openWindow(id: "settings")
                }
            }
        }
    }

    /// Background checks (every minute) stay quiet; the button only spins for a manual sync or real copying.
    private var syncActive: Bool { pipeline.manualSync || pipeline.isCopying }

    @ViewBuilder private var syncLabel: some View {
        if syncActive {
            BigLabel(symbol: "arrow.triangle.2.circlepath", title: "同步中…",
                     sub: pipeline.isCopying
                        ? (pipeline.copySource == "WiFi" ? "云端取回 " : "USB 拷贝 ") + "\(min(pipeline.copyDone + 1, pipeline.copyTotal)) / \(pipeline.copyTotal)"
                        : (pipeline.syncPhase ?? "检查设备") + "…",
                     spinning: true)
        } else if let r = pipeline.syncResult {
            BigLabel(symbol: "checkmark", title: "同步完成", sub: r)
        } else if !pipeline.canSyncNow {
            BigLabel(symbol: "arrow.triangle.2.circlepath", title: "立即同步", sub: "未连接设备")
        } else {
            BigLabel(symbol: "arrow.triangle.2.circlepath", title: "立即同步",
                     sub: pipeline.lastAnySync.map { "上次 " + DateFormatter.cached("HH:mm").string(from: $0) } ?? "尚未同步")
        }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings"); MenuPanelWindow.close()
    }

    /// Import, then show Preferences › 转写, where upload and transcription progress are visible.
    private func importAudio() {
        guard let urls = AudioImport.choose() else { return }
        Task { await pipeline.importFiles(urls) }
        SettingsNav.shared.request = .platform
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings"); MenuPanelWindow.close()
    }
}

/// 菜单栏面板自己的窗口。从面板里打开偏好、欢迎页等窗口后要把面板收起来：MenuBarExtra 的窗口
/// 不会因为别的窗口打开就自动关（2026-11-18 用户报：点「偏好…」后面板一直开着，1.4 就有）。
@MainActor
enum MenuPanelWindow {
    static weak var window: NSWindow?
    /// 收起面板。打开的窗口激活时系统有时会把面板又显示回来，所以过一会儿再收一次。
    /// 认窗口：记下的那个，没记到就按菜单栏面板窗口的类名找。
    static func close() {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { hide() }
    }
    private static func hide() {
        let panels = NSApp.windows.filter { $0 === window || String(describing: type(of: $0)).contains("MenuBarExtra") }
        for w in panels where w.isVisible { w.close() }
    }
}

private struct PanelWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { MenuPanelWindow.window = v.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { MenuPanelWindow.window = w }
    }
}

struct PanelSeparator: View {
    var body: some View { Rectangle().fill(Color.e1Sep).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 6) }
}

// MARK: devices

/// One device in the panel: icon, name, compact status. Clicking opens it in place (details, 立即同步, 设置…),
/// the way Control Center opens a module.
struct PanelDeviceRow: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow
    let kind: DeviceKind
    @Binding var expanded: DeviceKind?
    @State private var hover = false

    var body: some View {
        let st = pipeline.deviceStatus(kind)
        let open = expanded == kind
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PanelDeviceGlyph(kind: kind, active: st.active)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.name).font(.e1Body).foregroundStyle(Color.t1)
                    if kind == .e1 {
                        PenStatusLine(compact: true)
                    } else {
                        Text(st.shortText)
                            .font(.e1Sub).foregroundStyle(st.level == .problem ? Color.e1Red : Color.t2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.t3)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, 6).frame(height: 42)
            .background(hover || open ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : kind } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(open ? "收起" : "展开详细状态")

            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(st.details.isEmpty ? [st.line] : st.details, id: \.self) {
                        Text($0).font(.e1Sub).foregroundStyle(Color.t2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        if pipeline.isEnabled(kind) {
                            Button(kind.syncVerb) { Task { await pipeline.syncDevice(kind) } }
                                .buttonStyle(PillButtonStyle(height: 22)).font(.e1Sub)
                                .disabled(!pipeline.canSync(kind) || pipeline.manualSync)
                        }
                        Button("设置…") {
                            SettingsNav.openDevice(kind)
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "settings"); MenuPanelWindow.close()
                        }
                        .buttonStyle(PillButtonStyle(height: 22)).font(.e1Sub)
                    }
                    .padding(.top, 5)
                }
                .padding(.leading, 42).padding(.trailing, 8).padding(.top, 4).padding(.bottom, 10)
            }
        }
    }
}

/// The transcription service, next to 最近转写: green cloud when Aliyun answers, grey when something is wrong
/// (click to check again; still wrong opens Preferences).
struct CloudStatusButton: View {
    @EnvironmentObject var pipeline: Pipeline
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    @State private var checking = false
    var body: some View {
        Button {
            Task {
                checking = true
                await pipeline.checkCloud(force: true)
                checking = false
                if pipeline.cloudOK == false { NSApp.activate(ignoringOtherApps: true); openWindow(id: "settings"); MenuPanelWindow.close() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(settings.provider.info.name).font(.e1Sub).foregroundStyle(Color.t2)
                if checking {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 12)
                } else {
                    Image(systemName: pipeline.cloudOK == true ? "cloud.fill" : "cloud")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pipeline.cloudOK == true ? Color.e1Green : Color.t3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pipeline.cloudOK == true ? "阿里云连接正常：\(pipeline.cloudDetail)" : "阿里云连接异常：\(pipeline.cloudDetail)（点按重新检查）")
        .accessibilityLabel(pipeline.cloudOK == true ? "阿里云连接正常：\(pipeline.cloudDetail)" : "阿里云连接异常：\(pipeline.cloudDetail)（点按重新检查）")
    }
}

/// Pen status as icons: online dot · connection · battery · clock. Text only where an icon can't say it.
struct PenStatusLine: View {
    @EnvironmentObject var pipeline: Pipeline
    /// Panel: icons only (details in tooltips). Device page: icons with short labels.
    var compact = false
    var body: some View {
        let usb = pipeline.penConnected
        let wifi = pipeline.wifiOnline
        HStack(spacing: 7) {
            if usb && pipeline.isCopying && pipeline.copySource == "USB" {
                Text("正在拷贝 \(min(pipeline.copyDone + 1, pipeline.copyTotal)) / \(pipeline.copyTotal)")
                ProgressView(value: Double(pipeline.copyDone), total: Double(max(pipeline.copyTotal, 1)))
                    .progressViewStyle(.linear).controlSize(.mini).frame(width: 56).tint(Color.e1Blue)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "cable.connector")
                    if !compact { Text("USB") }
                }
                .foregroundStyle(usb ? Color.e1Green : Color.t3)
                .help(usb ? "USB 已连接" : "USB 未连接").accessibilityLabel(usb ? "USB 已连接" : "USB 未连接")

                HStack(spacing: 3) {
                    Image(systemName: "wifi")
                    if !compact { Text("WiFi") }
                }
                .foregroundStyle(wifi ? Color.e1Green : Color.t3)
                .help(wifiHelp).accessibilityLabel(wifiHelp)

                if let (b, charging) = battery {
                    HStack(spacing: 3) {
                        Image(systemName: batterySymbol(b, charging))
                        if !compact { Text("\(b)%") }
                    }
                    .foregroundStyle(!(usb || wifi) ? Color.t3 : b <= 20 && !charging ? Color.e1Red : Color.e1Green)
                    .help(charging ? "电量 \(b)%，充电中" : "电量 \(b)%").accessibilityLabel(charging ? "电量 \(b)%，充电中" : "电量 \(b)%")
                }
                if usb, !compact, let pen = pipeline.pen { clock(pen.clockStatus) }
                if !usb && !wifi { Text(offlineText).foregroundStyle(Color.t2) }
            }
        }
        .font(.e1Sub).foregroundStyle(Color.t2).lineLimit(1)
    }

    /// From USB, else the WiFi heartbeat (the last known level stays visible, greyed, while the pen is away).
    private var battery: (Int, Bool)? {
        if pipeline.penConnected, let pen = pipeline.pen, let b = pen.battery { return (b, pen.charging) }
        if pipeline.settingsWifiReady, let w = pipeline.wifiStatus { return (w.battery, w.charging) }
        return nil
    }

    private var wifiHelp: String {
        guard pipeline.settingsWifiReady else { return "WiFi 同步未设置" }
        guard let w = pipeline.wifiStatus, let d = w.seen else { return "WiFi：还没收到录音笔的心跳" }
        return w.isOnline ? "WiFi 在线：\(w.ssid) · 心跳 \(relativeTime(d))" : "WiFi 离线 · 最后在线 \(relativeTime(d))"
    }

    private var offlineText: String {
        if pipeline.settingsWifiReady, let d = pipeline.wifiStatus?.seen { return "最后在线 \(relativeTime(d))" }
        return compact ? "未连接" : "未连接 · 插上数据线即自动同步"
    }

    private func batterySymbol(_ level: Int, _ charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        return level >= 88 ? "battery.100percent" : level >= 63 ? "battery.75percent" : level >= 38 ? "battery.50percent"
            : level >= 13 ? "battery.25percent" : "battery.0percent"
    }

    @ViewBuilder private func clock(_ status: String) -> some View {
        switch status {
        case "synced", "rtc_ok": Image(systemName: "clock.badge.checkmark").help(status == "synced" ? "时间已联网校准" : "时钟正常")
        case "estimated": Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color.e1Red).help("时间为估计值，联网后自动校准")
        default: Image(systemName: "clock.badge.questionmark").help("未安装校时脚本")
        }
    }
}

// MARK: big round buttons

struct BigLabel: View {
    let symbol: String
    let title: String
    let sub: String
    var spinning = false
    var monoSub = false
    var subColor: Color? = nil
    /// The icon's colour when idle (same colours as the 转写 page's buttons).
    var tint: Color? = nil
    @Environment(\.bigRoundActive) private var active
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Color.white) : tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 1.2).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 36, height: 36)
            Text(title).font(.e1Body)
            Text(sub).font(monoSub ? .system(size: 11).monospacedDigit() : .e1Sub)
                .foregroundStyle(subColor ?? Color.primary).opacity(subColor == nil ? 0.6 : 1).lineLimit(1)
        }
    }
}

/// Circle 8% · hover 12% · pressed 18% and 94% scale · active blue with white icon · disabled 25%.
struct BigRoundStyle: ButtonStyle {
    let active: Bool
    var activeColor: Color = .e1Blue
    /// Recording level 0…1, drawn as a soft ring around the circle.
    var level: CGFloat = 0
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, active: active, activeColor: activeColor, level: level)
    }
    struct StyledBody: View {
        let configuration: Configuration
        let active: Bool
        let activeColor: Color
        let level: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let fill: Color = active ? activeColor
                : Color.primary.opacity(!enabled ? 0.05 : configuration.isPressed ? 0.18 : hover ? 0.12 : 0.08)
            configuration.label
                .foregroundStyle(active ? Color.t1 : enabled ? Color.t1 : Color.t3)
                .background(alignment: .top) {
                    ZStack {
                        if level > 0 {
                            Circle().fill(activeColor.opacity(0.22)).frame(width: 36 + 10 * level, height: 36 + 10 * level)
                                .animation(.easeOut(duration: 0.2), value: level)
                        }
                        Circle().fill(fill).frame(width: 36, height: 36)
                            .scaleEffect(configuration.isPressed && !active ? 0.94 : 1)
                    }
                    .frame(width: 36, height: 36)
                }
                .environment(\.bigRoundActive, active)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

private struct BigRoundActiveKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var bigRoundActive: Bool {
        get { self[BigRoundActiveKey.self] }
        set { self[BigRoundActiveKey.self] = newValue }
    }
}

// MARK: recent jobs

struct JobRow: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow
    let job: Job
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(pipeline.displayName(job)).font(.e1Body).foregroundStyle(Color.t1).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            switch job.state {
            case .done: pipeline.openNote(job)
            case .failed: pipeline.explainFailure(job)
            default: break
            }
        }
        .contextMenu { JobMenu(job: job) }
        .help(job.error ?? helpText)
    }

    /// "17:12", "昨天 17:12" or "11月10日" — the name carries only the date, so the time sits on the right.
    private var timeText: String {
        let cal = Calendar.current
        return cal.isDateInToday(job.created) ? DateFormatter.cached("HH:mm").string(from: job.created)
            : cal.isDateInYesterday(job.created) ? "昨天 " + DateFormatter.cached("HH:mm").string(from: job.created)
            : DateFormatter.cached("M月d日").string(from: job.created)
    }

    private var whenText: some View {
        Text(timeText).fixedSize().font(.e1Sub).foregroundStyle(Color.t2)
    }

    private var helpText: String {
        var parts = [pipeline.displayName(job)]
        if job.topic != nil { parts.append("录音名：\(job.title)") }
        parts.append(DateFormatter.cached("M月d日 HH:mm").string(from: job.created) + " · " + MarkdownRenderer.duration(job.durationSec))
        if let p = pipeline.place(of: job) { parts.append("地点：\(p)") }
        if pipeline.noteMissing(job) { parts.append("本地纪要已删除或移出笔记库；右键可重新生成") }
        parts.append("来源：\(job.source)")
        return parts.joined(separator: "\n")
    }

    @ViewBuilder private var icon: some View {
        let (symbol, failed): (String, Bool) = switch job.state {
        case .done: (job.sourceSymbol, false)
        case .queued: ("clock", false)
        case .transcribing: ("ellipsis", false)
        case .failed: ("exclamationmark", true)
        }
        ZStack {
            Circle().fill(failed ? Color.e1Red.opacity(0.14) : Color.primary.opacity(0.08))
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(failed ? Color.e1Red : pipeline.noteMissing(job) ? Color.t3 : Color.t1)
        }
        .frame(width: 22, height: 22)
    }

    @ViewBuilder private var trailing: some View {
        if hover {
            switch job.state {
            case .done:
                if pipeline.canOpenNote(job) {
                    IconButton(symbol: "doc.text", help: "打开会议纪要") { pipeline.openNote(job) }
                } else {
                    whenText
                }
            case .queued: Text("排队中").font(.e1Sub).foregroundStyle(Color.t2)
            case .transcribing: HStack(spacing: 5) { Spinner(); Text("转写中").font(.e1Sub).foregroundStyle(Color.t2) }
            case .failed:
                Button("重试") { pipeline.retry(job) }
                    .buttonStyle(PillButtonStyle(height: 20)).font(.e1Sub)
            }
        } else {
            switch job.state {
            case .done: whenText
            case .queued: Text("排队中").font(.e1Sub).foregroundStyle(Color.t2)
            case .transcribing: HStack(spacing: 5) { Spinner(); Text("转写中").font(.e1Sub).foregroundStyle(Color.t2) }
            case .failed: Text("失败").font(.e1Sub).foregroundStyle(Color.e1Red)
            }
        }
    }

    /// The denoised mp3 copied from the pen if present, else the original recording.
    private var audioFile: String? {
        [job.listenPath, job.audioPath].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

}

/// 20pt icon button: icon 60% · pressed background 10% and icon 85%.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            .buttonStyle(IconButtonStyle()).help(help).accessibilityLabel(help)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.85 : 0.6))
            .frame(width: 20, height: 20)
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
    }
}

// MARK: menu items

/// Panel menu item: hover grey 8% (as in Control Center) · pressed 14% · disabled 25% text.
struct PanelMenuItem: View {
    let title: String
    var shortcut: String? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(Color.t2) }
            }
        }
        .buttonStyle(MenuItemStyle())
        .disabled(!enabled)
    }
}

/// One row for both folders; the chevron opens a small menu to pick 全部纪要 or 录音文件.
/// 全部纪要: straight to the folder where transcribed recordings end up as notes.
struct FoldersMenuItem: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        PanelMenuItem(title: "全部纪要") { reveal(settings.notesFolder) }
    }
}

/// Opens a folder in Finder, creating it first if nothing has been synced there yet.
@MainActor func reveal(_ folder: String) {
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    open(folder)
}

struct MenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.e1Body).foregroundStyle(enabled ? Color.t1 : Color.t3)
                .padding(.horizontal, 9).frame(height: 24)
                .background(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.14 : hover ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Right-click menu for a transcription, the same in the menu bar panel and in Preferences › 转写.
struct JobMenu: View {
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow
    let job: Job

    private var audioFile: String? {
        [job.listenPath, job.audioPath].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    var body: some View {
        if pipeline.canOpenNote(job) { Button("打开纪要") { pipeline.openNote(job) } }
        if pipeline.noteMissing(job), pipeline.inCloud(job) { Button("重新生成本地纪要") { pipeline.regenerateNote(job) } }
        if let a = audioFile {
            Button("播放录音") { open(a) }
            Button("在访达中显示录音") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a)]) }
        }
        if pipeline.canNameSpeakers(job) {
            Button("为发言人命名…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "speakers", value: job.id); MenuPanelWindow.close() }
        }
        if job.state == .done { Button("用当前模板重新生成") { pipeline.rerender(job) } }
        if job.state == .failed { Button("重试") { pipeline.retry(job) } }
        Divider()
        Button("从列表移除") { pipeline.remove(job) }
    }
}
