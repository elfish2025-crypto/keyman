import SwiftUI
import KeymanCore

struct ProfileDetailView: View {
    @Bindable var model: AppModel
    let profileID: UUID
    @State private var showingAddModel = false
    @State private var editingModel: ModelRecord?
    @State private var testingModel: ModelRecord?
    @State private var readingModel: ModelRecord?
    @State private var deletingModel: ModelRecord?
    @State private var showingModelDeleteConfirm = false
    @State private var showingEditProfile = false
    @State private var replacingKeyProfile: ProviderProfile?
    @State private var newKey = ""
    @State private var showingDeleteConfirm = false
    @State private var showingClearKeyConfirm = false
    @State private var credentialEditSnapshot: ProviderProfile?

    var profile: ProviderProfile? { model.configuration.profiles.first { $0.id == profileID } }

    var body: some View {
        Group {
            if let profile { content(for: profile) }
            else { ContentUnavailableView("账号已删除", systemImage: "key.slash") }
        }
        .navigationTitle(profile?.name ?? "账号")
        .toolbar {
            if profile != nil { Button("编辑账号", systemImage: "pencil") { showingEditProfile = true }.disabled(model.isManaging) }
        }
        .sheet(isPresented: $showingEditProfile) {
            if let profile { ProfileEditorView(model: model, editing: profile).frame(width: 680, height: 700) }
        }
        .sheet(isPresented: $showingAddModel) {
            if let profile { ModelEditorView(model: model, profileID: profile.id).frame(width: 640, height: 700) }
        }
        .sheet(item: $editingModel) { record in
            ModelEditorView(model: model, profileID: profileID, editing: record).frame(width: 640, height: 700)
        }
        .sheet(item: $testingModel) { record in
            if let profile { ModelTestView(app: model, profile: profile, model: record).frame(width: 680, height: 600) }
        }
        .sheet(item: $readingModel) { record in
            if let profile { ModelGuideView(packet: ModelCatalog.packet(profile: profile, model: record, policy: model.configuration.outputPolicy)).frame(width: 700, height: 650) }
        }
        .sheet(item: $replacingKeyProfile, onDismiss: { newKey = "" }) { profile in
            replaceKeySheet(for: profile).frame(width: 540, height: 320)
        }
        .alert("删除账号？", isPresented: $showingDeleteConfirm) {
            Button("删除", role: .destructive) {
                Task { do { try await model.deleteProfile(profileID, original: credentialEditSnapshot) } catch { model.presentedError = error.localizedDescription } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("删除本机账号、所属模型与已保存的 Key。供应商端的 Key 保持原状。") }
        .alert("移除已保存的 Key？", isPresented: $showingClearKeyConfirm) {
            Button("移除", role: .destructive) {
                Task { do { try await model.replaceKey(profileID: profileID, secret: nil, original: credentialEditSnapshot) } catch { model.presentedError = error.localizedDescription } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("保留账号与模型配置；添加新的 Key 后才能继续调用。") }
        .alert("删除模型？", isPresented: $showingModelDeleteConfirm) {
            Button("删除", role: .destructive) {
                guard let deletingModel else { return }
                Task { do { try await model.deleteModel(deletingModel, profileID: profileID) } catch { model.presentedError = error.localizedDescription } }
            }
            Button("取消", role: .cancel) { deletingModel = nil }
        } message: { Text("将从此账号删除模型“\(deletingModel?.name ?? "")”的本机配置，账号与 Key 保留。") }
        .safeAreaInset(edge: .bottom, spacing: 0) { OperationErrorView(model: model) }
    }

    @ViewBuilder
    private func content(for profile: ProviderProfile) -> some View {
        List {
            Section("账号") {
                LabeledContent("账号标识", value: profile.alias)
                LabeledContent("供应商", value: profile.provider.rawValue)
                LabeledContent("状态", value: profile.isEnabled ? "已启用" : "已停用")
                if let workspace = profile.workspaceName { LabeledContent("工作空间", value: workspace) }
                if let workspaceID = profile.workspaceID { LabeledContent("Workspace / App ID", value: workspaceID) }
                if let project = profile.project { LabeledContent("项目", value: project) }
                if let region = profile.region { LabeledContent("区域", value: region) }
                LabeledContent("Key", value: model.credentialLabel(profile.id))
            }
            Section("接口与认证") {
                if profile.endpoints.isEmpty { Text("尚未配置接口，请在“编辑账号”中补充。").foregroundStyle(.secondary) }
                ForEach(profile.endpoints) { endpoint in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(endpoint.name) · \(endpoint.alias)")
                        Text(endpoint.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                LabeledContent("认证字段", value: profile.authentication.headerName.isEmpty ? "尚未配置" : profile.authentication.headerName)
                LabeledContent("认证前缀", value: profile.authentication.prefix.isEmpty ? "无" : profile.authentication.prefix)
                LabeledContent("凭证环境变量", value: profile.authentication.environmentVariable.isEmpty ? "尚未配置" : profile.authentication.environmentVariable)
            }
            Section {
                Button("测试配置") {
                    Task { do { try await model.testProfile(profile) } catch { model.presentedError = error.localizedDescription } }
                }.disabled(!profile.isEnabled || model.isManaging)
                if let result = model.profileTestResults[profile.id] {
                    Text(result == .remoteAuthenticated ? "远程鉴权成功" : "本机凭证可读取；尚未进行远程模型调用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("模型") {
                if profile.models.isEmpty { Text("尚未配置模型。保存 Key 后还需添加模型和调用方式。").foregroundStyle(.secondary) }
                ForEach(profile.models) { record in modelRow(profile: profile, record: record) }
                Button("添加模型") { showingAddModel = true }.disabled(model.isManaging)
            }
            if profile.notes != nil || !profile.sourceFiles.isEmpty {
                Section("来源与备注") {
                    if let notes = profile.notes { Text(notes).font(.callout) }
                    ForEach(profile.sourceFiles, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            Section("管理") {
                Button("编辑账号") { showingEditProfile = true }
                Button(profile.isEnabled ? "停用账号" : "启用账号") {
                    Task { do { try await model.setProfileEnabled(profile.id, enabled: !profile.isEnabled) } catch { model.presentedError = error.localizedDescription } }
                }
                Button("替换 Key") { newKey = ""; replacingKeyProfile = profile }
                Button("移除 Key，保留账号", role: .destructive) { credentialEditSnapshot = profile; showingClearKeyConfirm = true }
                Button("删除账号", role: .destructive) { credentialEditSnapshot = profile; showingDeleteConfirm = true }
            }.disabled(model.isManaging)
        }
    }

    private func modelRow(profile: ProviderProfile, record: ModelRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(record.name).font(.headline)
                Spacer()
                Text(record.isEnabled ? statusTitle(record.status) : "已停用").font(.caption).foregroundStyle(.secondary)
            }
            Text("标识：\(record.alias)").font(.caption).foregroundStyle(.secondary)
            Text(record.usageGuide?.summary.isEmpty == false ? record.usageGuide!.summary : "尚未填写用途，请在编辑模型中补充。")
                .font(.callout).foregroundStyle(record.usageGuide == nil ? .secondary : .primary)
            Text(record.modelID ?? (record.hasRequiredModelID ? "由接口或资源编号选择服务" : "调用配置待补充")).font(.caption).foregroundStyle(record.hasRequiredModelID ? Color.secondary : Color.orange)
            if record.callTemplate == nil { Text("调用方式尚未配置。").font(.caption).foregroundStyle(.orange) }
            if WatermarkPolicy.isVisual(record) {
                Text("水印：\(WatermarkPolicy.capability(profile: profile, model: record)?.disposition.title ?? "尚未核对")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("使用说明") { readingModel = record }
                Button("编辑模型") { editingModel = record }
                Button(record.isEnabled ? "停用模型" : "启用模型") {
                    Task { do { try await model.setModelEnabled(record, profileID: profile.id, enabled: !record.isEnabled) } catch { model.presentedError = error.localizedDescription } }
                }
                Button("测试模型…") { testingModel = record }
                    .disabled(!profile.isEnabled || !record.isEnabled || !record.status.isCallable || !record.hasRequiredModelID)
                Button("删除模型", role: .destructive) { deletingModel = record; showingModelDeleteConfirm = true }
            }.buttonStyle(.bordered).disabled(model.isManaging)
            if let result = model.modelTestResults[record.id] { Text(result).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
            .accessibilityElement(children: .contain)
    }

    private func statusTitle(_ status: ModelStatus) -> String {
        switch status { case .candidate: "候选"; case .declared: "已声明"; case .verified: "已验证"; case .unavailable: "不可用" }
    }

    private func replaceKeySheet(for profile: ProviderProfile) -> some View {
        NavigationStack {
            Form {
                SecureField("新 API Key", text: $newKey)
                Text("现有 \(model.credentialLabel(profile.id))").font(.caption).foregroundStyle(.secondary)
                Text("更换后保留账号和模型；旧的模型验证记录会清除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("替换 Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { newKey = ""; replacingKeyProfile = nil }.disabled(model.isManaging) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do { try await model.replaceKey(profileID: profile.id, secret: newKey, original: profile); newKey = ""; replacingKeyProfile = nil }
                            catch { model.presentedError = error.localizedDescription }
                        }
                    }.disabled(newKey.isEmpty || model.isManaging)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { OperationErrorView(model: model) }
        }
    }
}
