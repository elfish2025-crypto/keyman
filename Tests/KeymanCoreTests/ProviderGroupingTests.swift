import Foundation
import Testing
@testable import KeymanCore

@Suite
struct ProviderGroupingTests {
    private func profile(_ provider: ProviderKind = .customREST, host: String? = nil, group: String? = nil) -> ProviderProfile {
        var value = ProviderProfile.fixture(alias: "example")
        value.provider = provider
        value.endpoints = host.map { [.init(id: UUID(), alias: "default", name: "E", baseURL: URL(string: "https://\($0)")!)] } ?? []
        value.group = group
        return value
    }

    @Test
    func explicitGroupWinsOverInference() {
        #expect(ProviderGrouping.group(for: profile(.volcengineArk, group: "我的分组")) == "我的分组")
        #expect(ProviderGrouping.group(for: profile(.volcengineArk, group: "  ")) == "火山引擎")
    }

    @Test
    func infersVendorFromKindAndEndpointHost() {
        #expect(ProviderGrouping.group(for: profile(.volcengineArk)) == "火山引擎")
        #expect(ProviderGrouping.group(for: profile(.alibabaBailian)) == "阿里百炼")
        #expect(ProviderGrouping.group(for: profile(host: "openspeech.bytedance.com")) == "火山引擎")
        #expect(ProviderGrouping.group(for: profile(host: "api.vidu.cn")) == "Vidu")
        #expect(ProviderGrouping.group(for: profile(host: "service.vidu.cn")) == "Vidu")
        #expect(ProviderGrouping.group(for: profile(host: "tokenhub.tencentmaas.com")) == "腾讯云")
        #expect(ProviderGrouping.group(for: profile(host: "api.minimaxi.com")) == "MiniMax")
        #expect(ProviderGrouping.group(for: profile(host: "example.com")) == "其他")
        #expect(ProviderGrouping.group(for: profile(host: "eviltencent.com")) == "其他")
        #expect(ProviderGrouping.group(for: profile()) == "其他")
    }

    @Test
    func ordersKnownVendorsFirstAndFallbackLast() {
        let profiles = [profile(group: "其他"), profile(group: "Zeta"), profile(group: "腾讯云"),
                        profile(group: "火山引擎"), profile(group: "Alpha")]
        #expect(ProviderGrouping.orderedGroups(profiles) == ["火山引擎", "腾讯云", "Alpha", "Zeta", "其他"])
    }

    @Test
    func validatesGroupNames() throws {
        #expect(try ProviderGrouping.parse("  ") == nil)
        #expect(try ProviderGrouping.parse(" Vidu ") == "Vidu")
        #expect(throws: KeymanError.self) { try ProviderGrouping.parse(String(repeating: "a", count: 41)) }
        #expect(throws: KeymanError.self) { try ProviderGrouping.parse("a\nb") }
        var bad = ProviderProfile.fixture(alias: "example")
        bad.group = "a\nb"
        #expect(throws: KeymanError.self) {
            try ConfigurationValidator.validate(KeymanConfiguration(profiles: [bad]))
        }
    }

    @Test
    func managementDocumentSetsAndClearsGroup() throws {
        let base = ProviderProfile.fixture(alias: "example")
        let set = try ManagementDocuments.profile(Data(#"{"group":"火山引擎","name":"火山方舟 · 图像与视频"}"#.utf8), existing: base)
        #expect(set.group == "火山引擎")
        #expect(set.alias == "example")
        let cleared = try ManagementDocuments.profile(Data(#"{"group":null}"#.utf8), existing: set)
        #expect(cleared.group == nil)
    }
}
