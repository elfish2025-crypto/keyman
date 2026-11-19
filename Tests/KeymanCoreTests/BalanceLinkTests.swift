import Foundation
import Testing
@testable import KeymanCore

@Suite
struct BalanceLinkTests {
    private func profile(
        provider: ProviderKind = .customREST,
        host: String? = nil,
        balanceURL: URL? = nil
    ) -> ProviderProfile {
        var value = ProviderProfile.fixture(alias: "example")
        value.provider = provider
        value.endpoints = host.map { [.init(id: UUID(), alias: "default", name: "E", baseURL: URL(string: "https://\($0)")!)] } ?? []
        value.balanceURL = balanceURL
        return value
    }

    @Test
    func acceptsOnlyPlainHTTPS() throws {
        try BalanceLink.validate(URL(string: "https://console.cloud.tencent.com/expense/overview")!)
        for bad in ["http://example.com/a", "file:///etc/passwd", "javascript:alert(1)",
                    "https://user:pw@example.com/", "https:///nohost", "x-apple.systempreferences:"] {
            #expect(throws: KeymanError.self) { try BalanceLink.validate(URL(string: bad)!) }
        }
    }

    @Test
    func parseTreatsBlankAsNoLink() throws {
        #expect(try BalanceLink.parse("   ") == nil)
        #expect(try BalanceLink.parse(" https://example.com/balance ")?.host == "example.com")
        #expect(throws: KeymanError.self) { try BalanceLink.parse("http://example.com") }
    }

    @Test
    func ownLinkWinsOverDefault() {
        let own = URL(string: "https://example.com/my-balance")!
        let resolved = BalanceLink.resolve(profile(host: "tokenhub.tencentmaas.com", balanceURL: own))
        #expect(resolved == .init(url: own, isCustom: true))
    }

    @Test
    func documentedDefaultsMatchByHostSuffix() {
        #expect(BalanceLink.resolve(profile(host: "tokenhub.tencentmaas.com"))?.url.host == "console.cloud.tencent.com")
        #expect(BalanceLink.resolve(profile(host: "api.ai3d.cloud.tencent.com"))?.url.host == "console.cloud.tencent.com")
        #expect(BalanceLink.resolve(profile(host: "ws-x.cn-beijing.maas.aliyuncs.com"))?.url.host == "billing-cost.console.aliyun.com")
        #expect(BalanceLink.resolve(profile(provider: .alibabaBailian))?.url.host == "billing-cost.console.aliyun.com")
        #expect(BalanceLink.resolve(profile(host: "api.minimaxi.com"))?.url.host == "platform.minimax.cn")
    }

    @Test
    func noGuessForUnconfirmedProviders() {
        #expect(BalanceLink.resolve(profile(host: "ark.cn-beijing.volces.com")) == nil)
        #expect(BalanceLink.resolve(profile(host: "api.vidu.cn")) == nil)
        #expect(BalanceLink.resolve(profile(host: "openspeech.bytedance.com")) == nil)
        // A lookalike host must not match a documented suffix.
        #expect(BalanceLink.resolve(profile(host: "eviltencent.com")) == nil)
    }

    @Test
    func validatorRejectsUnsafeStoredLink() {
        var bad = ProviderProfile.fixture(alias: "example")
        bad.balanceURL = URL(string: "http://example.com")!
        #expect(throws: KeymanError.self) {
            try ConfigurationValidator.validate(KeymanConfiguration(profiles: [bad]))
        }
    }

    @Test
    func managementDocumentSetsAndClearsLink() throws {
        let base = ProviderProfile.fixture(alias: "example")
        let set = try ManagementDocuments.profile(
            Data(#"{"balanceURL":"https://example.com/balance"}"#.utf8), existing: base)
        #expect(set.balanceURL?.absoluteString == "https://example.com/balance")
        let cleared = try ManagementDocuments.profile(Data(#"{"balanceURL":null}"#.utf8), existing: set)
        #expect(cleared.balanceURL == nil)
    }

    @Test
    func oldConfigurationsStillLoad() throws {
        let data = Data(#"{"schemaVersion":5,"profiles":[]}"#.utf8)
        let config = try JSONDecoder().decode(KeymanConfiguration.self, from: data)
        #expect(config.schemaVersion == KeymanConfiguration.currentSchemaVersion)
    }
}
