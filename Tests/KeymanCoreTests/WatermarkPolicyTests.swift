import Foundation
import Testing
@testable import KeymanCore

@Test(arguments: [#"{"prompt":"cup"}"#, #"{"prompt":"cup","watermark":true}"#])
func watermarkDefaultClosesKnownSwitch(body: String) throws {
    let request = try KeymanRequestBuilder().build(profile: .fixture(alias: "test"),
        model: .seedreamFixture, secret: "test-secret", body: Data(body.utf8))
    let object = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    #expect(object["watermark"] as? Bool == false)
    #expect(object["prompt"] as? String == "cup")
}

@Test
func nestedSwitchPreservesOtherSettings() throws {
    let profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.modelID = "different-v1"
    model.watermarkCapability = capability(.configurable, profile, model, path: "parameters.logo.mode", value: .string("off"))
    let result = try WatermarkPolicy.prepare(profile: profile, model: model,
        body: Data(#"{"parameters":{"seed":42,"logo":{"mode":"on","position":"right"}}}"#.utf8), policy: .noVisibleWatermark)
    let object = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
    let parameters = object["parameters"] as! [String: Any]
    #expect(parameters["seed"] as? Int == 42)
    #expect((parameters["logo"] as? [String: String]) == ["mode": "off", "position": "right"])
}

@Test
func noSwitchModelReceivesNoInventedParameter() throws {
    let profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.modelID = "no-switch-v1"
    model.watermarkCapability = capability(.none, profile, model)
    let request = try KeymanRequestBuilder().build(profile: profile, model: model,
        secret: "unit-test", body: Data(#"{"prompt":"cup","size":"2K"}"#.utf8))
    let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    #expect(Set(object.keys) == ["prompt", "size", "model"])
    #expect(object["model"] as? String == "no-switch-v1")
}

@Test(arguments: [WatermarkDisposition.unknown, .unavoidable])
func blockedModelsNeverReadKeyOrSendRequest(disposition: WatermarkDisposition) async throws {
    var profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.modelID = "unverified-v1"
    model.watermarkCapability = capability(disposition, profile, model)
    profile.models = [model]
    let credentials = CountingCredentialStore()
    let transport = RecordingHTTPTransport(response: .init(statusCode: 200, headers: [:], body: Data("{}".utf8)))
    let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])),
                            credentialStore: credentials, transport: transport)
    do {
        _ = try await caller.call(profileAlias: profile.alias, modelAlias: model.alias, body: Data("{}".utf8))
        Issue.record("Policy must block")
    } catch KeymanError.outputPolicyBlocked {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(await credentials.loads == 0)
    #expect(await transport.lastRequest == nil)
}

@Test
func absenceOfSwitchInformationIsUnknownRatherThanNone() {
    let profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.modelID = "unknown-v1"
    model.callTemplate?.requestFields = ["prompt"]
    #expect(WatermarkPolicy.capability(profile: profile, model: model) == nil)
    expectThrows { try WatermarkPolicy.prepare(profile: profile, model: model, body: Data("{}".utf8), policy: .noVisibleWatermark) }
}

@Test(arguments: ["model", "endpoint", "path", "method", "header"])
func changedContractInvalidatesNoSwitchEvidence(change: String) {
    var profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.watermarkCapability = capability(.none, profile, model)
    switch change {
    case "model": model.modelID = "new-version"
    case "endpoint": profile.endpoints[0].baseURL = URL(string: "https://other.example/api")!
    case "path": model.callTemplate?.path = "/new/images"
    case "method": model.callTemplate?.method = .put
    default: model.callTemplate?.staticHeaders["API-Version"] = "new"
    }
    #expect(WatermarkPolicy.capability(profile: profile, model: model) == nil)
}

@Test
func explicitOverrideAndNonVisualModelsKeepOriginalBody() throws {
    let profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.modelID = "unknown-v1"
    let body = Data(#"{"watermark":true,"prompt":"hello"}"#.utf8)
    let allowed = try WatermarkPolicy.prepare(profile: profile, model: model, body: body, policy: .providerDefault)
    #expect((try JSONSerialization.jsonObject(with: allowed.body) as! [String: Any])["watermark"] as? Bool == true)
    #expect(!allowed.requiresInspection)
    model.modality = .text
    let text = try WatermarkPolicy.prepare(profile: profile, model: model, body: Data(#"{"prompt":"hello"}"#.utf8), policy: .noVisibleWatermark)
    #expect((try JSONSerialization.jsonObject(with: text.body) as! [String: Any])["watermark"] == nil)
    #expect(!text.requiresInspection)
}

@Test
func noSwitchCapabilityRejectsAParameterAndMissingEvidence() {
    let profile = ProviderProfile.fixture(alias: "test")
    var record = capability(.none, profile, .seedreamFixture, path: "watermark", value: .bool(false))
    expectThrows { try WatermarkPolicy.validate(record) }
    record.parameterPath = nil; record.disabledValue = nil; record.evidence = " "
    expectThrows { try WatermarkPolicy.validate(record) }
}

@Test
func nestedScalarCollisionFailsBeforeRequest() {
    let profile = ProviderProfile.fixture(alias: "test")
    var model = ModelRecord.seedreamFixture
    model.watermarkCapability = capability(.configurable, profile, model, path: "parameters.watermark", value: .bool(false))
    expectThrows { try WatermarkPolicy.prepare(profile: profile, model: model,
        body: Data(#"{"parameters":true}"#.utf8), policy: .noVisibleWatermark) }
}

@Test
func oldConfigurationMigratesWithPrivateBackup() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("config.json")
    let old = Data(#"{"schemaVersion":1,"profiles":[]}"#.utf8)
    try old.write(to: file)
    let store = FileConfigurationStore(fileURL: file)
    let config = try await store.load()
    #expect(config.outputPolicy == .noVisibleWatermark)
    #expect(config.schemaVersion == KeymanConfiguration.currentSchemaVersion)
    #expect(try Data(contentsOf: file) == old) // Reading never mutates the old installation's data.
    try await store.save(config)
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
    let backup = try #require(backups.first)
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: backup) == old)
    #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try await store.load() == config)
}

private func capability(_ disposition: WatermarkDisposition, _ profile: ProviderProfile, _ model: ModelRecord,
                        path: String? = nil, value: JSONScalar? = nil) -> WatermarkCapability {
    WatermarkCapability(disposition: disposition, parameterPath: path, disabledValue: value,
        evidence: "Verified test contract", contractFingerprint: WatermarkPolicy.fingerprint(profile: profile, model: model))
}

private actor CountingCredentialStore: CredentialStoring {
    private(set) var loads = 0
    func load(for profileID: UUID) throws -> String { loads += 1; throw KeymanError.keyMissing }
    func save(_ secret: String, for profileID: UUID) {}
    func delete(for profileID: UUID) {}
    func maskedSuffix(for profileID: UUID) throws -> String { throw KeymanError.keyMissing }
}
