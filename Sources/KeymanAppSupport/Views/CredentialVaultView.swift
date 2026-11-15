import SwiftUI
import KeymanCore

struct CredentialVaultView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?
    @State private var fromSource = false
    @State private var sourcePath = ""
    @State private var sourceCurrent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("一次授权，统一读取") {
                    Text("新版本把所有 Key 保存在一个 macOS 钥匙串条目中。浏览账号和模型不会自动弹出授权窗口。")
                    Text("系统询问时，输入 Mac 登录密码并选择“始终允许”，供本版本的应用和 Agent 后续访问。选择“允许”仅对本次有效。")
                    Text("应用升级导致签名变化、钥匙串锁定或系统权限重置后，仍可能要求重新授权一次。Keyman 不收集或保存你的登录密码。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("授权读取统一凭证库") { perform { try await model.readVaultStatus(unlock: true) } }
                }
                if let status = model.vaultStatus {
                    Section("当前状态") {
                        Text(status.exists ? "统一凭证库已创建" : "尚未创建统一凭证库")
                        Text("已保存 \(status.profiles.filter { $0.state == .stored }.count) 个；已清除 \(status.profiles.filter { $0.state == .cleared }.count) 个；旧条目或未配置 \(status.profiles.filter { $0.state == .legacyOrMissing }.count) 个。")
                            .font(.caption)
                    }
                }
                Section("迁移旧版本凭证") {
                    Toggle("使用原始导入目录", isOn: $fromSource)
                    if fromSource {
                        TextField("目录", text: $sourcePath)
                        Toggle("确认目录中的 Key 是现用版本", isOn: $sourceCurrent)
                        Text("直接写入统一库，不逐条读取旧 Key。已迁移的不同 Key 不会被覆盖。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("从现有钥匙串迁移时，系统可能最后一次逐条请求授权。旧条目保留作恢复备份；日后移除 Key 或删除账号时一并清除。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("迁移到统一凭证库") {
                        perform { try await model.migrateVault(sourceURL: fromSource ? URL(fileURLWithPath: sourcePath) : nil) }
                    }.disabled(fromSource && (!sourceCurrent || sourcePath.isEmpty))
                    if let report = model.vaultMigrationReport {
                        Text("本次迁移 \(report.migratedAliases.count) 个凭证。\(report.missingAliases.isEmpty ? "" : "未找到：" + report.missingAliases.joined(separator: "、"))")
                    }
                }
                if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                if busy { ProgressView("正在处理，请在出现时完成系统授权…") }
            }.formStyle(.grouped).disabled(busy || model.isManaging)
            .navigationTitle("Keyman 凭证库")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) } }
            .task { do { try await model.readVaultStatus() } catch { message = error.localizedDescription } }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = nil
        Task { defer { busy = false }; do { try await action() } catch { message = error.localizedDescription } }
    }
}
