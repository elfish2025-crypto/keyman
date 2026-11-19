import SwiftUI
import KeymanCore

private struct EndpointFormRecord: Identifiable {
    var id = UUID()
    var alias = ""
    var name = ""
    var address = ""
    init(_ endpoint: EndpointRecord? = nil) {
        if let endpoint { id = endpoint.id; alias = endpoint.alias; name = endpoint.name; address = endpoint.baseURL.absoluteString }
    }
    func record() throws -> EndpointRecord {
        guard let url = URL(string: address) else { throw KeymanError.invalidRequest("接口地址格式不正确。") }
        return .init(id: id, alias: alias, name: name, baseURL: url)
    }
}

struct ProfileEditorView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProviderProfile?
    @State private var draftID = UUID()
    @State private var provider: ProviderKind = .volcengineArk
    @State private var name = ""
    @State private var alias = ""
    @State private var secret = ""
    @State private var isEnabled = true
    @State private var project = ""
    @State private var region = ""
    @State private var workspaceName = ""
    @State private var workspaceID = ""
    @State private var notes = ""
    @State private var balanceURLText = ""
    @State private var authHeader = "Authorization"
    @State private var authPrefix = "Bearer"
    @State private var environmentVariable = "ARK_API_KEY"
    @State private var endpoints: [EndpointFormRecord] = []
    @State private var saving = false
    @State private var populated = false

    init(model: AppModel, editing: ProviderProfile? = nil) {
        self.model = model; self._editing = State(initialValue: editing)
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                scopeSection
                endpointsSection
                authenticationSection
                balanceSection
                Section("备注") {
                    TextEditor(text: $notes).frame(minHeight: 70).accessibilityLabel("账号备注")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editing == nil ? "添加账号" : "编辑账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { secret = ""; dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task {
                            defer { saving = false }
                            do { try await save(); secret = ""; dismiss() }
                            catch { model.presentedError = error.localizedDescription }
                        }
                    }
                    .disabled(name.isEmpty || alias.isEmpty || saving || model.isManaging)
                }
            }
            .onAppear { populate() }
            .onChange(of: provider) { _, value in
                guard editing == nil, populated else { return }
                endpoints = []
                region = ""
                if value == .volcengineArk { try? fillPreset() }
                else {
                    authHeader = value == .alibabaBailian ? "Authorization" : ""
                    authPrefix = value == .alibabaBailian ? "Bearer" : ""
                    environmentVariable = value == .alibabaBailian ? "DASHSCOPE_API_KEY" : ""
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { OperationErrorView(model: model) }
        }
    }

    private var identitySection: some View {
        Section("账号") {
            Picker("供应商", selection: $provider) {
                Text("火山方舟").tag(ProviderKind.volcengineArk)
                Text("阿里百炼").tag(ProviderKind.alibabaBailian)
                Text("其他 / 自定义 REST API").tag(ProviderKind.customREST)
            }
            TextField("名称", text: $name)
            TextField("账号标识（供 Agent 使用）", text: $alias).autocorrectionDisabled()
            if editing != nil {
                Text("更改标识后，Agent 的命令需使用新标识；已保存的 Key 与模型保持关联。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField("API Key（可稍后填写）", text: $secret)
            }
            Toggle("启用账号", isOn: $isEnabled)
        }
    }

    private var scopeSection: some View {
        Section("所属范围") {
            TextField("项目（可选）", text: $project)
            TextField("区域（可选）", text: $region)
            TextField("工作空间名称（可选）", text: $workspaceName)
            TextField("Workspace / App ID（可选）", text: $workspaceID).autocorrectionDisabled()
        }
    }

    private var endpointsSection: some View {
        Section("接口地址") {
            if endpoints.isEmpty {
                Text("尚未配置接口；可先保存凭证，随后补齐模型调用信息。")
                    .foregroundStyle(.secondary)
            }
            ForEach($endpoints) { $endpoint in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("接口名称", text: $endpoint.name)
                    TextField("接口标识", text: $endpoint.alias).autocorrectionDisabled()
                    TextField("Base URL", text: $endpoint.address).autocorrectionDisabled()
                    HStack {
                        Button("移除此接口", role: .destructive) { endpoints.removeAll { $0.id == endpoint.id } }
                            .disabled(isReferenced(endpoint.id))
                        if isReferenced(endpoint.id) {
                            Text("模型正在使用；先调整模型的接口再移除。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 6)
            }
            Button("添加接口") { endpoints.append(EndpointFormRecord()) }
            if provider != .customREST {
                Button("填入供应商北京区域预设") {
                    do { try fillPreset() } catch { model.presentedError = error.localizedDescription }
                }
                Text("该按钮替换表单中的接口和认证设置；保存前仍可取消。其他区域请填写对应地址。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var authenticationSection: some View {
        Section("认证设置") {
            TextField("认证 Header 名", text: $authHeader).autocorrectionDisabled()
            TextField("认证前缀（没有则留空）", text: $authPrefix).autocorrectionDisabled()
            TextField("凭证环境变量名", text: $environmentVariable).autocorrectionDisabled()
            Text("这里只填写字段名称，例如 Authorization、Bearer、ARK_API_KEY。完整 Key 使用账号里的“替换 Key”保存。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var balanceSection: some View {
        Section("余额页") {
            TextField("余额页链接（可选，https）", text: $balanceURLText).autocorrectionDisabled()
            Text("点击账号旁的余额按钮时，用默认浏览器打开这个页面。Keyman 不访问该页面，也不会带上任何凭证。留空则使用内置默认链接（如有）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func isReferenced(_ id: UUID) -> Bool {
        guard let endpoint = editing?.endpoints.first(where: { $0.id == id }) else { return false }
        return editing?.models.contains { $0.callTemplate?.endpointAlias == endpoint.alias } == true
    }

    private func populate() {
        guard !populated else { return }; populated = true
        guard let editing else { try? fillPreset(); return }
        draftID = editing.id; provider = editing.provider; name = editing.name; alias = editing.alias
        isEnabled = editing.isEnabled; project = editing.project ?? ""; region = editing.region ?? ""
        workspaceName = editing.workspaceName ?? ""; workspaceID = editing.workspaceID ?? ""; notes = editing.notes ?? ""
        balanceURLText = editing.balanceURL?.absoluteString ?? ""
        endpoints = editing.endpoints.map { EndpointFormRecord($0) }
        authHeader = editing.authentication.headerName; authPrefix = editing.authentication.prefix
        environmentVariable = editing.authentication.environmentVariable
    }

    private func fillPreset() throws {
        let preset = try ProviderPresets.profile(kind: provider, name: name, alias: alias,
            workspaceID: optional(workspaceID), project: project, workspaceName: optional(workspaceName))
        endpoints = preset.endpoints.map { endpoint in
            var item = EndpointFormRecord(endpoint)
            if let old = editing?.endpoints.first(where: { $0.alias == endpoint.alias }) { item.id = old.id }
            return item
        }
        region = preset.region ?? ""
        authHeader = preset.authentication.headerName; authPrefix = preset.authentication.prefix
        environmentVariable = preset.authentication.environmentVariable
    }

    private func optional(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private func save() async throws {
        let profile = ProviderProfile(id: draftID, alias: alias, name: name, provider: provider,
            project: optional(project), region: optional(region), workspaceName: optional(workspaceName), workspaceID: optional(workspaceID),
            endpoints: try endpoints.map { try $0.record() },
            authentication: .init(headerName: authHeader, prefix: authPrefix, environmentVariable: environmentVariable),
            notes: optional(notes), sourceFiles: editing?.sourceFiles ?? [], models: editing?.models ?? [],
            lastTestedAt: editing?.lastTestedAt, lastTestSucceeded: editing?.lastTestSucceeded, isEnabled: isEnabled,
            balanceURL: try BalanceLink.parse(balanceURLText))
        try await model.saveProfile(profile, secret: editing == nil && !secret.isEmpty ? secret : nil, original: editing)
    }
}
