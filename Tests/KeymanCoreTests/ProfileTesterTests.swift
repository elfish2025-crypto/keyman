import Foundation
import Testing
@testable import KeymanCore

@Test
func testBailianProfileTestUsesGETModelsAndNeverPOST() async throws {
    let profile = ProviderProfile.bailianFixture
    let configuration = InMemoryConfigurationStore(.init(profiles: [profile]))
    let credentials = InMemoryCredentialStore()
    await credentials.save("unit-test-credential", for: profile.id)
    let transport = RecordingHTTPTransport(
        response: .init(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))
    )
    let tester = ProfileTester(
        configurationStore: configuration,
        credentialStore: credentials,
        transport: transport
    )

    let result = try await tester.test(profileAlias: profile.alias)
    let request = await transport.lastRequest

    #expect(result == .remoteAuthenticated)
    #expect(request?.httpMethod == "GET")
    #expect(request?.url?.path == "/compatible-mode/v1/models")
}

@Test
func testArkProfileTestIsLocalOnlyAndMakesNoProviderRequest() async throws {
    let profile = ProviderProfile.fixture(alias: "example-ark")
    let configuration = InMemoryConfigurationStore(.init(profiles: [profile]))
    let credentials = InMemoryCredentialStore()
    await credentials.save("unit-test-credential", for: profile.id)
    let transport = RecordingHTTPTransport(
        response: .init(statusCode: 500, headers: [:], body: Data())
    )
    let tester = ProfileTester(
        configurationStore: configuration,
        credentialStore: credentials,
        transport: transport
    )

    #expect(try await tester.test(profileAlias: profile.alias) == .localOnly)
    let request = await transport.lastRequest
    #expect(request == nil)
}
