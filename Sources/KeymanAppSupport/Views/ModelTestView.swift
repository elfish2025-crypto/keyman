import SwiftUI
import KeymanCore

struct ModelTestView: View {
    @Bindable var app: AppModel
    @State private var profile: ProviderProfile
    @State private var model: ModelRecord
    @Environment(\.dismiss) private var dismiss
    @State private var request = "{}"
    @State private var result = ""
    @State private var running = false
    @State private var confirming = false
    @State private var populated = false
    @State private var taskID = ""

    init(app: AppModel, profile: ProviderProfile, model: ModelRecord) {
        self.app = app
        self._profile = State(initialValue: profile)
        self._model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("测试请求") {
                    Text("提供符合此接口的请求内容。执行后会向供应商发送真实请求，可能计费，并遵守当前水印规则。")
                        .font(.callout)
                    TextEditor(text: $request).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160).accessibilityLabel("测试请求内容")
                }
                Section {
                    Button("检查请求（不调用供应商）") {
                        do {
                            _ = try KeymanRequestBuilder().build(profile: profile, model: model,
                                secret: "", body: Data(request.utf8), policy: app.configuration.outputPolicy)
                            result = "本机请求检查通过；尚未读取 Key 或调用供应商。"
                        } catch { result = error.localizedDescription }
                    }.disabled(running)
                    Button("执行测试（可能计费）") { confirming = true }
                        .disabled(running || app.testingModelID != nil)
                    if running { ProgressView("等待供应商响应…") }
                    if !result.isEmpty { Text(result).textSelection(.enabled) }
                }
                if model.callTemplate?.taskQuery != nil {
                    Section("查询已有任务") {
                        TextField("任务编号", text: $taskID).autocorrectionDisabled()
                        Button("查询进度与成品") {
                            running = true
                            Task {
                                defer { running = false }
                                do { show(try await app.queryTask(profile: profile, model: model, taskID: taskID)) }
                                catch { result = error.localizedDescription }
                            }
                        }.disabled(running || taskID.isEmpty)
                        Text("查询同一个任务，不会重新生成或提交新任务。成功后继续检查成品。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("测试 \(model.name)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() }.disabled(running) } }
            .onAppear {
                guard !populated else { return }; populated = true
                do { request = JSONValue.pretty(try ModelCatalog.example(profile: profile, model: model)) }
                catch { result = error.localizedDescription }
            }
            .alert("执行真实模型请求？", isPresented: $confirming) {
                Button("执行") {
                    running = true
                    app.confirmBillableTest(modelID: model.id)
                    Task {
                        defer { running = false }
                        do {
                            let response = try await app.testModel(profileAlias: profile.alias, model: model, body: Data(request.utf8), expectedProfile: profile)
                            show(response)
                        } catch { result = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("将使用当前请求内容调用供应商，可能产生费用。") }
        }
    }

    private func show(_ response: CallResponse) {
        if let task = response.task { taskID = task.id }
        let taskText = response.task.map { "任务 \($0.id)：\($0.status)\n" } ?? ""
        result = taskText + (response.verification?.detail ?? "收到 HTTP \(response.statusCode)。")
            + "\n" + String(decoding: response.body.prefix(12_000), as: UTF8.self)
    }
}
