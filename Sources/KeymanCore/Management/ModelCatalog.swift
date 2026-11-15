import Foundation

public struct ModelUsagePacket: Codable, Equatable, Sendable {
    public var profileAlias: String
    public var modelAlias: String
    public var modelName: String
    public var modality: ModelModality
    public var guide: ModelUsageGuide?
    public var requestReady: Bool
    public var blockers: [String]
    public var credentialRead = false
    public var networkRequest = false
    public var providerAccessVerified = false
    public var credentialHandling: String
    public var exampleCommand: [String]
    public var preflightCommand: [String]
    public var callCommand: [String]
    public var outputPolicy: OutputPolicy
    public var nextAction: String
    public var requiredBodyFields: [String] = []
    public var taskQueryCommand: [String]? = nil
}

public struct AccountCatalogEntry: Codable, Sendable {
    public var profileAlias: String
    public var name: String
    public var provider: ProviderKind
    public var notes: String?
    public var isEnabled: Bool
    public var nextAction: String?
    public var models: [ModelUsagePacket]
}

public enum ModelCatalog {
    public static func description(_ packet: ModelUsagePacket) -> String {
        let guide = packet.guide
        var lines = [packet.modelName, guide?.summary ?? "尚未填写用途。", "输入：\(guide?.inputs ?? "待补充")", "输出：\(guide?.outputs ?? "待补充")"]
        if let guide {
            lines += guide.useCases.map { "适用：\($0)" }
            lines += guide.instructions.enumerated().map { "\($0.offset + 1). \($0.element)" }
            lines += guide.limitations.map { "限制：\($0)" }
            lines += guide.documentationURLs.map { "资料：\($0)" }
        }
        lines += packet.blockers.map { "待解决：\($0)" }
        lines += [packet.credentialHandling, packet.nextAction, packet.exampleCommand.joined(separator: " "), packet.preflightCommand.joined(separator: " "), packet.callCommand.joined(separator: " ")]
        return lines.joined(separator: "\n")
    }
    public static func packet(profile: ProviderProfile, model: ModelRecord, policy: OutputPolicy) -> ModelUsagePacket {
        let guide = model.usageGuide
        var blockers: [String] = []
        if !profile.isEnabled { blockers.append("账号已停用。") }
        if !model.isEnabled { blockers.append("模型已停用。") }
        if !model.status.isCallable { blockers.append("模型处于候选或不可用状态，尚不能调用。") }
        if !model.hasRequiredModelID && model.callTemplate?.modelIDBodyField != nil { blockers.append("缺少准确的 Model ID。") }
        if model.callTemplate == nil && model.modelID == nil { blockers.append("尚未确定 Model ID，或确认该服务无需 Model ID。") }
        if model.callTemplate == nil { blockers.append("缺少调用接口与路径。") }
        if profile.authentication.headerName.isEmpty { blockers.append("认证方式尚未配置。") }
        if guide?.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { blockers.append("尚未填写模型用途。") }
        if guide?.inputs.isEmpty != false || guide?.outputs.isEmpty != false { blockers.append("尚未说明输入与输出。") }
        if let example = guide?.requestExample {
            if guide?.contractFingerprint != WatermarkPolicy.fingerprint(profile: profile, model: model) {
                blockers.append("调用配置已变化，请重新核对并保存请求示例；旧示例不会自动套用。")
            } else if profile.isEnabled && model.isEnabled && model.status.isCallable && model.hasRequiredModelID {
                do { _ = try KeymanRequestBuilder().build(profile: profile, model: model, secret: "", body: JSONEncoder().encode(example), policy: policy) }
                catch { blockers.append(error.localizedDescription) }
            }
        } else { blockers.append("缺少可直接使用的请求示例。") }
        let prefix = ["keyman", "preflight", profile.alias, model.alias, "--body", "@request.json"]
        var packet = ModelUsagePacket(profileAlias: profile.alias, modelAlias: model.alias, modelName: model.name, modality: model.modality,
            guide: guide, requestReady: blockers.isEmpty, blockers: blockers,
            credentialHandling: "Keyman 使用本账号凭证完成认证。无需读取或粘贴完整 Key；本条说明未检查钥匙串权限、余额或供应商开通状态。",
            exampleCommand: ["keyman", "example", profile.alias, model.alias], preflightCommand: prefix,
            callCommand: ["keyman", "call", profile.alias, model.alias, "--body", "@request.json"], outputPolicy: policy,
            nextAction: blockers.isEmpty ? "导出示例，按任务修改请求并执行 preflight；已获任务调用授权后再 call，检查返回结果。" : "先解决 blockers 中列出的缺项。优先使用本机说明；说明缺失或调用配置变化时再查所列官方文档并更新。")
        packet.requiredBodyFields = model.callTemplate?.requiredBodyFields ?? []
        if model.callTemplate?.taskQuery != nil { packet.taskQueryCommand = ["keyman", "task", profile.alias, model.alias, "<返回的任务编号>"] }
        return packet
    }

    public static func entries(_ configuration: KeymanConfiguration, query: String? = nil) -> [AccountCatalogEntry] {
        let terms = (query ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return configuration.profiles.compactMap { profile in
            let accountText = [profile.alias, profile.name, profile.notes ?? ""].joined(separator: " ").lowercased()
            let models = profile.models.filter { model in
                let guide = model.usageGuide
                let text = [accountText, model.alias, model.name, model.modality.rawValue, guide?.summary ?? "", guide?.useCases.joined(separator: " ") ?? ""].joined(separator: " ").lowercased()
                return terms.allSatisfy { text.contains($0) }
            }.map { packet(profile: profile, model: $0, policy: configuration.outputPolicy) }
            guard terms.isEmpty || !models.isEmpty || terms.allSatisfy({ accountText.contains($0) }) else { return nil }
            return .init(profileAlias: profile.alias, name: profile.name, provider: profile.provider, notes: profile.notes,
                isEnabled: profile.isEnabled, nextAction: profile.models.isEmpty ? "此账号仅保管凭证，尚未配置模型。请先核对接口、模型版本及认证要求。" : nil, models: models)
        }
    }

    public static func example(profile: ProviderProfile, model: ModelRecord) throws -> [String: JSONValue] {
        guard let guide = model.usageGuide, let example = guide.requestExample else {
            throw KeymanError.invalidRequest("此模型尚未保存请求示例。请先阅读 keyman guide，再补齐使用说明。")
        }
        guard guide.contractFingerprint == WatermarkPolicy.fingerprint(profile: profile, model: model) else {
            throw KeymanError.invalidRequest("请求示例对应旧的调用配置，请核对后重新保存。")
        }
        return example
    }
}
