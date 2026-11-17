import AppKit
import SwiftUI

/// The recording devices the app syncs from. The menu bar panel and Preferences › 设备 only talk to this layer
/// (name, icon, one status line, sync, settings page); each device's own sync code stays where it is.
enum DeviceKind: String, CaseIterable, Identifiable {
    case e1
    case voiceMemos
    var id: String { rawValue }

    var name: String {
        switch self {
        case .e1: "搜狗 E1 录音笔"
        case .voiceMemos: "语音备忘录"
        }
    }
    /// Preferences sub-page with this device's settings.
    var subpage: String { "device-" + rawValue }
    var glyph: SidebarIcon.Glyph { self == .e1 ? .device : .voiceMemos }
    /// Folder (inside the audio folder) that this device's new recordings are copied into, by month.
    var folderName: String {
        switch self {
        case .e1: "搜狗E1"
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
    /// Devices in the menu bar panel: the pen always, the others once they're switched on.
    var panelDevices: [DeviceKind] { DeviceKind.allCases.filter { $0 == .e1 || isEnabled($0) } }

    func isEnabled(_ d: DeviceKind) -> Bool {
        switch d {
        case .e1: true
        case .voiceMemos: settings.voiceMemos
        }
    }

    /// The latest time any device was synced or looked at (for 「立即同步 · 上次 …」).
    var lastAnySync: Date? {
        [lastSync, lastWifiCheck, settings.voiceMemos ? memoScan?.at : nil].compactMap { $0 }.max()
    }

    func deviceStatus(_ d: DeviceKind) -> DeviceStatus {
        switch d {
        case .e1: e1Status
        case .voiceMemos: voiceMemoStatus
        }
    }

    private var e1Status: DeviceStatus {
        let clock = DateFormatter.cached("HH:mm")
        let snap = penSnapshot
        let battery = snap?.battery.map { "电量 \($0)%" + ((snap?.charging ?? false) ? "（充电中）" : "") }
        let last = lastSync.map { "上次同步 " + clock.string(from: $0) }
        var details: [String] = []
        if penConnected {
            details.append("USB 已连接" + (penClock.isEmpty ? "" : " · " + penClock))
        }
        if settings.wifiReady {
            if let w = wifiStatus, let seen = w.seen {
                details.append(w.isOnline ? "WiFi 在线 · 心跳 \(relativeTime(seen))" : "WiFi 最后在线 \(relativeTime(seen))")
            } else {
                details.append("WiFi 还没收到心跳")
            }
        } else if !penConnected {
            details.append("插上数据线即自动同步，也可设置 WiFi 同步")
        }
        let counts = [battery, snap?.freeBytes.map { "可用 " + formatBytes($0) }].compactMap { $0 }
        if !counts.isEmpty { details.append(counts.joined(separator: " · ")) }
        let tail = [last, snap?.recordingCount.map { "笔内 \($0) 条" }].compactMap { $0 }
        if !tail.isEmpty { details.append(tail.joined(separator: " · ")) }

        if isCopying {
            let what = (copySource == "WiFi" ? "正在取回" : "正在拷贝") + " \(min(copyDone + 1, copyTotal)) / \(copyTotal)"
            return DeviceStatus(tag: penConnected ? "已连接" : "在线", level: .ok, line: what, details: details)
        }
        if penConnected {
            return DeviceStatus(tag: "已连接", level: .ok, line: (["USB 已连接", battery, last].compactMap { $0 }).joined(separator: " · "), details: details)
        }
        if wifiOnline, let seen = wifiStatus?.seen {
            return DeviceStatus(tag: "在线", level: .ok, line: (["WiFi 在线", battery, "心跳 " + relativeTime(seen)].compactMap { $0 }).joined(separator: " · "), details: details)
        }
        if settings.wifiReady, let e = wifiError {
            return DeviceStatus(tag: "出错", level: .problem, line: e, details: details)
        }
        if settings.wifiReady, let seen = wifiStatus?.seen {
            return DeviceStatus(tag: "离线", level: .idle, line: "WiFi 最后在线 \(relativeTime(seen))" + (last.map { " · " + $0 } ?? ""), details: details)
        }
        return DeviceStatus(tag: "未连接", level: .idle, line: "插上数据线即自动同步" + (last.map { " · " + $0 } ?? ""), details: details)
    }

    private var voiceMemoStatus: DeviceStatus {
        guard settings.voiceMemos else {
            return DeviceStatus(tag: "未开启", level: .idle, line: "打开后，iPhone 和这台 Mac 上的新录音自动转写", details: [])
        }
        guard let scan = memoScan else {
            return DeviceStatus(tag: "检查中", level: .waiting, line: "正在查找语音备忘录…", details: [])
        }
        let since = settings.voiceMemosSince.map { "只转写 " + DateFormatter.cached("M月d日 HH:mm").string(from: $0) + " 以后录的" } ?? "只转写从现在起录的"
        let checked = "上次检查 " + DateFormatter.cached("HH:mm").string(from: scan.at)
        switch scan.problem {
        case .noAccess?:
            return DeviceStatus(tag: "需要授权", level: .problem, line: "需要在「完全磁盘访问权限」里打开本应用", details: ["需要在「完全磁盘访问权限」里打开本应用"])
        case .notFound?:
            return DeviceStatus(tag: "没有录音", level: .idle, line: "这台 Mac 上还没有语音备忘录", details: ["这台 Mac 上还没有语音备忘录", "iPhone 的录音要在 iCloud 里打开语音备忘录同步"])
        case .audioFolder?:
            return DeviceStatus(tag: "等待中", level: .waiting, line: "录音目录现在用不了，接上移动硬盘后自动继续", details: ["录音目录现在用不了（移动硬盘没接？）", checked])
        case .failed(let why)?:
            return DeviceStatus(tag: "出错", level: .problem, line: why, details: [why])
        case nil:
            var details = [since]
            if scan.settling > 0 { details.append("\(scan.settling) 条正在录音或同步，好了就转写") }
            return DeviceStatus(tag: "已开启", level: .ok, line: checked + " · " + since, details: details, short: "已开启 · " + checked)
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
    var body: some View { SidebarIcon(glyph: kind.glyph, size: size) }
}

struct PanelDeviceGlyph: View {
    let kind: DeviceKind
    let active: Bool
    var body: some View {
        ZStack {
            Circle().fill(active ? (kind == .voiceMemos ? Color(red: 0.93, green: 0.25, blue: 0.24) : Color.e1Blue) : Color.primary.opacity(0.08))
            switch kind {
            case .e1:
                PenGlyph(body_: active ? .white : Color.primary.opacity(0.3), detail: active ? .e1Blue : Color.dyn(0xDCDCDE, 0x4A4A4C))
                    .frame(width: 16, height: 16)
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
