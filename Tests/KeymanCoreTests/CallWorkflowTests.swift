import Foundation
import Testing
@testable import KeymanCore

private func speechProfile() -> ProviderProfile {
    var profile = ProviderProfile.fixture(alias: "speech")
    profile.provider = .customREST
    profile.authentication = .init(headerName: "X-Api-Key", prefix: "", environmentVariable: "SPEECH_KEY")
    profile.models = [.fixture(alias: "tts", modelID: nil, status: .declared,
        callTemplate: .init(endpointAlias: "default", method: .post, path: "/api/v3/tts/unidirectional/sse",
            modelIDBodyField: nil, staticHeaders: ["X-Api-Resource-Id": "seed-tts-2.0"], requestFields: [],
            isAsync: false, responseFormat: .volcengineTTSSSE, uuidHeaders: ["X-Api-Request-Id"],
            requiredBodyFields: ["req_params.text", "req_params.speaker"]))]
    profile.models[0].modality = .speech
    return profile
}

private let speechBody = Data(#"{"req_params":{"text":"你好","speaker":"test-speaker","audio_params":{"format":"mp3","sample_rate":24000}}}"#.utf8)
private let goodSSE = Data("event: 352\r\ndata: {\"code\":0,\"data\":\"YWJj\"}\r\n\r\n: heartbeat\r\nevent: 352\r\ndata: {\"code\":0,\"data\":\"ZGVm\"}\r\n\r\nevent: 152\r\ndata: {\"code\":20000000,\"data\":null,\"usage\":{\"text_words\":2}}\r\n\r\n".utf8)

@Test func serviceWithoutModelIDUsesCorrectAuthAndFreshUUID() throws {
    let profile = speechProfile(), model = profile.models[0]
    try ConfigurationValidator.validate(.init(profiles: [profile]))
    let builder = KeymanRequestBuilder()
    let a = try builder.build(profile: profile, model: model, secret: "test-key", body: speechBody)
    let b = try builder.build(profile: profile, model: model, secret: "test-key", body: speechBody)
    #expect(a.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
    #expect(a.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(a.value(forHTTPHeaderField: "X-Api-Request-Id") != b.value(forHTTPHeaderField: "X-Api-Request-Id"))
    #expect(UUID(uuidString: try #require(a.value(forHTTPHeaderField: "X-Api-Request-Id"))) != nil)
    #expect((try JSONSerialization.jsonObject(with: a.httpBody!) as? [String: Any])?["model"] == nil)
}

@Test(arguments: ["", "REPLACE_WITH_OWNED_SPEAKER_ID", "YOUR_VOICE_ID", "S_********", "<speaker-id>"])
func placeholdersStopBeforeCredentialsOrNetwork(_ speaker: String) async throws {
    let profile = speechProfile()
    let transport = WorkflowTransport([])
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: InMemoryCredentialStore(), transport: transport)
    let body = try JSONSerialization.data(withJSONObject: ["req_params": ["text": "你好", "speaker": speaker]])
    do { _ = try await caller.call(profileAlias: "speech", modelAlias: "tts", body: body); Issue.record("Expected missing input") }
    catch KeymanError.invalidRequest { }
    catch { Issue.record("Should fail before reading missing key: \(error)") }
    #expect(await transport.requests.isEmpty)
}

@Test func sseAudioIsAssembledAndSavedWithoutBase64InOutput() async throws {
    let profile = speechProfile()
    let credentials = InMemoryCredentialStore(); await credentials.save("test-secret", for: profile.id)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = WorkflowTransport([.init(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: goodSSE)])
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: credentials, transport: transport, audioStore: .init(root: root))
    let response = try await caller.call(profileAlias: "speech", modelAlias: "tts", body: speechBody)
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let file = try #require(object["audioFile"] as? String)
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data("abcdef".utf8))
    #expect(object["streamComplete"] as? Bool == true)
    #expect(object["contentQualityVerified"] as? Bool == false)
    #expect(!String(decoding: response.body, as: UTF8.self).contains("YWJj"))
    let permissions = try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test(arguments: [
    "data: {\"code\":0,\"data\":\"YWJj\"}\n\n",
    "data: {\"code\":20000000}\n\n",
    "data: {\"code\":0,\"data\":\"not base64\"}\n\ndata: {\"code\":20000000}\n\n",
    "event: 153\ndata: {\"code\":0}\n\n",
    "event: 151\ndata: {\"code\":20000000}\n\n",
    "data: {\"code\":45000000,\"message\":\"permission denied\"}\n\n",
    "data: {\"code\":0,\"data\":\"YWJj\"}\n\ndata: {\"code\":20000000}\n\ndata: {\"code\":55000000}\n\n",
    "data: {\"code\":0\n\n",
    "{\"code\":45000000,\"message\":\"HTTP 200 error\"}"
])
func incompleteOrFailedSpeechNeverProducesSuccess(_ text: String) throws {
    #expect(throws: KeymanError.self) { try VolcengineSSEAudio.decode(Data(text.utf8)) }
}

@Test func dynamicHeadersCannotOverrideCredentialsOrDuplicateHeaders() throws {
    let profile = speechProfile()
    for name in ["X-Api-Key", "Authorization", "Host", "X-Api-Resource-Id", "x-api-resource-id"] {
        var template = profile.models[0].callTemplate!
        template.uuidHeaders = [name]
        #expect(throws: KeymanError.self) { try ManagementValidation.template(template, authentication: profile.authentication) }
    }
}

@Test func legacyTemplateDecodesAndWorkflowChangesInvalidateGuideBinding() throws {
    var profile = speechProfile()
    let old = Data(#"{"endpointAlias":"default","method":"POST","path":"/tts","staticHeaders":{},"requestFields":[],"isAsync":false}"#.utf8)
    let template = try JSONDecoder().decode(CallTemplate.self, from: old)
    #expect(template.responseFormat == nil && template.taskQuery == nil)
    let fingerprint = WatermarkPolicy.fingerprint(profile: profile, model: profile.models[0])
    profile.models[0].callTemplate?.uuidHeaders = nil
    #expect(WatermarkPolicy.fingerprint(profile: profile, model: profile.models[0]) != fingerprint)
    #expect(try JSONDecoder().decode(CallTemplate.self, from: JSONEncoder().encode(profile.models[0].callTemplate)) == profile.models[0].callTemplate)
}

@Test func queryOnlyUsesGETAndInspectsSuccessfulTaskOnce() async throws {
    var model = ModelRecord.seedreamFixture
    model.alias = "video"; model.modality = .video
    model.callTemplate?.path = "/tasks"; model.callTemplate?.isAsync = true
    model.callTemplate?.taskQuery = .init(path: "/tasks/{id}")
    var profile = ProviderProfile.fixture(alias: "video", models: [model])
    profile.models[0].watermarkCapability = .init(disposition: .none, evidence: "test fixture", contractFingerprint: WatermarkPolicy.fingerprint(profile: profile, model: model))
    let transport = WorkflowTransport(["{\"id\":\"task-1\"}", "{\"id\":\"task-1\",\"status\":\"running\"}", "{\"id\":\"task-1\",\"status\":\"succeeded\"}"].map {
        .init(statusCode: 200, headers: [:], body: Data($0.utf8))
    })
    let gate = WorkflowGate(), credentials = InMemoryCredentialStore()
    await credentials.save("test-secret", for: profile.id)
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: credentials, transport: transport, outputVerifier: gate)
    let submitted = try await caller.call(profileAlias: "video", modelAlias: "video", body: Data("{}".utf8))
    #expect(submitted.task?.id == "task-1")
    let running = try await caller.query(profileAlias: "video", modelAlias: "video", taskID: "task-1")
    #expect(running.task?.terminal == false && running.generationRequestSent == false)
    let done = try await caller.query(profileAlias: "video", modelAlias: "video", taskID: "task-1")
    #expect(done.task?.succeeded == true)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "GET"])
    #expect(requests.dropFirst().allSatisfy { $0.httpBody == nil && $0.url?.path.hasSuffix("/tasks/task-1") == true })
    #expect(await gate.calls == 2) // Submission receipt plus completed output; never the running poll.
}

@Test(arguments: ["../x", "https://evil.example/key", "a?key", "a#key", "a%2Fx", "", "x\nHeader"])
func unsafeTaskIDsStopBeforeReadingCredential(_ id: String) async throws {
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(), credentialStore: InMemoryCredentialStore())
    do { _ = try await caller.query(profileAlias: "missing", modelAlias: "missing", taskID: id); Issue.record("Expected invalid ID") }
    catch KeymanError.invalidRequest { }
    catch { Issue.record("ID should be rejected first: \(error)") }
}

@Test(arguments: ["{\"code\":\"InvalidParameter\",\"message\":\"bad input\"}", "{\"error\":{\"message\":\"bad input\"}}", "<html>gateway error</html>"])
func http200ErrorIsNotProviderSuccess(_ body: String) throws {
    #expect(throws: KeymanError.self) { try ProviderResponseValidation.validate(Data(body.utf8), format: .json) }
}

@Test(arguments: [0, 1, 3]) func voiceDesignMustBeReadyBeforeSynthesis(_ status: Int) throws {
    #expect(throws: KeymanError.self) {
        try ProviderResponseValidation.validate(Data("{\"speaker_id\":\"S_owned\",\"status\":\(status)}".utf8), format: .volcengineVoiceDesign)
    }
}

@Test func authenticationDiagnosticsPreserveProviderCodeAndRedactEchoedSecret() async throws {
    let profile = speechProfile(), credentials = InMemoryCredentialStore()
    await credentials.save("test-secret", for: profile.id)
    let transport = WorkflowTransport([.init(statusCode: 401, headers: [:], body: Data(#"{"code":"InvalidApiKey","message":"test-secret invalid"}"#.utf8))])
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: credentials, transport: transport)
    do { _ = try await caller.call(profileAlias: "speech", modelAlias: "tts", body: speechBody); Issue.record("Expected auth error") }
    catch KeymanError.authenticationRejected(let status, let detail) {
        #expect(status == 401)
        #expect(detail.contains("InvalidApiKey") && detail.contains("[REDACTED]") && !detail.contains("test-secret"))
    }
}

@Test func modelMoveCollisionLeavesBothAccountsUnchanged() async throws {
    let source = speechProfile()
    var destination = source; destination.alias = "destination"
    destination = destination.withNewID()
    let before = KeymanConfiguration(profiles: [source, destination])
    let configurations = InMemoryConfigurationStore(before)
    let manager = KeymanManager(configurationStore: configurations, credentialStore: InMemoryCredentialStore())
    await expectThrowsAsync { try await manager.moveModel("tts", from: "speech", to: "destination", patch: Data("{}".utf8)) }
    #expect(try await configurations.load() == before)
    #expect(await configurations.saveCount == 0)
}

private actor WorkflowTransport: HTTPTransporting {
    private var responses: [HTTPResponse]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw KeymanError.networkError("Unexpected extra request") }
        return responses.removeFirst()
    }
}

@Test func modelMoveIsAtomicPreservesIdentityAndNeverMovesKeys() async throws {
    let source = speechProfile()
    var destination = ProviderProfile.fixture(alias: "destination")
    destination.provider = .customREST
    destination.authentication = source.authentication
    let configurations = InMemoryConfigurationStore(.init(profiles: [source, destination]))
    let credentials = InMemoryCredentialStore()
    await credentials.save("source-key", for: source.id); await credentials.save("destination-key", for: destination.id)
    let manager = KeymanManager(configurationStore: configurations, credentialStore: credentials)
    let patch = Data("{}".utf8)
    _ = try await manager.moveModel("tts", from: "speech", to: "destination", patch: patch, dryRun: true)
    #expect(try await configurations.load().profiles[0].models.count == 1)
    _ = try await manager.moveModel("tts", from: "speech", to: "destination", patch: patch)
    let updated = try await configurations.load()
    #expect(updated.profiles[0].models.isEmpty)
    #expect(updated.profiles[1].models.first?.id == source.models[0].id)
    #expect(try await credentials.load(for: source.id) == "source-key")
    #expect(try await credentials.load(for: destination.id) == "destination-key")
    #expect(await configurations.saveCount == 1)
}

private actor WorkflowGate: OutputVerifying {
    private(set) var calls = 0
    func verify(body: Data, model: ModelRecord, profileAlias: String) async -> OutputVerification {
        calls += 1
        return .init(status: .pending, detail: "Synthetic output inspection")
    }
}
