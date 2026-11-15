import SwiftUI
import UniformTypeIdentifiers
import KeymanCore

struct OutputPolicyView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFiles = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("图片与视频") {
                    Picker("默认输出要求", selection: Binding(get: { model.configuration.outputPolicy }, set: { policy in
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await model.setOutputPolicy(policy) }
                            catch { model.presentedError = error.localizedDescription }
                        }
                    })) {
                        ForEach(OutputPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(saving)
                    Text("无可见水印：支持关闭的模型自动关闭；已确认不加水印、没有开关的模型不添加参数；未核对或无法关闭时在调用前说明原因。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("更换模型或接口后需要重新核对。生成结果会在本机检查；检查失败不会自动重新生成。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("检查已有结果") {
                    Button("选择图片或视频…") { choosingFiles = true }
                        .disabled(model.checkingMedia)
                    if model.checkingMedia { ProgressView("正在本机检查…") }
                    ForEach(Array(model.mediaInspections.enumerated()), id: \.offset) { _, inspection in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: inspection.file).lastPathComponent).bold()
                            Text(inspection.status == .noVisibleMarkDetected ? "未检出常见文字水印" : "需要检查结果")
                                .foregroundStyle(inspection.status == .noVisibleMarkDetected ? .green : .orange)
                            ForEach(inspection.findings, id: \.self) { Text($0) }
                            Text(inspection.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("图片使用文字识别；视频抽查首尾及约每 2 秒的画面。可能漏掉纯图形或短暂出现的标记，不检测隐形水印。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("输出规则")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await model.inspectMedia(urls) }
                case .failure(let error): model.presentedError = error.localizedDescription
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { OperationErrorView(model: model) }
        }
    }
}
