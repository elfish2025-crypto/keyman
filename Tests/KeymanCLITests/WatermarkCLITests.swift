import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanCLI

@Test
func preflightReadsNoCredentialAndMakesNoModelCall() async throws {
    let store = InMemoryConfigurationStore(.init(profiles: [visualProfile()]))
    let caller = CountingCaller()
    let app = CLIApplication(configurationStore: store, credentialStore: FailingCredentialStore(),
        modelCaller: caller, commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let result = await app.execute(arguments: ["preflight", "test", "image", "--body-stdin"],
                                   stdin: { Data(#"{"prompt":"cup","watermark":true}"#.utf8) })
    #expect(result.exitCode == 0)
    let object = try JSONSerialization.jsonObject(with: result.stdout) as! [String: Any]
    #expect(object["credentialRead"] as? Bool == false)
    #expect(object["networkRequest"] as? Bool == false)
    #expect((object["body"] as? [String: Any])?["watermark"] as? Bool == false)
    #expect(await caller.count == 0)
}

@Test
func strictPolicyBlocksGenericRunBeforeCredentialRead() async {
    let app = CLIApplication(configurationStore: InMemoryConfigurationStore(.init(profiles: [visualProfile()])),
        credentialStore: FailingCredentialStore(), modelCaller: StubModelCaller(),
        commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let result = await app.execute(arguments: ["run", "test", "--", "irrelevant-command"], stdin: { Data() })
    #expect(result.exitCode == 1)
    #expect(String(decoding: result.stdout, as: UTF8.self).contains("output_policy_blocked"))
    #expect(!String(decoding: result.stdout, as: UTF8.self).contains("keychain_denied"))
}

@Test
func uncheckedRunIsExplicitAndLabelsItsMissingGuarantee() async throws {
    let runner = RecordingRunner()
    let app = CLIApplication(configurationStore: InMemoryConfigurationStore(.init(profiles: [visualProfile()])),
        credentialStore: FixedCredentialStore(), modelCaller: StubModelCaller(),
        commandRunner: runner, legacyImporter: StubLegacyImporter())
    let result = await app.execute(arguments: ["run", "test", "--allow-unchecked-output", "--", "tool"], stdin: { Data() })
    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stderr, as: UTF8.self).contains("未经管理器检查"))
    let environment = await runner.environment
    #expect(environment["ARK_API_KEY"] == "test-credential")
    #expect(environment["KEYMAN_OUTPUT_POLICY"]?.contains("verifyBeforeDelivery") == true)
    #expect(!String(decoding: result.stdout + result.stderr, as: UTF8.self).contains("test-credential"))
}

@Test
func incompleteOutputReturnsReceiptAndNoRetrySignal() async throws {
    var response = CallResponse(statusCode: 200, headers: [:], body: Data(#"{"task_id":"existing-task"}"#.utf8), isAsync: true)
    response.verification = OutputVerification(status: .pending, responseFile: "/tmp/kept-response.json", detail: "Wait for existing task")
    let caller = CountingCaller(response: response)
    let app = CLIApplication(configurationStore: InMemoryConfigurationStore(), credentialStore: FailingCredentialStore(),
        modelCaller: caller, commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let result = await app.execute(arguments: ["call", "test", "image", "--body-stdin"], stdin: { Data("{}".utf8) })
    #expect(result.exitCode == 3)
    let object = try JSONSerialization.jsonObject(with: result.stdout) as! [String: Any]
    #expect(object["ok"] as? Bool == false)
    #expect(object["automaticRetryAllowed"] as? Bool == false)
    #expect((object["providerResponse"] as? [String: String])?["task_id"] == "existing-task")
    #expect(await caller.count == 1)
}

@Test
func oneCallOverrideDoesNotChangePersistentPolicy() async throws {
    let store = InMemoryConfigurationStore()
    let caller = CountingCaller()
    let app = CLIApplication(configurationStore: store, credentialStore: FailingCredentialStore(),
        modelCaller: caller, commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let result = await app.execute(arguments: ["call", "test", "image", "--body-stdin", "--allow-watermark"], stdin: { Data("{}".utf8) })
    #expect(result.exitCode == 0)
    #expect(await caller.policy == .providerDefault)
    #expect(try await store.load().outputPolicy == .noVisibleWatermark)
    #expect(await store.saveCount == 0)
}

@Test
func noSwitchCapabilityCanBeConfiguredWithoutParameterFields() async throws {
    var profile = visualProfile()
    profile.models[0].modelID = "without-switch-v1"
    let store = InMemoryConfigurationStore(.init(profiles: [profile]))
    let app = CLIApplication(configurationStore: store, credentialStore: FailingCredentialStore(),
        modelCaller: StubModelCaller(), commandRunner: StubCommandRunner(), legacyImporter: StubLegacyImporter())
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(#"{"disposition":"none","evidence":"Model documentation and verified output"}"#.utf8).write(to: file)
    let saved = await app.execute(arguments: ["watermark-config", "test", "image", "--file", file.path], stdin: { Data() })
    #expect(saved.exitCode == 0)
    let result = await app.execute(arguments: ["preflight", "test", "image", "--body-stdin"], stdin: { Data(#"{"prompt":"cup"}"#.utf8) })
    #expect(result.exitCode == 0)
    let object = try JSONSerialization.jsonObject(with: result.stdout) as! [String: Any]
    #expect((object["body"] as? [String: Any])?["watermark"] == nil)
}

private func visualProfile() -> ProviderProfile {
    let model = ModelRecord(id: UUID(), alias: "image", name: "Test model", modelID: "doubao-seedream-5-0-pro-260628",
        modality: .image, status: .declared,
        callTemplate: .init(endpointAlias: "default", method: .post, path: "/images/generations",
            modelIDBodyField: "model", staticHeaders: [:], requestFields: ["prompt"], isAsync: false),
        sourceFile: nil, lastVerifiedAt: nil)
    return ProviderProfile(id: UUID(), alias: "test", name: "Test", provider: .volcengineArk,
        project: nil, region: nil, workspaceName: nil, workspaceID: nil,
        endpoints: [.init(id: UUID(), alias: "default", name: "Ark", baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!)],
        authentication: .init(headerName: "Authorization", prefix: "Bearer", environmentVariable: "ARK_API_KEY"),
        notes: nil, sourceFiles: [], models: [model], lastTestedAt: nil, lastTestSucceeded: nil)
}

private actor CountingCaller: ModelCalling {
    private(set) var count = 0
    private(set) var policy: OutputPolicy?
    let response: CallResponse
    init(response: CallResponse = .init(statusCode: 200, headers: [:], body: Data("{}".utf8), isAsync: false)) { self.response = response }
    func call(profileAlias: String, modelAlias: String, body: Data, policyOverride: OutputPolicy?) async throws -> CallResponse {
        count += 1; policy = policyOverride; return response
    }
}

private struct FixedCredentialStore: CredentialStoring {
    func load(for profileID: UUID) async throws -> String { "test-credential" }
    func maskedSuffix(for profileID: UUID) async throws -> String { "tial" }
    func save(_ secret: String, for profileID: UUID) async throws {}
    func delete(for profileID: UUID) async throws {}
}

private actor RecordingRunner: CommandRunning {
    private(set) var environment: [String: String] = [:]
    func run(command: [String], additionalEnvironment: [String: String]) async throws -> CommandResult {
        environment = additionalEnvironment
        return .init(exitCode: 0, stdout: Data(), stderr: Data())
    }
}
