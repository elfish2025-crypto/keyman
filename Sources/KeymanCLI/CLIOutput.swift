import Foundation
import KeymanCore

public struct CLIResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CLIErrorEnvelope: Codable {
    public struct Detail: Codable {
        public var type: String
        public var message: String

        public init(type: String, message: String) {
            self.type = type
            self.message = message
        }
    }
    public var ok = false
    public var error: Detail

    public init(ok: Bool = false, error: Detail) {
        self.ok = ok
        self.error = error
    }
}

enum CLIOutput {
    private struct ProfileSummary: Codable {
        var alias: String
        var name: String
        var provider: ProviderKind
        var project: String?
        var region: String?
        var workspaceName: String?
        var modelCount: Int
        var isEnabled: Bool
    }

    private struct ImportProfileSummary: Codable {
        var profile: ProviderProfile
        var secretSuffix: String?
    }

    private struct Success<T: Encodable>: Encodable {
        var ok = true
        var data: T
    }

    static func profiles(_ profiles: [ProviderProfile], json: Bool) -> CLIResult {
        let summaries = profiles.map {
            ProfileSummary(
                alias: $0.alias,
                name: $0.name,
                provider: $0.provider,
                project: $0.project,
                region: $0.region,
                workspaceName: $0.workspaceName,
                modelCount: $0.models.count,
                isEnabled: $0.isEnabled
            )
        }
        if json { return encoded(Success(data: summaries)) }
        let text = summaries.map { "\($0.alias)\t\($0.provider.rawValue)\t\($0.modelCount)" }
            .joined(separator: "\n")
        return .init(exitCode: 0, stdout: Data((text + "\n").utf8), stderr: Data())
    }

    static func profile(_ profile: ProviderProfile, json: Bool) -> CLIResult {
        if json { return encoded(Success(data: profile)) }
        let text = "\(profile.alias)\t\(profile.name)\n\(profile.notes ?? "")\n"
        return .init(exitCode: 0, stdout: Data(text.utf8), stderr: Data())
    }

    static func models(_ models: [ModelRecord], json: Bool) -> CLIResult {
        if json { return encoded(Success(data: models)) }
        let text = models.map {
            "\($0.alias)\t\($0.status.rawValue)\t\($0.modelID ?? "缺少 Model ID")\t\($0.usageGuide?.summary ?? "尚未填写用途")"
        }.joined(separator: "\n")
        return .init(exitCode: 0, stdout: Data((text + "\n").utf8), stderr: Data())
    }

    static func model(_ model: ModelRecord, json: Bool) -> CLIResult {
        json
            ? encoded(Success(data: model))
            : .init(
                exitCode: 0,
                stdout: Data("\(model.alias)\t\(model.status.rawValue)\n".utf8),
                stderr: Data()
            )
    }

    static func help() -> CLIResult {
        let text = """
        keyman mcp                        本机 MCP 服务（stdio，由 Agent 客户端启动）
        keyman list [--json]
        keyman catalog [用途关键词] [--json]
        keyman guide <profile> <model> [--json]
        keyman example <profile> <model> > request.json
        keyman install-guides [--dry-run]
        keyman vault status|unlock
        keyman vault migrate [--source <原资料目录> --source-current] [--dry-run]
        keyman profile <profile> [--json]
        keyman models <profile> [--json]
        keyman inspect <profile> <model> [--json]
        keyman call <profile> <model> (--body @file | --body-stdin)
        keyman call <profile> <model> (--body @file | --body-stdin) --allow-watermark
        keyman preflight <profile> <model> (--body @file | --body-stdin)
        keyman task <profile> <model> <任务编号> [--wait-seconds 0...600]
        keyman policy [show | set no-visible-watermark | set provider-default]
        keyman watermark-config <profile> <model> --file <能力描述.json>
        keyman verify <图片或视频文件> [更多文件]
        keyman verify-response <profile> <model> --file <已有响应.json>
        keyman run <profile> [--allow-unchecked-output] -- <command>
        keyman import-preview <path> [--json]
        keyman import-commit <path> [--json]
        keyman import-check <path> [--json]

        账号、模型与接口管理（修改类命令支持 --dry-run）：
        keyman profile add --file <profile.json> [--key-stdin | --key-file <key.txt>]
        keyman profile update <profile> --file <patch.json>
        keyman profile get <profile>
        keyman profile list
        keyman profile enable|disable|delete|test <profile>
        keyman endpoint add <profile> --file <endpoint.json>
        keyman endpoint update <profile> <endpoint> --file <patch.json>
        keyman endpoint get|delete <profile> <endpoint>
        keyman endpoint list <profile>
        keyman model add <profile> --file <model.json>
        keyman model update <profile> <model> --file <patch.json>
        keyman model move <原账号> <model> <目标账号> --file <patch.json>
        keyman model get|enable|disable|delete <profile> <model>
        keyman model list <profile>
        keyman key set <profile> (--key-stdin | --key-file <key.txt>)
        keyman key status|clear <profile>

        管理命令返回 JSON。更新文件仅包含需要修改的字段；可选字段用 null 清空。
        Key 不接受命令行明文参数，也不写入 profile.json 或 model.json。
        --dry-run 不写配置或钥匙串，不进行供应商调用。
        catalog 按用途检索；guide 包含输入输出、步骤和缺项；example 导出请求体。
        使用说明不读取 Key、不调用供应商；资料齐备不代表凭证或远程服务已验证。
        task 只查询已有任务：等待中退出码 3，失败／取消退出码 1，成功仍遵守成品检查。不会重复提交生成任务。
        豆包语音 SSE 完整结束后保存音频到本机，JSON 返回 audioFile；中断或错误不会报告合成成功。
        vault unlock 只读取一个统一凭证库条目；系统授权时选择“始终允许”供本版本后续访问。
        迁移默认读取旧钥匙串，首次可能逐条授权；从原目录迁移须先确认 Key 未更换，再提供 --source-current。
        迁移保留旧条目供恢复；clear/delete 同时移除对应旧条目，统一库不自动退回已迁移的旧 Key。

        警告：keyman run 会把 API Key 临时注入子进程；该子进程可以读取原始凭证。
        默认要求无可见水印。图像／视频调用自动检查成品；未完成检查时返回退出码 3，请勿自动重试。
        外部命令无法由 Keyman 检查请求参数，严格规则下默认阻止通用 run；明确使用兼容豁免后，请对结果执行 verify。
        """
        return .init(exitCode: 0, stdout: Data((text + "\n").utf8), stderr: Data())
    }

    static func importPreview(_ preview: ImportPreview, json: Bool) -> CLIResult {
        let safe = preview.profiles.map {
            ImportProfileSummary(
                profile: $0.profile,
                secretSuffix: $0.secretSuffix
            )
        }
        if json { return encoded(Success(data: safe)) }
        let text = safe.map {
            "\($0.profile.alias)\t\($0.profile.models.count) 个模型\tKey ····\($0.secretSuffix ?? "未发现")"
        }.joined(separator: "\n")
        return .init(exitCode: 0, stdout: Data((text + "\n").utf8), stderr: Data())
    }

    static func importReport(_ report: ImportReport, json: Bool) -> CLIResult {
        if json { return encoded(report, exitCode: report.ok ? 0 : 1) }
        let lines = report.credentials.map { item in
            let label: String = switch item.state {
            case .matching: "已保存且一致"
            case .added: "已新增并核对"
            case .restored: "已补回并核对"
            case .missingProfile: "尚未导入"
            case .missingCredential: "缺少凭证"
            case .differentCredential: "与来源不同，未覆盖"
            case .missingSourceKey: "来源缺少 Key"
            }
            let account = item.storedAlias.map { $0 == item.alias ? item.alias : "\(item.alias) → \($0)" } ?? item.alias
            return "\(account)\t\(label)\tKey ····\(item.secretSuffix ?? "未发现")"
        }
        return .init(exitCode: report.ok ? 0 : 1, stdout: Data((lines.joined(separator: "\n") + "\n").utf8), stderr: Data())
    }

    static func error(_ error: Error) -> CLIResult {
        let detail = CLIErrorEnvelope.Detail(
            type: errorType(error),
            message: errorMessage(error)
        )
        let data = (try? JSONEncoder().encode(CLIErrorEnvelope(error: detail)))
            ?? Data(#"{"ok":false,"error":{"type":"provider_error","message":"输出失败"}}"#.utf8)
        return .init(exitCode: 1, stdout: data, stderr: Data())
    }

    static func encoded<T: Encodable>(_ value: T, exitCode: Int32 = 0) -> CLIResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return .init(
            exitCode: exitCode,
            stdout: (try? encoder.encode(value)) ?? Data(),
            stderr: Data()
        )
    }

    private static func errorType(_ error: Error) -> String {
        guard let error = error as? KeymanError else { return "provider_error" }
        switch error {
        case .profileNotFound: return "profile_not_found"
        case .profileDisabled: return "profile_disabled"
        case .configurationChanged: return "configuration_changed"
        case .keyMissing: return "key_missing"
        case .keyRejected, .authenticationRejected: return "key_rejected"
        case .modelNotFound: return "model_not_found"
        case .modelNotEnabled: return "model_not_enabled"
        case .modelNotCallable: return "model_not_callable"
        case .rateLimited: return "rate_limited"
        case .networkError: return "network_error"
        case .invalidRequest, .invalidAlias: return "invalid_request"
        case .importInvalid: return "import_invalid"
        case .keychainDenied: return "keychain_denied"
        case .outputPolicyBlocked: return "output_policy_blocked"
        default: return "provider_error"
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        error.localizedDescription
    }
}
