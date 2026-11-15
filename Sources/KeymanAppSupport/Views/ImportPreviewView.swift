import SwiftUI
import KeymanCore

struct ImportPreviewView: View {
    @Bindable var model: AppModel
    let rootURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var preview: ImportPreview?
    @State private var loadError: String?
    @State private var showingCommitConfirm = false
    @State private var committing = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("导入预览")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("确认导入") {
                            showingCommitConfirm = true
                        }
                        .disabled(preview == nil || committing)
                    }
                }
                .task { await load() }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    OperationErrorView(model: model)
                }
                .alert("确认导入", isPresented: $showingCommitConfirm) {
                    Button("导入", role: .destructive) {
                        Task {
                            do {
                                try await commit()
                                dismiss()
                            } catch {
                                model.presentedError = error.localizedDescription
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("新增凭证将保存到本机钥匙串。已有账号会先核对：相同 Key 保留现有配置，不同 Key 停止导入并提示冲突。")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
            List {
                ForEach(Array(preview.profiles.enumerated()), id: \.offset) { _, item in
                    Section(profileSectionTitle(item.profile)) {
                        profileSummary(item)
                        ForEach(item.profile.models) { modelRecord in
                            modelRow(profile: item.profile, modelRecord: modelRecord)
                        }
                    }
                }
            }
        } else if let loadError {
            ContentUnavailableView {
                Label("无法生成预览", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else {
            ProgressView("解析中…")
        }
    }

    @ViewBuilder
    private func profileSummary(_ item: ImportedProfilePreview) -> some View {
        let suffixText: String = item.secretSuffix.map { "Key ····\($0)" } ?? "未发现 Key"
        LabeledContent("Key") {
            Text(suffixText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("API Key 已隐藏")
        }
        LabeledContent("Alias") {
            Text(item.profile.alias).foregroundStyle(.secondary)
        }
        if model.configuration.profiles.contains(where: { $0.alias == item.profile.alias || $0.previousAliases.contains(item.profile.alias) }) {
            Text("已有账号：核对 Key 后保留现有模型和输出规则。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if item.profile.models.isEmpty {
            Text("保存凭证；模型和调用方式尚未配置。")
                .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Provider") {
            Text(item.profile.provider.rawValue).foregroundStyle(.secondary)
        }
        if let workspace = item.profile.workspaceName {
            LabeledContent("工作空间") {
                Text(workspace).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modelRow(profile: ProviderProfile, modelRecord: ModelRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(modelRecord.name).font(.subheadline)
                Spacer()
                Text(modelStatusLabel(profile: profile, modelRecord: modelRecord))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.15))
                    .clipShape(Capsule())
            }
            Text("alias: \(modelRecord.alias)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(modelRecord.modelID ?? "缺少 Model ID")
                .font(.caption)
                .foregroundStyle(modelRecord.modelID == nil ? .red : .secondary)
        }
    }

    private func modelStatusLabel(profile: ProviderProfile, modelRecord: ModelRecord) -> String {
        switch profile.provider {
        case .volcengineArk:
            return "已声明开通"
        case .alibabaBailian:
            return "候选"
        case .customREST:
            return modelRecord.status.rawValue
        }
    }

    private func profileSectionTitle(_ profile: ProviderProfile) -> String {
        switch profile.provider {
        case .volcengineArk: return "火山方舟 · \(profile.name)"
        case .alibabaBailian: return "阿里百炼 · \(profile.name)"
        case .customREST: return profile.name
        }
    }

    private func load() async {
        do {
            preview = try model.importPreview(rootURL: rootURL)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func commit() async throws {
        guard let preview else { return }
        committing = true
        defer { committing = false }
        try await model.commitImport(preview)
    }
}
