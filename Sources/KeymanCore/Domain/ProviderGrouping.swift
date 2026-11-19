import Foundation

/// Groups accounts by vendor for display. Grouping never affects credentials, endpoints or calls.
public enum ProviderGrouping {
    public static let fallback = "其他"
    private static let preferredOrder = ["火山引擎", "阿里百炼", "Vidu", "腾讯云", "MiniMax"]

    public static func validate(_ group: String) throws {
        let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, !trimmed.contains(where: \.isNewline) else {
            throw KeymanError.invalidRequest("分组名称不能为空，最长 40 个字符，且不能换行。")
        }
    }

    /// Normalizes user-entered text; blank means "no explicit group".
    public static func parse(_ text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        try validate(trimmed)
        return trimmed
    }

    public static func group(for profile: ProviderProfile) -> String {
        if let group = profile.group?.trimmingCharacters(in: .whitespacesAndNewlines), !group.isEmpty { return group }
        return inferred(for: profile) ?? fallback
    }

    static func inferred(for profile: ProviderProfile) -> String? {
        switch profile.provider {
        case .volcengineArk: return "火山引擎"
        case .alibabaBailian: return "阿里百炼"
        case .customREST: break
        }
        let hosts = profile.endpoints.compactMap { $0.baseURL.host?.lowercased() }
        func any(_ suffixes: [String]) -> Bool {
            hosts.contains { host in suffixes.contains { host == $0 || host.hasSuffix("." + $0) } }
        }
        if any(["volces.com", "volcengine.com", "bytedance.com"]) { return "火山引擎" }
        if any(["aliyuncs.com", "aliyun.com"]) { return "阿里百炼" }
        if any(["vidu.cn", "vidu.com"]) { return "Vidu" }
        if any(["tencentmaas.com", "tencent.com", "tencentcloudapi.com"]) { return "腾讯云" }
        if any(["minimaxi.com", "minimax.cn", "minimax.io"]) { return "MiniMax" }
        return nil
    }

    /// Group names in display order: well-known vendors first, then the rest alphabetically,
    /// with the fallback group last.
    public static func orderedGroups(_ profiles: [ProviderProfile]) -> [String] {
        let names = Set(profiles.map(group(for:)))
        let known = preferredOrder.filter(names.contains)
        let rest = names.subtracting(known).subtracting([fallback]).sorted()
        return known + rest + (names.contains(fallback) ? [fallback] : [])
    }
}
