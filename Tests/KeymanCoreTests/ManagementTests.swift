import Foundation
import Testing
@testable import KeymanCore

@Suite
struct ManagementTests {
    @Test
    func accountRenameRetainsIdentityCredentialModelsAndImportLink() async throws {
        let config = InMemoryConfigurationStore()
        let keys = InMemoryCredentialStore()
        let manager = KeymanManager(configurationStore: config, credentialStore: keys)
        let source = ProviderProfile.fixture(alias: "source-account")
        try await manager.saveProfile(source, secret: "synthetic-original-key")
        try await manager.saveModel(.seedreamFixture, profileAlias: source.alias)
        let original = try await manager.profile(source.alias)
        let patch = try ManagementDocuments.profile(Data(#"{"alias":"renamed","name":"Edited","notes":"Keep this note"}"#.utf8), existing: original)
        try await manager.saveProfile(patch, original: original)
        let renamed = try await manager.profile("renamed")
        #expect(renamed.id == source.id)
        #expect(renamed.models == original.models)
        #expect(renamed.previousAliases == [source.alias])
        #expect(try await keys.load(for: renamed.id) == "synthetic-original-key")
        let preview = ImportPreview(profiles: [.init(profile: source.withNewID(), secret: "synthetic-original-key", secretSuffix: "-key")])
        let report = try await LegacyImportCoordinator(configurationStore: config, credentialStore: keys).commit(preview)
        #expect(report.credentials[0].state == .matching)
        #expect(report.credentials[0].storedAlias == "renamed")
        #expect(try await config.load().profiles == [renamed])
        await expectThrowsAsync { try await manager.saveProfile(.fixture(alias: source.alias)) }
        try await manager.setProfileEnabled("renamed", enabled: false)
        #expect(try await manager.profile("renamed").isEnabled == false)
        #expect(try await keys.load(for: renamed.id) == "synthetic-original-key")
        try await manager.deleteModel(ModelRecord.seedreamFixture.alias, profileAlias: "renamed")
        try await manager.deleteEndpoint("default", profileAlias: "renamed")
        #expect(try await manager.profile("renamed").endpoints.isEmpty)
        try await manager.deleteProfile("renamed")
        #expect(try await config.load().profiles.isEmpty)
        await expectThrowsAsync { try await keys.load(for: renamed.id) }
        #expect(try await config.load().outputPolicy == .noVisibleWatermark)
    }

    @Test
    func dryRunsAndMetadataChangesDoNotAccessKeychain() async throws {
        let config = InMemoryConfigurationStore()
        let keys = ManagementCredentialSpy()
        let manager = KeymanManager(configurationStore: config, credentialStore: keys)
        let draft = ProviderProfile.fixture(alias: "draft")
        let dryRun = try await manager.saveProfile(draft, secret: "synthetic-secret", dryRun: true)
        #expect(dryRun.dryRun && !dryRun.networkRequest)
        #expect(try await config.load().profiles.isEmpty)
        try await manager.saveProfile(draft)
        try await manager.saveModel(.seedreamFixture, profileAlias: draft.alias)
        try await manager.setProfileEnabled(draft.alias, enabled: false)
        try await manager.setCredential(draft.alias, secret: "replacement", dryRun: true)
        try await manager.deleteProfile(draft.alias, dryRun: true)
        #expect(await keys.operations == 0)
        #expect(try await config.load().profiles.count == 1)
    }

    @Test
    func endpointRenameKeepsEvidenceButContractChangeInvalidatesIt() async throws {
        var profile = ProviderProfile.fixture(alias: "account", models: [.seedreamFixture])
        profile.models[0].status = .verified
        profile.models[0].lastVerifiedAt = Date(timeIntervalSince1970: 1_000)
        profile.models[0].watermarkCapability = WatermarkPolicy.capability(profile: profile, model: profile.models[0])
        let config = InMemoryConfigurationStore(.init(profiles: [profile]))
        let manager = KeymanManager(configurationStore: config, credentialStore: ManagementCredentialSpy())
        var endpoint = profile.endpoints[0]; endpoint.alias = "renamed-interface"
        try await manager.saveEndpoint(endpoint, profileAlias: profile.alias, originalAlias: "default")
        let renamed = try await manager.profile(profile.alias)
        #expect(renamed.models[0].callTemplate?.endpointAlias == endpoint.alias)
        #expect(renamed.models[0].status == .verified)
        #expect(renamed.models[0].watermarkCapability == profile.models[0].watermarkCapability)
        await expectThrowsAsync { try await manager.deleteEndpoint(endpoint.alias, profileAlias: profile.alias) }
        endpoint.baseURL = URL(string: "https://changed.example.invalid/api")!
        try await manager.saveEndpoint(endpoint, profileAlias: profile.alias, originalAlias: endpoint.alias)
        let changed = try await manager.profile(profile.alias)
        #expect(changed.models[0].status == .declared)
        #expect(changed.models[0].lastVerifiedAt == nil)
        #expect(changed.models[0].watermarkCapability?.disposition == .unknown)
        expectThrows { try KeymanRequestBuilder().build(profile: changed, model: changed.models[0], secret: "", body: Data("{}".utf8)) }
    }

    @Test
    func authenticationChangeAndKeyChangeClearVerification() async throws {
        var profile = ProviderProfile.fixture(alias: "account", models: [.seedreamFixture])
        profile.models[0].status = .verified
        profile.lastTestSucceeded = true
        let config = InMemoryConfigurationStore(.init(profiles: [profile]))
        let keys = InMemoryCredentialStore()
        let manager = KeymanManager(configurationStore: config, credentialStore: keys)
        var edited = profile; edited.authentication.prefix = "Token"
        try await manager.saveProfile(edited, original: profile)
        #expect(try await manager.profile(profile.alias).models[0].watermarkCapability?.disposition == .unknown)
        #expect(try await manager.profile(profile.alias).lastTestSucceeded == nil)
        try await manager.setCredential(profile.alias, secret: "  synthetic-key\n")
        #expect(try await keys.load(for: profile.id) == "synthetic-key")
        #expect(try await manager.profile(profile.alias).credentialRevision == 1)
        try await manager.setCredential(profile.alias, secret: nil)
        #expect(try await manager.profile(profile.alias).models.count == 1)
        #expect(try await manager.profile(profile.alias).credentialRevision == 2)
        #expect(try await manager.credentialStatus(profile.alias).configured == false)
    }

    @Test
    func enablingCandidateNeverPromotesItAndManualVerificationIsRejected() async throws {
        var profile = ProviderProfile.fixture(alias: "account", models: [.seedreamFixture])
        profile.models[0].status = .candidate; profile.models[0].isEnabled = false
        let config = InMemoryConfigurationStore(.init(profiles: [profile]))
        let manager = KeymanManager(configurationStore: config, credentialStore: ManagementCredentialSpy())
        try await manager.setModelEnabled(profile.models[0].alias, profileAlias: profile.alias, enabled: true)
        let enabled = try await manager.profile(profile.alias)
        #expect(enabled.models[0].status == .candidate)
        #expect(enabled.models[0].isEnabled)
        var forged = enabled.models[0]; forged.status = .verified
        await expectThrowsAsync { try await manager.saveModel(forged, profileAlias: profile.alias, original: enabled.models[0]) }
        #expect(try await manager.profile(profile.alias) == enabled)
    }

    @Test(arguments: ["profile", "model", "candidate"])
    func disabledOrCandidateItemsCannotReadCredentialOrSendRequest(kind: String) async throws {
        var profile = ProviderProfile.fixture(alias: "account", models: [.seedreamFixture])
        if kind == "profile" { profile.isEnabled = false }
        if kind == "model" { profile.models[0].isEnabled = false }
        if kind == "candidate" { profile.models[0].status = .candidate }
        let keys = ManagementCredentialSpy()
        let transport = RecordingHTTPTransport(response: .init(statusCode: 200, headers: [:], body: Data("{}".utf8)))
        let caller = ModelCaller(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])), credentialStore: keys, transport: transport)
        await expectThrowsAsync { try await caller.call(profileAlias: profile.alias, modelAlias: profile.models[0].alias, body: Data("{}".utf8)) }
        #expect(await keys.operations == 0)
        #expect(await transport.lastRequest == nil)
    }

    @Test
    func staleEditFailsAndUnrelatedAccountAddedElsewhereSurvives() async throws {
        let original = ProviderProfile.fixture(alias: "first")
        let added = ProviderProfile.fixture(alias: "second")
        let config = InMemoryConfigurationStore(.init(profiles: [original]))
        let manager = KeymanManager(configurationStore: config, credentialStore: ManagementCredentialSpy())
        try await manager.saveProfile(added)
        var edited = original; edited.name = "User edit"
        try await manager.saveProfile(edited, original: original)
        #expect(try await config.load().profiles == [edited, added])
        edited.notes = "Stale edit"
        do {
            try await manager.saveProfile(edited, original: original)
            Issue.record("Must reject stale edit")
        } catch KeymanError.configurationChanged {}
        #expect(try await manager.profile(original.alias).notes == nil)
    }

    @Test(arguments: ["replace", "clear", "delete", "create"])
    func configurationFailureRestoresCredential(operation: String) async throws {
        let profile = ProviderProfile.fixture(alias: "account")
        let original = KeymanConfiguration(profiles: operation == "create" ? [] : [profile])
        let config = ManagementFailingStore(original)
        let keys = InMemoryCredentialStore()
        if operation != "create" { await keys.save("old-synthetic-secret", for: profile.id) }
        let manager = KeymanManager(configurationStore: config, credentialStore: keys)
        await expectThrowsAsync {
            switch operation {
            case "create": try await manager.saveProfile(profile, secret: "new-synthetic-secret")
            case "delete": try await manager.deleteProfile(profile.alias)
            default: try await manager.setCredential(profile.alias, secret: operation == "clear" ? nil : "new-synthetic-secret")
            }
        }
        #expect(try await config.load() == original)
        if operation == "create" { await expectThrowsAsync { try await keys.load(for: profile.id) } }
        else { #expect(try await keys.load(for: profile.id) == "old-synthetic-secret") }
    }

    @Test
    func keychainWriteFailureLeavesConfigurationAndPriorCredentialUntouched() async throws {
        let profile = ProviderProfile.fixture(alias: "account")
        let config = InMemoryConfigurationStore(.init(profiles: [profile]))
        let keys = ManagementCredentialSpy(failWrite: true)
        let manager = KeymanManager(configurationStore: config, credentialStore: keys)
        do {
            try await manager.setCredential(profile.alias, secret: "new-synthetic-secret")
            Issue.record("Expected Keychain failure")
        } catch KeymanError.keychainDenied {}
        #expect(await keys.writes == 1)
        #expect(await config.saveCount == 0)
        #expect(try await keys.load(for: profile.id) == "old-synthetic-secret")
    }

    @Test(arguments: [#"{"key":"must-not-enter-config"}"#, #"{"models":[]}"#, #"{"authentication":{"secret":"hidden"}}"#])
    func managementDocumentsRejectSecretAndInternalFields(json: String) {
        expectThrows { try ManagementDocuments.profile(Data(json.utf8)) }
    }

    @Test(arguments: ["http://external.example/api", "https://user:password@example.invalid", "https://example.invalid?key=bad"])
    func invalidEndpointIsRejectedBeforeAnyCredentialAccess(url: String) async throws {
        var profile = ProviderProfile.fixture(alias: "account")
        profile.endpoints[0].baseURL = URL(string: url)!
        let keys = ManagementCredentialSpy()
        let config = InMemoryConfigurationStore()
        await expectThrowsAsync { try await KeymanManager(configurationStore: config, credentialStore: keys).saveProfile(profile, secret: "synthetic-key") }
        #expect(await keys.operations == 0)
        #expect(await config.saveCount == 0)
    }

    @Test
    func headerReplacementAndNullClearWorkWithoutLeakingAuthentication() throws {
        var model = ModelRecord.seedreamFixture
        model.callTemplate?.staticHeaders = ["X-Old-Version": "1"]
        model.sourceFile = "source.md"
        let changed = try ManagementDocuments.model(Data(#"{"sourceFile":null,"callTemplate":{"staticHeaders":{"X-Version":"2"}}}"#.utf8), existing: model)
        #expect(changed.id == model.id)
        #expect(changed.sourceFile == nil)
        #expect(changed.callTemplate?.path == model.callTemplate?.path)
        #expect(changed.callTemplate?.staticHeaders == ["X-Version": "2"])
        var unsafe = changed; unsafe.callTemplate?.staticHeaders = ["Authorization": "synthetic-secret"]
        expectThrows { try ConfigurationValidator.validate(.init(profiles: [.fixture(alias: "account", models: [unsafe])])) }
        for path in ["//other.invalid", "/%2e%2e/escape", "/images?key=bad"] {
            unsafe = model; unsafe.callTemplate?.path = path
            expectThrows { try ConfigurationValidator.validate(.init(profiles: [.fixture(alias: "account", models: [unsafe])])) }
        }
    }
}

private actor ManagementCredentialSpy: CredentialStoring {
    private(set) var operations = 0
    private(set) var writes = 0
    let failWrite: Bool
    init(failWrite: Bool = false) { self.failWrite = failWrite }
    func load(for profileID: UUID) throws -> String { operations += 1; return "old-synthetic-secret" }
    func save(_ secret: String, for profileID: UUID) throws {
        operations += 1; writes += 1
        if failWrite { throw KeymanError.keychainDenied }
    }
    func delete(for profileID: UUID) { operations += 1 }
    func maskedSuffix(for profileID: UUID) throws -> String { String(try load(for: profileID).suffix(4)) }
}

private actor ManagementFailingStore: ConfigurationStoring {
    let original: KeymanConfiguration
    init(_ original: KeymanConfiguration) { self.original = original }
    func load() -> KeymanConfiguration { original }
    func save(_ configuration: KeymanConfiguration) throws { throw KeymanError.invalidRequest("Synthetic disk failure") }
}
