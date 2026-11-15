import Foundation
import Testing
@testable import KeymanCore

private let viduExamples = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Vidu")
private let viduAliases = ["q3-image-to-video", "q3-turbo-image-to-video", "q3-reference-to-video",
    "q3-turbo-reference-to-video", "q3-text-to-video", "q3-turbo-text-to-video",
    "q3-start-end-to-video", "q3-turbo-start-end-to-video"]

private func viduFixture(_ alias: String = "q3-image-to-video") throws -> ProviderProfile {
    var model = try ManagementDocuments.model(Data(contentsOf: viduExamples.appendingPathComponent(alias + ".model.json")))
    var profile = ProviderProfile.fixture(alias: "vidu")
    profile.provider = .customREST
    profile.endpoints = [.init(id: UUID(), alias: "vidu-api", name: "Vidu", baseURL: URL(string: "https://api.vidu.cn")!)]
    profile.authentication = .init(headerName: "Authorization", prefix: "Token", environmentVariable: "VIDU_API_KEY")
    model.watermarkCapability = .init(disposition: .configurable, parameterPath: "watermark", disabledValue: .bool(false),
        evidence: "Official documented contract fixture", contractFingerprint: WatermarkPolicy.fingerprint(profile: profile, model: model))
    profile.models = [model]
    return profile
}

@Test(arguments: viduAliases)
func viduPreparedDocumentsBuildWithCorrectModelAndWatermark(_ alias: String) throws {
    let profile = try viduFixture(alias), model = profile.models[0]
    try ConfigurationValidator.validate(.init(profiles: [profile]))
    let body = try Data(contentsOf: viduExamples.appendingPathComponent(alias + ".request.json"))
    let request = try KeymanRequestBuilder().build(profile: profile, model: model, secret: "fixture-key", body: body)
    let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Token fixture-key")
    #expect(object["model"] as? String == model.modelID)
    #expect(object["watermark"] as? Bool == false)
    #expect(object["audio"] as? Bool == false)
    #expect(model.callTemplate?.taskQuery?.queryIDPath == "id")
    #expect(model.usageGuide?.summary.isEmpty == false)
}

@Test func viduImageSubjectsAndOwnedSubjectsAreAccepted() throws {
    let profile = try viduFixture("q3-reference-to-video"), model = profile.models[0]
    let data = try Data(contentsOf: viduExamples.appendingPathComponent("q3-reference-subjects.request.json"))
    _ = try KeymanRequestBuilder().build(profile: profile, model: model, secret: "", body: data)
    let owned = Data(#"{"prompt":"@actor waves","subjects":[{"name":"actor","server_id":"owned-subject-123"}],"duration":3}"#.utf8)
    _ = try KeymanRequestBuilder().build(profile: profile, model: model, secret: "", body: owned)
}

@Test(arguments: [
    #"{"images":[]}"#, #"{"images":["https://cdn.vidu.cn/a.png","https://cdn.vidu.cn/b.png"]}"#,
    #"{"images":["file:///tmp/photo.png"]}"#, #"{"images":["https://example.com/photo.png"]}"#,
    #"{"images":["data:image/png;base64,invalid"]}"#, #"{"duration":true}"#, #"{"duration":1.5}"#,
    #"{"duration":0}"#, #"{"duration":17}"#, #"{"resolution":"480p"}"#, #"{"audio":"false"}"#,
    #"{"seed":-1}"#, #"{"duraton":5}"#
])
func viduInvalidInputsStopBeforeCredentialsOrNetwork(_ patch: String) async throws {
    let profile = try viduFixture(), transport = ViduFixtureTransport([])
    var body = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: viduExamples.appendingPathComponent("q3-image-to-video.request.json"))) as? [String: Any])
    for (key, value) in try #require(JSONSerialization.jsonObject(with: Data(patch.utf8)) as? [String: Any]) { body[key] = value }
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: InMemoryCredentialStore(), transport: transport)
    do {
        _ = try await caller.call(profileAlias: "vidu", modelAlias: profile.models[0].alias, body: JSONSerialization.data(withJSONObject: body))
        Issue.record("Expected request validation failure")
    } catch KeymanError.invalidRequest { }
    catch { Issue.record("Must fail before missing credential lookup: \(error)") }
    #expect(await transport.requests.isEmpty)
}

@Test(arguments: [
    #"{"model":"viduq3-pro","prompt":"test","images":["https://cdn.vidu.cn/a.png"]}"#,
    #"{"model":"viduq3","prompt":"test","images":["https://cdn.vidu.cn/a.png"],"duration":2}"#,
    #"{"model":"viduq3","prompt":"test","images":["https://cdn.vidu.cn/a.png"],"aspect_ratio":"4:3"}"#,
    #"{"model":"viduq3","prompt":"test","subjects":[{"name":"actor","server_id":"YOUR_SUBJECT_ID"}]}"#,
    #"{"model":"viduq3","prompt":"test","subjects":[{"name":"actor","server_id":"owned-1"},{"name":"actor","server_id":"owned-2"}]}"#,
    #"{"model":"viduq3","prompt":"test","images":["https://cdn.vidu.cn/a.png"],"subjects":[{"name":"actor","server_id":"owned-1"}]}"#,
    #"{"model":"viduq3","prompt":"test","videos":["https://cdn.vidu.cn/a.mp4"]}"#
])
func viduReferenceModeRejectsWrongContract(_ json: String) throws {
    let body = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(throws: KeymanError.self) { try ViduVideoValidation.validate(body, path: "/ent/v2/reference2video") }
}

@Test func viduFramesRequireTwoAndReferenceHasSevenImageLimit() throws {
    let url = "https://cdn.vidu.cn/a.png"
    #expect(throws: KeymanError.self) {
        try ViduVideoValidation.validate(["model": "viduq3-pro", "images": [url]], path: "/ent/v2/start-end2video")
    }
    #expect(throws: KeymanError.self) {
        try ViduVideoValidation.validate(["model": "viduq3", "prompt": "test", "images": Array(repeating: url, count: 8)], path: "/ent/v2/reference2video")
    }
}

@Test func taskQueryIDPathIsOptionalForOldContractsAndBindsNewGuides() throws {
    let query = TaskQueryTemplate(path: "/tasks/{id}")
    let encoded = try JSONEncoder().encode(query)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("queryIDPath"))
    #expect(try JSONDecoder().decode(TaskQueryTemplate.self, from: encoded).queryIDPath == nil)
    var profile = try viduFixture(), model = profile.models[0]
    let before = WatermarkPolicy.fingerprint(profile: profile, model: model)
    model.callTemplate?.taskQuery?.queryIDPath = "task_id"
    #expect(WatermarkPolicy.fingerprint(profile: profile, model: model) != before)
    #expect(throws: KeymanError.self) { try ManagementValidation.template(model.callTemplate!, authentication: profile.authentication) }
    model.callTemplate?.responseFormat = .json
    model.callTemplate?.taskQuery?.queryIDPath = "bad..path"
    #expect(throws: KeymanError.self) { try ManagementValidation.template(model.callTemplate!, authentication: profile.authentication) }
    profile.models[0] = model
}

@Test func viduTaskSubmissionAndQueryUseDifferentIDsAndOnlyOriginalMedia() async throws {
    let profile = try viduFixture(), credentials = InMemoryCredentialStore()
    await credentials.save("fixture-key", for: profile.id)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let downloader = ViduFixtureDownloader()
    let gate = OutputVerifier(root: root, inspector: ViduFixtureInspector(), downloader: downloader)
    let transport = ViduFixtureTransport([
        #"{"task_id":"task-123","state":"created"}"#,
        #"{"id":"task-123","state":"processing"}"#,
        #"{"id":"task-123","state":"success","err_code":"","creations":[{"url":"https://cdn.vidu.cn/original.mp4","watermarked_url":"https://cdn.vidu.cn/watermarked.mp4"}]}"#
    ])
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
        credentialStore: credentials, transport: transport, outputVerifier: gate)
    let submitted = try await caller.call(profileAlias: "vidu", modelAlias: profile.models[0].alias,
        body: Data(contentsOf: viduExamples.appendingPathComponent("q3-image-to-video.request.json")))
    #expect(submitted.task?.id == "task-123" && submitted.task?.status == "created")
    #expect(submitted.verification?.deliverable == false)
    let pending = try await caller.query(profileAlias: "vidu", modelAlias: profile.models[0].alias, taskID: "task-123")
    #expect(pending.task?.terminal == false && pending.generationRequestSent == false)
    let done = try await caller.query(profileAlias: "vidu", modelAlias: profile.models[0].alias, taskID: "task-123")
    #expect(done.task?.succeeded == true && done.generationRequestSent == false)
    #expect(done.verification?.deliverable == true)
    #expect(await downloader.urls.map(\.absoluteString) == ["https://cdn.vidu.cn/original.mp4"])
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "GET", "GET"])
    #expect(requests.dropFirst().allSatisfy { $0.url?.path == "/ent/v2/tasks/task-123/creations" && $0.httpBody == nil })
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Token fixture-key" })
}

@Test(arguments: [
    #"{"id":"other-task","state":"success"}"#,
    #"{"task_id":"task-123","state":"success"}"#,
    #"{"id":"task-123","state":"success","err_code":"service_error"}"#,
    #"{"id":"task-123","state":"success","err_code":123}"#
])
func viduQueryRejectsWrongIdentityAndEmbeddedErrors(_ response: String) async throws {
    let profile = try viduFixture(), credentials = InMemoryCredentialStore()
    await credentials.save("fixture-key", for: profile.id)
    let transport = ViduFixtureTransport([response])
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])), credentialStore: credentials, transport: transport)
    await expectThrowsAsync { try await caller.query(profileAlias: "vidu", modelAlias: profile.models[0].alias, taskID: "task-123") }
    #expect(await transport.requests.map(\.httpMethod) == ["GET"])
}

@Test func viduFailedSubmissionIsTerminalAndKeepsTaskID() throws {
    let profile = try viduFixture()
    let body = Data(#"{"task_id":"task-123","state":"failed","err_code":"content_policy"}"#.utf8)
    try ProviderResponseValidation.validate(body, format: .viduVideo)
    let task = try TaskProgress.submitted(body: body, query: profile.models[0].callTemplate!.taskQuery!, profile: "vidu", model: "q3-image-to-video")
    #expect(task.id == "task-123" && task.terminal && !task.succeeded)
}

private actor ViduFixtureTransport: HTTPTransporting {
    private var responses: [String]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [String]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw KeymanError.networkError("Unexpected fixture request") }
        return .init(statusCode: 200, headers: [:], body: Data(responses.removeFirst().utf8))
    }
}

private actor ViduFixtureDownloader: MediaDownloading {
    private(set) var urls: [URL] = []
    func download(_ url: URL, to directory: URL, name: String) throws -> URL {
        urls.append(url)
        let file = directory.appendingPathComponent(name + ".mp4")
        try Data("mock-media".utf8).write(to: file)
        return file
    }
}

private struct ViduFixtureInspector: MediaInspecting {
    func inspect(_ url: URL) async -> MediaInspection {
        .init(file: url.path, status: .noVisibleMarkDetected, inspectedFrames: 1, detail: "Mock inspection")
    }
}
