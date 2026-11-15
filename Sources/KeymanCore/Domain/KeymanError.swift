import Foundation

public enum KeymanError: Error, LocalizedError, Equatable, Sendable {
    case invalidAlias(String)
    case duplicateProfileAlias(String)
    case duplicateModelAlias(profile: String, model: String)
    case duplicateEndpointAlias(profile: String, endpoint: String)
    case endpointNotFound(profile: String, endpoint: String)
    case modelNotCallable(String)
    case unsupportedSchemaVersion(Int)
    case profileNotFound(String)
    case profileDisabled(String)
    case configurationChanged
    case modelNotFound(String)
    case modelNotEnabled(String)
    case keyMissing
    case keyRejected
    case authenticationRejected(status: Int, detail: String)
    case rateLimited
    case invalidRequest(String)
    case networkError(String)
    case providerError(status: Int, message: String)
    case importInvalid(String)
    case keychainDenied
    case outputPolicyBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAlias(let alias):
            return "标识“\(alias)”无效，请使用小写字母、数字和连字符。"
        case .duplicateProfileAlias(let alias):
            return "配置“\(alias)”已存在，请修改标识，或在原配置中替换 Key。"
        case .duplicateModelAlias(_, let alias):
            return "模型标识“\(alias)”已存在。"
        case .duplicateEndpointAlias(_, let alias):
            return "接口标识“\(alias)”已存在。"
        case .endpointNotFound(_, let alias):
            return "找不到接口“\(alias)”，请选择此配置中已保存的接口。"
        case .modelNotCallable(let alias):
            return "模型“\(alias)”缺少 Model ID 或调用模板，请先补全。"
        case .unsupportedSchemaVersion(let version):
            return "配置文件版本 \(version) 暂不受支持，请使用匹配的 Keyman 版本。"
        case .profileNotFound(let alias):
            return "找不到配置“\(alias)”，请先添加或导入账号。"
        case .profileDisabled(let alias):
            return "账号“\(alias)”已停用，请启用后再调用。"
        case .configurationChanged:
            return "配置已被其他窗口或 Agent 修改，本次未覆盖。请刷新后重新编辑。"
        case .modelNotFound(let alias):
            return "找不到模型“\(alias)”，请检查模型标识。"
        case .modelNotEnabled(let alias):
            return "模型“\(alias)”处于候选或不可用状态，请确认已开通后再调用。"
        case .keyMissing:
            return "此配置尚未保存 API Key，请添加或替换 Key。"
        case .keyRejected:
            return "供应商拒绝了请求，请检查 Key、账号权限及接口地址。"
        case .authenticationRejected(let status, let detail):
            return "供应商拒绝了认证或授权（HTTP \(status)）：\(detail)。请核对凭证、地域、业务空间和服务权限。"
        case .rateLimited:
            return "供应商限制了请求频率或额度，请稍后重试并检查账号用量。"
        case .invalidRequest(let message), .importInvalid(let message), .outputPolicyBlocked(let message):
            return message
        case .networkError(let message):
            return "网络请求失败：\(message)"
        case .providerError(let status, let message):
            return "操作失败（\(status)）：\(message)"
        case .keychainDenied:
            return "无法访问 macOS 钥匙串。请解锁钥匙串，并在系统询问时允许 Keyman 访问。"
        }
    }
}
