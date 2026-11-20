import AppKit
import SwiftUI

/// The recording devices the app syncs from. The menu bar panel and Preferences › 设备 only talk to this layer
/// (name, icon, one status line, sync, settings page); each device's own sync code stays where it is.
enum DeviceKind: String, CaseIterable, Identifiable {
    case e1
    case c1Max
    case usbDisk
    case voiceMemos
    var id: String { rawValue }

    var name: String {
        switch self {
        case .e1: "搜狗 E1 录音笔"
        case .c1Max: "搜狗 C1 Max"
        case .usbDisk: "U 盘录音笔"
        case .voiceMemos: "语音备忘录"
        }
    }
    /// Preferences sub-page with this device's settings.
    var subpage: String { "device-" + rawValue }
    var glyph: SidebarIcon.Glyph {
        switch self {
        case .e1: .device
        case .c1Max: .c1Max
        case .usbDisk: .usbDisk
        case .voiceMemos: .voiceMemos
        }
    }
    /// Folder (inside the audio folder) that this device's new recordings are copied into, by month.
    var folderName: String {
        switch self {
        case .e1: "搜狗E1"
        case .c1Max: "搜狗C1Max"
        case .usbDisk: "U盘录音笔"   // 实际按每支笔的名字分文件夹
        case .voiceMemos: "语音备忘录"
        }
    }
    var syncVerb: String { self == .voiceMemos ? "立即检查" : "立即同步" }
}

/// Where a device stands, in the words every list uses.
struct DeviceStatus: Equatable {
    enum Level { case ok, idle, waiting, problem }
    var tag: String           // 已连接 · 在线 · 离线 · 未连接 · 已开启 · 未开启 · 需要授权 …
    var level: Level
    var line: String          // one line for lists
    var details: [String]     // a few short lines for the panel's expanded row
    var short = ""            // the panel row's own line, when it differs from the tag
    var shortText: String { short.isEmpty ? tag : short }
    /// Connected, online or switched on: the icon is drawn in colour.
    var active: Bool { level == .ok }
}

extension DeviceStatus.Level {
    var color: Color {
        switch self {
        case .ok: .e1Green
        case .idle: .secondary
        case .waiting: .orange
        case .problem: .e1Red
        }
    }
}

extension Pipeline {
    /// Devices in the menu bar panel: the E1 always, C1 Max once it has been plugged in, U 盘录音笔 once one is added or recognised, Voice Memos once switched on.
    var panelDevices: [DeviceKind] {
        DeviceKind.allCases.filter {
            switch $0 {
            case .e1: true
            case .c1Max: c1EverSeen || c1.phase != .absent
            case .usbDisk: !usbEntries.isEmpty || usb.disks.contains(where: \.guarded)
            case .voiceMemos: settings.voiceMemos
            }
        }
    }

    func isEnabled(_ d: DeviceKind) -> Bool {
        switch d {
        case .e1, .c1Max, .usbDisk: true
        case .voiceMemos: settings.voiceMemos
        }
    }

    /// The latest time any device was synced or looked at (for 「立即同步 · 上次 …」).
    var lastAnySync: Date? {
        [lastSync, lastWifiCheck, c1LastSync, usb.lastSync, settings.voiceMemos ? memoScan?.at : nil].compactMap { $0 }.max()
    }

    func deviceStatus(_ d: DeviceKind) -> DeviceStatus {
        switch d {
        case .e1: e1Status
        case .c1Max: c1Status
        case .usbDisk: usbStatus
        case .voiceMemos: voiceMemoStatus
        }
    }

    /// 每台设备都用同样的两行：第一行连接状态，第二行数量和上次同步；有问题才多一行。设备列表里把两行连成一行。
    static func status(_ tag: String, _ level: DeviceStatus.Level, _ first: String, _ second: String? = nil,
                       warning: String? = nil, short: String = "") -> DeviceStatus {
        let lines = [first, second, warning].compactMap { $0?.isEmpty == false ? $0 : nil }
        return DeviceStatus(tag: tag, level: level, line: lines.prefix(2).joined(separator: " · "), details: lines, short: short)
    }

    /// 「笔内 4 条 · 上次同步 12:58」
    static func countAndSync(_ count: Int?, _ last: Date?, verb: String = "上次同步") -> String {
        [count.map { "笔内 \($0) 条" }, last.map { verb + " " + DateFormatter.cached("HH:mm").string(from: $0) }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var e1Status: DeviceStatus {
        let info = Self.countAndSync(penSnapshot?.recordingCount, lastSync)
        if isCopying {
            let what = (copySource == "WiFi" ? "正在取回" : "正在拷贝") + " \(min(copyDone + 1, copyTotal)) / \(copyTotal)"
            return Self.status(penConnected ? "已连接" : "在线", .ok, penConnected ? "USB 已连接" : "WiFi 在线", what)
        }
        if penConnected { return Self.status("已连接", .ok, wifiOnline ? "USB 已连接 · WiFi 在线" : "USB 已连接", info) }
        if wifiOnline { return Self.status("在线", .ok, "WiFi 在线", info) }
        if settings.wifiReady, let e = wifiError { return Self.status("出错", .problem, "WiFi 同步出错", e) }
        if settings.wifiReady, let seen = wifiStatus?.seen {
            return Self.status("离线", .idle, "WiFi 最后在线 " + relativeTime(seen), info)
        }
        return Self.status("未连接", .idle, "未连接", "插上数据线即自动同步")
    }

    private var voiceMemoStatus: DeviceStatus {
        guard settings.voiceMemos else { return Self.status("未开启", .idle, "未开启", "打开后自动转写新录音") }
        guard let scan = memoScan else { return Self.status("检查中", .waiting, "新录音自动转写", "正在查找语音备忘录…") }
        switch scan.problem {
        case .noAccess?: return Self.status("需要授权", .problem, "需要授权", "在「完全磁盘访问权限」里打开音录")
        case .notFound?: return Self.status("没有录音", .idle, "新录音自动转写", "这台 Mac 上还没有语音备忘录")
        case .audioFolder?: return Self.status("等待中", .waiting, "新录音自动转写", "录音目录用不了，接上移动硬盘后继续")
        case .failed(let why)?: return Self.status("出错", .problem, "出错", why)
        case nil:
            let info = (scan.settling > 0 ? "\(scan.settling) 条正在同步 · " : "") + Self.countAndSync(nil, scan.at, verb: "上次检查")
            return Self.status("已开启", .ok, "新录音自动转写", info)
        }
    }

    /// 立即同步 for one device (nil = every device), from the panel or a device page.
    func syncDevice(_ d: DeviceKind) async {
        await syncNow(only: d)
    }
}

/// A device's icon: the System Settings–style tile (Preferences), or a round Control Center–style button (panel).
struct DeviceIcon: View {
    let kind: DeviceKind
    var size: CGFloat = 32
    var body: some View {
        // 语音备忘录用系统里苹果自己的应用图标（运行时从系统读，不随安装包分发），用户一眼认得；读不到才用自己画的
        if kind == .voiceMemos, let icon = Self.voiceMemosIcon {
            // 系统应用图标四周留了约 10% 的透明边，放大一点让主体和其他设备的方块一样大
            Image(nsImage: icon).resizable().interpolation(.high)
                .frame(width: size * 1.22, height: size * 1.22).frame(width: size, height: size)
        } else {
            SidebarIcon(glyph: kind.glyph, size: size)
        }
    }

    static let voiceMemosIcon: NSImage? = {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: "com.apple.VoiceMemos") else { return nil }
        return ws.icon(forFile: url.path)
    }()
}

struct PanelDeviceGlyph: View {
    let kind: DeviceKind
    let active: Bool
    var body: some View {
        ZStack {
            Circle().fill(active ? (kind == .voiceMemos ? Color(red: 0.93, green: 0.25, blue: 0.24) : kind == .c1Max ? Color.indigo : kind == .usbDisk ? Color.teal : Color.e1Blue)
                          : Color.primary.opacity(0.08))
            switch kind {
            case .e1:
                PenGlyph(body_: active ? .white : Color.primary.opacity(0.3), detail: active ? .e1Blue : Color.dyn(0xDCDCDE, 0x4A4A4C))
                    .frame(width: 16, height: 16)
            case .c1Max:
                C1Glyph(body_: active ? .white : Color.primary.opacity(0.3), detail: active ? .indigo : Color.dyn(0xDCDCDE, 0x4A4A4C))
                    .frame(width: 16, height: 16)
            case .usbDisk:
                Image(systemName: "externaldrive.fill").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary.opacity(0.35))
            case .voiceMemos:
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary.opacity(0.35))
            }
        }
        .frame(width: 26, height: 26)
    }
}

extension SettingsNav {
    /// Preferences › 设备 › one device's page.
    @MainActor static func openDevice(_ d: DeviceKind) {
        shared.requestSub = d.subpage
        shared.request = .device
    }
}
