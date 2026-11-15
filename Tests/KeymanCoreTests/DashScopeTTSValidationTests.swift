import Foundation
import Testing
@testable import KeymanCore

private func completeAudio(_ url: String = "http://audio.example/result.wav?signature=test") -> [String: Any] {
    ["status_code": 200, "code": "", "message": "", "output": [
        "finish_reason": "stop", "audio": ["url": url, "data": ""]
    ]]
}

@Test(arguments: ["http://audio.example/result.wav?signature=test", "https://audio.example/result.wav"])
func documentedDashScopeSuccessAcceptsEmptyCodeAndSignedAudioURL(_ url: String) throws {
    let body = try JSONSerialization.data(withJSONObject: completeAudio(url))
    try ProviderResponseValidation.validate(body, format: .json)
    try ProviderResponseValidation.validate(body, format: .dashscopeTTSAudio)
}

@Test(arguments: ["", "/audio.wav", "file:///private/audio.wav", "https://user:pass@audio.example/file.wav", "https://", "https://audio.example/a b.wav"])
func dashScopeSuccessRequiresUsableAudioLocation(_ url: String) throws {
    let body = try JSONSerialization.data(withJSONObject: completeAudio(url))
    #expect(throws: KeymanError.self) { try ProviderResponseValidation.validate(body, format: .dashscopeTTSAudio) }
}

@Test(arguments: [#"{}"#, #"{"output":{"finish_reason":"stop","audio":{}}}"#,
    #"{"output":{"finish_reason":null,"audio":{"url":"https://audio.example/file.wav"}}}"#,
    #"{"output":{"finish_reason":"null","audio":{"data":"YXVkaW8="}}}"#])
func incompleteDashScopeResponsesAreNotSuccessfulSynthesis(_ text: String) throws {
    #expect(throws: KeymanError.self) {
        try ProviderResponseValidation.validate(Data(text.utf8), format: .dashscopeTTSAudio)
    }
}

@Test(arguments: [400, 401, 403, 429, 500])
func embeddedProviderFailureCannotHideBehindHTTP200AndEmptyCode(_ status: Int) throws {
    var response = completeAudio(); response["status_code"] = status
    let body = try JSONSerialization.data(withJSONObject: response)
    #expect(throws: KeymanError.self) { try ProviderResponseValidation.validate(body, format: .json) }
}

@Test func explicitErrorStillFailsWithOtherwiseCompleteAudio() throws {
    var response = completeAudio(); response["code"] = "AccessDenied.Unpurchased"
    #expect(throws: KeymanError.self) {
        try ProviderResponseValidation.validate(JSONSerialization.data(withJSONObject: response), format: .dashscopeTTSAudio)
    }
}

@Test func ssmlAndProseAreNotMistakenForResourcePlaceholders() throws {
    for text in ["<speak>你好，<break time=\"300ms\"/>欢迎。</speak>", "示例中的 REPLACE_WITH_VOICE 是占位符。"] {
        try RequestBodyValidation.validate(["input": ["text": text, "voice": "longanyang"]], fields: ["input.text", "input.voice"])
    }
    for voice in ["REPLACE_WITH_DESIGNED_VOICE", "YOUR_VOICE_ID", "S_********", "<speaker-id>"] {
        #expect(throws: KeymanError.self) {
            try RequestBodyValidation.validate(["input": ["voice": voice]], fields: ["input.voice"])
        }
    }
}

@Test func completeAudioModeCannotBeConfiguredAsStreaming() throws {
    let auth = AuthenticationConfiguration(headerName: "Authorization", prefix: "Bearer", environmentVariable: "TEST_KEY")
    var template = CallTemplate(endpointAlias: "default", method: .post, path: "/tts",
        modelIDBodyField: "model", staticHeaders: [:], requestFields: [], isAsync: false, responseFormat: .dashscopeTTSAudio)
    try ManagementValidation.template(template, authentication: auth)
    template.staticHeaders["x-dashscope-sse"] = "enable"
    #expect(throws: KeymanError.self) { try ManagementValidation.template(template, authentication: auth) }
    template.staticHeaders = [:]; template.uuidHeaders = ["X-DashScope-SSE"]
    #expect(throws: KeymanError.self) { try ManagementValidation.template(template, authentication: auth) }
    template.uuidHeaders = nil; template.isAsync = true
    #expect(throws: KeymanError.self) { try ManagementValidation.template(template, authentication: auth) }
}

@Test func modelCallerEnforcesAudioCompletionAfterOneRequest() async throws {
    var model = ModelRecord.fixture(alias: "tts", modelID: "qwen3-tts-flash-2025-11-27", status: .declared,
        callTemplate: .init(endpointAlias: "default", method: .post, path: "/tts", modelIDBodyField: "model",
            staticHeaders: [:], requestFields: [], isAsync: false, responseFormat: .dashscopeTTSAudio,
            requiredBodyFields: ["input.text", "input.voice"]))
    model.modality = .speech
    let profile = ProviderProfile.fixture(alias: "speech", models: [model])
    let credentials = InMemoryCredentialStore(); await credentials.save("test-secret", for: profile.id)
    let transport = IncompleteAudioTransport()
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: credentials, transport: transport)
    do {
        _ = try await caller.call(profileAlias: "speech", modelAlias: "tts", body: Data(#"{"input":{"text":"你好","voice":"Cherry"}}"#.utf8))
        Issue.record("Incomplete audio should not succeed")
    } catch KeymanError.providerError(_, let message) {
        #expect(message.contains("不要自动重新生成"))
    }
    #expect(await transport.count == 1)
}

private actor IncompleteAudioTransport: HTTPTransporting {
    private(set) var count = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        count += 1
        return .init(statusCode: 200, headers: [:], body: Data(#"{"code":"","output":{"finish_reason":"stop","audio":{}}}"#.utf8))
    }
}
