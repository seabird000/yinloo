import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AboutPage: View {
    enum Check: Equatable { case idle, checking, latest, newer(String), failed }
    @State private var check: Check = .idle

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本") {
                    HStack {
                        switch check {
                        case .idle: Trailing(text: AppLinks.version)
                        case .checking: ProgressView().controlSize(.small); Trailing(text: "检查中…")
                        case .latest: Trailing(text: "\(AppLinks.version) · 已是最新")
                        case .newer(let v): Text("有新版本 \(v)").foregroundStyle(.tint)
                        case .failed: Trailing(text: "检查失败")
                        }
                        if case .newer = check {
                            Button("下载…") { NSWorkspace.shared.open(AppLinks.download) }
                        } else {
                            Button("检查") { Task { await checkUpdate() } }.disabled(check == .checking)
                        }
                    }
                }
                LabeledContent {
                    Button("打开…") { NSWorkspace.shared.open(AppLinks.website) }
                } label: {
                    Text("官网")
                    Text("yinloo.com")
                }
                LabeledContent {
                    Button("打开…") { NSWorkspace.shared.open(AppLinks.repo) }
                } label: {
                    Text("源代码")
                    Text("github.com/seabird000/yinloo")
                }
                LabeledContent("数据目录") {
                    Button("在访达中显示") {
                        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("E1Recorder")
                        NSWorkspace.shared.activateFileViewerSelecting([u])
                    }
                }
            } header: {
                VStack(spacing: 4) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    Text("音录").font(.title3.weight(.semibold)).foregroundStyle(.primary).padding(.top, 6)
                    Text("能录音的，就能用 AI 转成文字。录音笔、语音备忘录和 Mac 上的录音，自动转写，整理成会议纪要。")
                        .font(.callout).fontWeight(.regular).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 380).padding(.top, 2).padding(.bottom, 14)
                }
                .frame(maxWidth: .infinity)
            } footer: {
                Text(Self.credits)
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
    }

    /// 页脚：本应用的许可和内置的第三方组件。点名字打开包里的许可证或声明文件（系统默认的文本编辑器）；
    /// 开发时直接运行、包里没有这些文件，就只显示文字。
    static var credits: AttributedString {
        func part(_ text: String, _ url: URL? = nil) -> AttributedString {
            var s = AttributedString(text)
            s.link = url
            return s
        }
        func bundled(_ name: String) -> URL? { Bundle.main.url(forResource: name, withExtension: "txt") }
        return part("MIT 许可", AppLinks.license) + part(" · 内置 ")
            + part("adb", bundled("adb-NOTICE")) + part("（Apache-2.0）、")
            + part("sherpa-onnx", bundled("sherpa-onnx-LICENSE")) + part("（Apache-2.0，")
            + part("编入的组件", bundled("sherpa-onnx-ThirdPartyNotices")) + part("）、")
            + part("ONNX Runtime", bundled("onnxruntime-LICENSE")) + part("（MIT，")
            + part("第三方声明", bundled("onnxruntime-ThirdPartyNotices")) + part("）。")
            + part("本机转写模型下载后使用：X-ASR（上海交通大学等，Apache-2.0）、Paraformer 和标点模型（阿里巴巴达摩院 FunASR），见")
            + part("模型声明", bundled("models-NOTICE")) + part("。")
    }

    private func checkUpdate() async {
        check = .checking
        guard let latest = await UpdateCheck.latest() else { check = .failed; return }
        check = UpdateCheck.isNewer(latest) ? .newer(latest) : .latest
    }
}
