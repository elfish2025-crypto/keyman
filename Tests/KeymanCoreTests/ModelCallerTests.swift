import Foundation
import Testing
@testable import KeymanCore

@Test
func testCallerMaps429AndRedactsCredential() async {
    let profile = ProviderProfile.fixture(
        alias: "example-ark",
        models: [.seedreamFixture]
    )
    let configuration = InMemoryConfigurationStore(
        .init(profiles: [profile])
    )
    let credentials = InMemoryCredentialStore()
    await credentials.save("unit-test-credential", for: profile.id)
    let transport = StubHTTPTransport(
        response: .init(statusCode: 429, headers: [:], body: Data("unit-test-credential".utf8))
    )
    let caller = ModelCaller(
        configurationStore: configuration,
        credentialStore: credentials,
        transport: transport
    )

    await expectThrowsAsync {
        _ = try await caller.call(
            profileAlias: "example-ark",
            modelAlias: "seedream-5-pro",
            body: Data("{}".utf8)
        )
    }
}

private struct StubHTTPTransport: HTTPTransporting {
    let response: HTTPResponse
    func send(_ request: URLRequest) async throws -> HTTPResponse { response }
}

@Test
func successfulHTTPStillRequiresOutputGateAndAppliesPolicyBeforeSending() async throws {
    let profile = ProviderProfile.fixture(alias: "test", models: [.seedreamFixture])
    let credentials = InMemoryCredentialStore()
    await credentials.save("unit-test-credential", for: profile.id)
    let transport = RecordingHTTPTransport(response: .init(statusCode: 200, headers: [:],
        body: Data(#"{"data":[],"debug":"unit-test-credential"}"#.utf8)))
    let gate = RecordingOutputGate()
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: credentials, transport: transport, outputVerifier: gate)
    let response = try await caller.call(profileAlias: "test", modelAlias: "seedream-5-pro",
        body: Data(#"{"prompt":"cup","watermark":true}"#.utf8))
    let request = try #require(await transport.lastRequest)
    #expect((try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["watermark"] as? Bool == false)
    #expect(response.verification?.status == .suspectedWatermark)
    #expect(await gate.calls == 1)
    #expect(!(await gate.body).contains("unit-test-credential"))
    #expect((await gate.body).contains("[REDACTED]"))
}

private actor RecordingOutputGate: OutputVerifying {
    private(set) var calls = 0
    private(set) var body = ""
    func verify(body: Data, model: ModelRecord, profileAlias: String) async -> OutputVerification {
        calls += 1; self.body = String(decoding: body, as: UTF8.self)
        return .init(status: .suspectedWatermark, detail: "Fixture: watermark found")
    }
}
