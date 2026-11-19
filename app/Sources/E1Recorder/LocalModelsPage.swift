import AppKit
import SwiftUI

/// 偏好 › 转写 › 服务选项 › 本机模型：下载、暂停、继续、删除本机语音模型。
struct LocalModelsPage: View {
    @EnvironmentObject var s: AppSettings
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(LocalModels.all) { ModelRow(model: $0, current: s.localEngine == $0.id) }
            } header: {
                SectionTitle("本机模型", info: "在这台 Mac 上转写，录音不上传。模型第一次用要下载一次：先从国内镜像下，下不了再从 GitHub 官方下；下完核对校验码，确认和官方发布的一模一样。只在你点「下载」时才下载。")
            } footer: {
                HStack {
                    Text("两个模型准确度差不多：X-ASR 错字少，Paraformer 漏字少。删掉后随时可以重新下载。")
                        .font(.e1Sub).foregroundStyle(Color.t2)
                    Spacer()
                    Button("在访达中显示") {
                        try? FileManager.default.createDirectory(at: LocalModels.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(LocalModels.root)
                    }
                    .buttonStyle(.link).font(.e1Sub)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }
}

private struct ModelRow: View {
    let model: LocalModel
    let current: Bool
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        let st = store.state(model)
        LabeledContent {
            ModelActions(model: model)
        } label: {
            HStack(spacing: 6) {
                Text(model.name)
                if model == LocalModels.xasr { Tag(text: "推荐") }
                if current { Tag(text: "正在用") }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.note) · 下载约 \(model.downloadSize / 1_000_000) MB · \(model.license)")
                if let f = st.fraction { ProgressView(value: f).frame(maxWidth: 260) }
                if st != .notInstalled {
                    Text(st.label).foregroundStyle(st.isFailure ? Color.e1Red : Color.t2).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.t2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).stroke(Color.t2.opacity(0.5), lineWidth: 0.5))
    }
}

/// 下载 / 暂停 / 继续 / 删除。服务选项页的「语音模型」那一行和引导第 1 页也用它（引导页不给删除）。
struct ModelActions: View {
    let model: LocalModel
    var allowDelete = true
    @ObservedObject private var store = ModelStore.shared
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 8) {
            switch store.state(model) {
            case .notInstalled:
                Button("下载") { store.download(model) }.disabled(store.isBusy)
            case .failed:
                Button("重试") { store.download(model) }.disabled(store.isBusy)
            case .paused:
                Button("继续") { store.download(model) }.disabled(store.isBusy)
                if allowDelete { Button("删除") { store.delete(model) } }
            case .downloading:
                Button("暂停") { store.pause(model) }
            case .unpacking:
                ProgressView().controlSize(.small)
            case .installed:
                if allowDelete { Button("删除…") { confirmDelete = true } }
            }
        }
        .confirmationDialog("删除本机模型「\(model.name)」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.delete(model) }
        } message: {
            Text("删除后用它转写前要重新下载（约 \(model.downloadSize / 1_000_000) MB）。已经转好的纪要不受影响。")
        }
    }
}
