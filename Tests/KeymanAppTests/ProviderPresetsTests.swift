import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanAppSupport

@Test
func testArkPresetUsesPlatformAPIAndARKEnvironmentVariable() throws {
    let profile = try ProviderPresets.profile(
        kind: .volcengineArk,
        name: "Example-Ark",
        alias: "example-ark",
        workspaceID: nil
    )
    #expect(
        profile.endpoints.first?.baseURL.absoluteString ==
        "https://ark.cn-beijing.volces.com/api/v3"
    )
    #expect(profile.authentication.environmentVariable == "ARK_API_KEY")
}

@Test
func testBailianWorkspacePresetBuildsDedicatedBeijingEndpoints() throws {
    let profile = try ProviderPresets.profile(
        kind: .alibabaBailian,
        name: "example-workspace",
        alias: "example-workspace",
        workspaceID: "ws-unit-test"
    )
    #expect(
        profile.endpoints.first(where: { $0.alias == "openai" })?.baseURL.absoluteString ==
        "https://ws-unit-test.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    )
    #expect(
        profile.endpoints.first(where: { $0.alias == "dashscope" })?.baseURL.absoluteString ==
        "https://ws-unit-test.cn-beijing.maas.aliyuncs.com/api/v1"
    )
}

@Test
func testCustomRESTProfileUsesOnlySavedHostAndAuthSettings() throws {
    let profile = try ProviderPresets.customProfile(
        name: "Internal Image API",
        alias: "internal-image",
        baseURL: "https://api.example.invalid/v1",
        headerName: "X-API-Key",
        prefix: "",
        environmentVariable: "INTERNAL_IMAGE_API_KEY"
    )
    #expect(profile.endpoints.first?.baseURL.host == "api.example.invalid")
    #expect(profile.authentication.headerName == "X-API-Key")
}

@Test
func testPresetPreservesEnteredProjectAndWorkspaceName() throws {
    let ark = try ProviderPresets.profile(
        kind: .volcengineArk, name: "Film", alias: "film", workspaceID: nil,
        project: "film-production"
    )
    #expect(ark.project == "film-production")
    let bailian = try ProviderPresets.profile(
        kind: .alibabaBailian, name: "Voice", alias: "voice", workspaceID: "ws-test",
        workspaceName: "Voice Production"
    )
    #expect(bailian.workspaceName == "Voice Production")
}

@Test
func testBailianPresetRejectsWorkspaceIDThatChangesTheHost() {
    #expect(throws: KeymanError.self) {
        try ProviderPresets.profile(
            kind: .alibabaBailian, name: "Voice", alias: "voice", workspaceID: "other.example/path"
        )
    }
}
