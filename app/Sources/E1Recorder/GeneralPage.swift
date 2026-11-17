import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GeneralPage: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @Environment(\.openWindow) private var openWindow
    @State private var msg = ""

    var body: some View {
        Form {
            Section {
                Toggle("开机启动", isOn: Binding(get: { s.launchAtLogin }, set: { s.launchAtLogin = $0 })).toggleStyle(.switch)
                Picker("菜单图标", selection: $s.menuIcon) {
                    ForEach(MenuBarIcon.styles, id: \.id) { st in
                        Label { Text(st.name) } icon: { Image(nsImage: MenuBarIcon.idle(st.id)) }.tag(st.id)
                    }
                }
                LabeledContent("使用引导") { Button("打开…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "welcome") } }
            } header: {
                Text("启动选项")
            }

            Section {
                LabeledContent("导出配置") { Button("导出…", action: exportConfig) }
                LabeledContent("导入配置") {
                    HStack { if !msg.isEmpty { Trailing(text: msg) }; Button("导入…", action: importConfig) }
                }
                LabeledContent("诊断信息") { Button("导出…") { Diagnostics.export() } }
                    .help("遇到问题时导出一份运行情况，方便排查；不含密钥、录音标题和网络名称")
            } header: {
                SectionTitle("配置迁移", info: "换电脑：在新电脑安装本应用 → 导入配置 → 按提示填写访问密钥。导出内容包括平台、模型、应用编号、接口地址、热词、模板与目录、WiFi 同步的存储空间、语音备忘录开关、发言人和地点；访问密钥与钥匙只在钥匙串里，不导出。")
            }
        }
    }

    private func exportConfig() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSSavePanel()
        p.nameFieldStringValue = "音录配置.json"
        if p.runModal() == .OK, let u = p.url {
            do { try s.exportConfig(to: u); msg = "已导出" } catch { msg = error.localizedDescription }
        }
    }

    private func importConfig() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url {
            do {
                try s.importConfig(from: u)
                let m = s.missingSecrets
                msg = m.isEmpty ? "已导入" : "已导入，还需填写：" + m.joined(separator: "、")
            } catch { msg = error.localizedDescription }
        }
    }
}
