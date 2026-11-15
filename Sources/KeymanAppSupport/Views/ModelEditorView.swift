import SwiftUI
import KeymanCore

struct ModelEditorView: View {
    @Bindable var model: AppModel
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var alias = ""
    @State private var modelID = ""
    @State private var modality: ModelModality = .other
    @State private var status: ModelStatus = .declared
    @State private var isEnabled = true
    @State private var endpointAlias = ""
    @State private var method: HTTPMethod = .post
    @State private var path = ""
    @State private var modelIDBodyField = ""
    @State private var requestFieldsText = ""
    @State private var isAsync = false
    @State private var sourceFile = ""
    @State private var watermarkDisposition: WatermarkDisposition = .unknown
    @State private var watermarkPath = "watermark"
    @State private var watermarkDisabledValue = "false"
    @State private var watermarkEvidence = ""
    @State private var capabilityBinding = ""
    @State private var outputPathsText = ""
    @State private var staticHeadersText = "{}"
    @State private var responseFormat: CallResponseFormat = .json
    @State private var uuidHeadersText = ""
    @State private var requiredFieldsText = ""
    @State private var taskQueryText = ""
    @State private var purpose = ""
    @State private var useCasesText = ""
    @State private var inputs = ""
    @State private var outputs = ""
    @State private var instructionsText = ""
    @State private var limitationsText = ""
    @State private var documentationText = ""
    @State private var exampleText = ""
    @State private var confirmExample = false

    @State private var editing: ModelRecord?
    @State private var expectedProfile: ProviderProfile?
    @State private var populated = false

    init(model: AppModel, profileID: UUID, editing: ModelRecord? = nil) {
        self.model = model
        self.profileID = profileID
        self._editing = State(initialValue: editing)
        self._expectedProfile = State(initialValue: model.configuration.profiles.first { $0.id == profileID })
    }

    private var requestFields: [String] {
        requestFieldsText
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private var hasCallTemplate: Bool {
        !endpointAlias.isEmpty && !path.isEmpty
    }

    private var callTemplate: CallTemplate? {
        guard hasCallTemplate else { return nil }
        return CallTemplate(
            endpointAlias: endpointAlias,
            method: method,
            path: path,
            modelIDBodyField: modelIDBodyField.isEmpty ? nil : modelIDBodyField,
            staticHeaders: (try? JSONDecoder().decode([String: String].self, from: Data(staticHeadersText.utf8))) ?? [:],
            requestFields: requestFields,
            isAsync: isAsync,
            outputPaths: outputPathsText.isEmpty ? nil : outputPathsText
                .split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init),
            responseFormat: responseFormat == .json ? nil : responseFormat,
            uuidHeaders: uuidHeadersText.isEmpty ? nil : words(uuidHeadersText),
            requiredBodyFields: requiredFieldsText.isEmpty ? nil : words(requiredFieldsText),
            taskQuery: taskQueryText.isEmpty ? nil : try? JSONDecoder().decode(TaskQueryTemplate.self, from: Data(taskQueryText.utf8))
        )
    }

    private var draft: ModelRecord {
        ModelRecord(id: editing?.id ?? UUID(), alias: alias, name: name,
            modelID: modelID.isEmpty ? nil : modelID, modality: modality, status: status,
            callTemplate: callTemplate, sourceFile: sourceFile.isEmpty ? nil : sourceFile,
            lastVerifiedAt: editing?.lastVerifiedAt, isEnabled: isEnabled)
    }

    private var currentFingerprint: String {
        guard let profile = expectedProfile else { return "" }
        return WatermarkPolicy.fingerprint(profile: profile, model: draft)
    }

    private var canSave: Bool {
        if status == .verified {
            return !name.isEmpty
                && !alias.isEmpty
                && (modelIDBodyField.isEmpty || !modelID.isEmpty)
                && !endpointAlias.isEmpty
                && !path.isEmpty
        }
        // declared models may be incomplete and remain visible
        return !name.isEmpty && !alias.isEmpty
    }

    private var hintMessage: String {
        if (!modelIDBodyField.isEmpty && modelID.isEmpty) || !hasCallTemplate {
            return "不可调用：缺少所需的 Model ID 或调用模板"
        }
        return ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("Alias", text: $alias)
                        .autocorrectionDisabled()
                    TextField("Model ID", text: $modelID)
                        .autocorrectionDisabled()
                    Picker("模态", selection: $modality) {
                        ForEach(ModelModality.allCases, id: \.self) { item in
                            Text(modalityTitle(item)).tag(item)
                        }
                    }
                    Picker("状态", selection: $status) {
                        ForEach(ModelStatus.allCases.filter { $0 != .verified || editing?.status == .verified }, id: \.self) { item in
                            Text(statusTitle(item)).tag(item)
                        }
                    }
                    Toggle("启用模型", isOn: $isEnabled)
                    .onChange(of: status) { _, newValue in
                        if newValue == .verified {
                            if endpointAlias.isEmpty { endpointAlias = "default" }
                        }
                    }
                    if let hint = Optional(hintMessage), !hint.isEmpty {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("用途与使用说明") {
                    TextField("一句话介绍：这个模型做什么", text: $purpose, axis: .vertical)
                    TextField("适用任务（每行一个）", text: $useCasesText, axis: .vertical)
                    TextField("需要输入什么", text: $inputs, axis: .vertical)
                    TextField("会返回什么", text: $outputs, axis: .vertical)
                    TextField("使用步骤（每行一步）", text: $instructionsText, axis: .vertical)
                    TextField("限制与注意事项（每行一条）", text: $limitationsText, axis: .vertical)
                    TextField("官方文档地址（每行一个）", text: $documentationText, axis: .vertical)
                    DisclosureGroup("请求示例（JSON，不含 Key）") {
                        TextEditor(text: $exampleText).font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120).accessibilityLabel("请求示例")
                        Toggle("我已按当前接口重新核对这个示例", isOn: $confirmExample)
                        Text("修改接口后，旧示例会标记为待核对。留空表示尚未提供可执行示例。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("人和 Agent 共用这份说明。填写说明不会自动开通或验证模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("调用模板") {
                    Picker("使用的接口", selection: $endpointAlias) {
                        Text("尚未选择").tag("")
                        ForEach(expectedProfile?.endpoints ?? []) { endpoint in
                            Text("\(endpoint.name) · \(endpoint.alias)").tag(endpoint.alias)
                        }
                    }
                    if expectedProfile?.endpoints.isEmpty != false {
                        Text("此账号尚未配置接口。先在账号的“编辑账号”中添加接口地址和认证方式。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Picker("Method", selection: $method) {
                        ForEach(HTTPMethod.allCases, id: \.self) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    TextField("Path（相对路径）", text: $path)
                        .autocorrectionDisabled()
                    TextField("Model ID Body 字段（可空）", text: $modelIDBodyField)
                        .autocorrectionDisabled()
                    TextField("Request 字段（空格/逗号分隔）", text: $requestFieldsText)
                        .autocorrectionDisabled()
                    Text("附加请求头（JSON，仅限非密钥信息）").font(.caption)
                    TextEditor(text: $staticHeadersText).font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 55).accessibilityLabel("附加请求头")
                    Toggle("接口返回异步任务", isOn: $isAsync)
                    if isAsync {
                        Text("此调用返回任务编号；填写查询配置后，可在测试窗口继续查询，Agent 可用 task 命令等待结果。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("响应处理与调用前检查") {
                        Picker("响应格式", selection: $responseFormat) {
                            Text("标准 JSON").tag(CallResponseFormat.json)
                            Text("百炼语音（检查完整音频）").tag(CallResponseFormat.dashscopeTTSAudio)
                            Text("豆包语音 SSE（合并音频）").tag(CallResponseFormat.volcengineTTSSSE)
                            Text("豆包音色设计（检查训练状态）").tag(CallResponseFormat.volcengineVoiceDesign)
                            Text("Vidu 视频（参数与任务检查）").tag(CallResponseFormat.viduVideo)
                        }
                        TextField("每次生成 UUID 的请求头", text: $uuidHeadersText)
                        TextField("必填请求字段（点分路径）", text: $requiredFieldsText)
                        Text("没有 model 参数的服务可将 Model ID 和对应请求字段留空。必填字段为空或仍为占位值时，会在读取 Key 前停止。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("任务查询配置（JSON，留空表示未配置）").font(.caption)
                        TextEditor(text: $taskQueryText).font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 75).accessibilityLabel("任务查询配置")
                    }
                    if modality == .image || modality == .video {
                        TextField("返回文件字段（留空自动识别）", text: $outputPathsText)
                        Text("例如 data.*.url 或 output.video_url；多个字段用逗号分开。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if modality == .image || modality == .video {
                    Section("可见水印") {
                        Picker("模型的水印行为", selection: $watermarkDisposition) {
                            ForEach(WatermarkDisposition.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if watermarkDisposition == .configurable {
                            TextField("关闭开关的字段路径", text: $watermarkPath)
                            TextField("关闭时的 JSON 值", text: $watermarkDisabledValue)
                            Text("例如 watermark 或 parameters.watermark；值通常为 false，也可使用 0 或带双引号的字符串。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if watermarkDisposition == .none {
                            Text("调用时不添加任何水印字段。请以模型文档或实测为依据，不要仅凭没有开关推断。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("资料来源或实测依据", text: $watermarkEvidence)
                        Text("结论绑定当前模型版本与接口；更换后会重新要求核对。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("来源") {
                    TextField("Source File", text: $sourceFile)
                        .autocorrectionDisabled()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "添加模型" : "编辑模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                try await save()
                                dismiss()
                            } catch {
                                model.presentedError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(!canSave || model.isManaging)
                }
            }
            .onAppear { populate() }
            .onChange(of: currentFingerprint) { _, value in
                if !capabilityBinding.isEmpty && capabilityBinding != value {
                    watermarkDisposition = .unknown
                    watermarkEvidence = ""
                    capabilityBinding = value
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                OperationErrorView(model: model)
            }
        }
    }

    private func populate() {
        guard !populated else { return }
        populated = true
        guard let editing else {
            endpointAlias = expectedProfile?.endpoints.first?.alias ?? ""
            modelIDBodyField = "model"
            return
        }
        name = editing.name
        alias = editing.alias
        modelID = editing.modelID ?? ""
        modality = editing.modality
        status = editing.status
        isEnabled = editing.isEnabled
        endpointAlias = editing.callTemplate?.endpointAlias ?? ""
        method = editing.callTemplate?.method ?? .post
        path = editing.callTemplate?.path ?? ""
        modelIDBodyField = editing.callTemplate?.modelIDBodyField ?? ""
        requestFieldsText = (editing.callTemplate?.requestFields ?? []).joined(separator: ", ")
        isAsync = editing.callTemplate?.isAsync ?? false
        responseFormat = editing.callTemplate?.responseFormat ?? .json
        uuidHeadersText = editing.callTemplate?.uuidHeaders?.joined(separator: ", ") ?? ""
        requiredFieldsText = editing.callTemplate?.requiredBodyFields?.joined(separator: ", ") ?? ""
        if let query = editing.callTemplate?.taskQuery {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            taskQueryText = String(decoding: (try? encoder.encode(query)) ?? Data(), as: UTF8.self)
        }
        sourceFile = editing.sourceFile ?? ""
        if let guide = editing.usageGuide {
            purpose = guide.summary; useCasesText = guide.useCases.joined(separator: "\n")
            inputs = guide.inputs; outputs = guide.outputs
            instructionsText = guide.instructions.joined(separator: "\n")
            limitationsText = guide.limitations.joined(separator: "\n")
            documentationText = guide.documentationURLs.joined(separator: "\n")
            exampleText = guide.requestExample.map(JSONValue.pretty) ?? ""
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        staticHeadersText = String(data: (try? encoder.encode(editing.callTemplate?.staticHeaders ?? [:])) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        outputPathsText = editing.callTemplate?.outputPaths?.joined(separator: ", ") ?? ""
        if let profile = expectedProfile,
           let capability = WatermarkPolicy.capability(profile: profile, model: editing) {
            watermarkDisposition = capability.disposition
            watermarkPath = capability.parameterPath ?? "watermark"
            watermarkDisabledValue = capability.disabledValue?.jsonText ?? "false"
            watermarkEvidence = capability.evidence
            capabilityBinding = capability.contractFingerprint
        } else { capabilityBinding = currentFingerprint }
    }

    private func save() async throws {
        if !taskQueryText.isEmpty && (try? JSONDecoder().decode(TaskQueryTemplate.self, from: Data(taskQueryText.utf8))) == nil {
            throw KeymanError.invalidRequest("任务查询配置不是有效 JSON。请参照管理文档中的 taskQuery 示例。")
        }
        guard path.isEmpty || !endpointAlias.isEmpty else {
            throw KeymanError.invalidRequest("已填写调用路径，请选择该模型使用的接口。")
        }
        guard (try? JSONDecoder().decode([String: String].self, from: Data(staticHeadersText.utf8))) != nil else {
            throw KeymanError.invalidRequest("附加请求头应为 JSON 字符串对象，例如 {\"X-Workspace-Id\":\"workspace\"}。")
        }
        var record = draft
        func lines(_ text: String) -> [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        let example = exampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : try JSONValue.object(from: Data(exampleText.utf8))
        if ![purpose, useCasesText, inputs, outputs, instructionsText, limitationsText, documentationText, exampleText].allSatisfy({ $0.isEmpty }) {
            record.usageGuide = .init(summary: purpose, useCases: lines(useCasesText), inputs: inputs, outputs: outputs,
                instructions: lines(instructionsText), limitations: lines(limitationsText), documentationURLs: lines(documentationText),
                requestExample: example, contractFingerprint: editing?.usageGuide?.contractFingerprint, reviewedAt: editing?.usageGuide?.reviewedAt)
        }
        if WatermarkPolicy.isVisual(record) {
            record.watermarkCapability = WatermarkCapability(disposition: watermarkDisposition,
                parameterPath: watermarkDisposition == .configurable ? watermarkPath : nil,
                disabledValue: watermarkDisposition == .configurable ? try JSONScalar.parse(watermarkDisabledValue) : nil,
                evidence: watermarkEvidence, contractFingerprint: currentFingerprint)
        }
        try await model.addOrUpdateModel(record, profileID: profileID, expectedProfile: expectedProfile, original: editing, confirmUsageExample: confirmExample)
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
    }

    private func modalityTitle(_ modality: ModelModality) -> String {
        switch modality {
        case .text: "文本"
        case .image: "图像"
        case .video: "视频"
        case .speech: "语音合成"
        case .voiceDesign: "音色设计"
        case .other: "其他"
        }
    }

    private func statusTitle(_ status: ModelStatus) -> String {
        switch status {
        case .candidate: "候选"
        case .declared: "已声明"
        case .verified: "已验证"
        case .unavailable: "不可用"
        }
    }
}

extension HTTPMethod: CaseIterable {
    public static var allCases: [HTTPMethod] {
        [.get, .post, .put, .patch, .delete]
    }
}
