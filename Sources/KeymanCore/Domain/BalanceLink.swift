import Foundation

/// A link to the provider's own balance page. Keyman only opens it in the user's
/// browser: it never requests the page, never sends credentials and never reads a balance.
public enum BalanceLink {
    public struct Resolved: Equatable, Sendable {
        public var url: URL
        /// `true` when the account stores the link itself; `false` for a built-in default.
        public var isCustom: Bool
    }

    /// Accepts only plain https links so the button cannot launch other applications
    /// or leak credentials through the URL.
    public static func validate(_ url: URL) throws {
        guard url.absoluteString.count <= 2048,
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw KeymanError.invalidRequest("余额页链接必须是不含账号信息的 https 地址。")
        }
    }

    /// Parses user-entered text. Blank text means "no custom link".
    public static func parse(_ text: String) throws -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed) else {
            throw KeymanError.invalidRequest("余额页链接格式不正确。")
        }
        try validate(url)
        return url
    }

    public static func resolve(_ profile: ProviderProfile) -> Resolved? {
        if let url = profile.balanceURL { return Resolved(url: url, isCustom: true) }
        if let url = defaultURL(for: profile) { return Resolved(url: url, isCustom: false) }
        return nil
    }

    // Defaults are limited to pages confirmed in each provider's official documentation.
    // Volcengine and Vidu have no confirmed console URL, so those accounts need their own link.
    static func defaultURL(for profile: ProviderProfile) -> URL? {
        let hosts = profile.endpoints.compactMap { $0.baseURL.host?.lowercased() }
        func any(_ suffixes: [String]) -> Bool {
            hosts.contains { host in suffixes.contains { host == $0 || host.hasSuffix("." + $0) } }
        }
        if profile.provider == .alibabaBailian || any(["aliyuncs.com"]) {
            return URL(string: "https://billing-cost.console.aliyun.com/fortune/billing-account")
        }
        if any(["tencentmaas.com", "tencent.com", "tencentcloudapi.com"]) {
            return URL(string: "https://console.cloud.tencent.com/expense/overview")
        }
        if any(["minimaxi.com", "minimax.cn"]) {
            return URL(string: "https://platform.minimax.cn/user-center/payment/balance")
        }
        if any(["minimax.io"]) {
            return URL(string: "https://platform.minimax.io/user-center/payment/balance")
        }
        return nil
    }
}
