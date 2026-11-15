import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanAppSupport

@MainActor @Test
func deniedKeychainIsLabelledSeparatelyAndDoesNotBlockMetadataManagement() async throws {
    let profile = try ProviderPresets.profile(kind: .volcengineArk, name: "Original", alias: "account", workspaceID: nil)
    let config = InMemoryConfigurationStore(.init(profiles: [profile]))
    let app = AppModel(configurationStore: config, credentialStore: DeniedManagementCredentials(), importer: LegacyImporter())
    await expectThrowsAsync { try await app.reload() }
    #expect(app.credentialLabel(profile.id) == "Key 待授权或读取失败")
    var edited = profile; edited.name = "Edited"
    try await app.saveProfile(edited, secret: nil, original: profile)
    #expect(app.configuration.profiles[0].name == "Edited")
    #expect(app.credentialLabel(profile.id) == "Key 待授权或读取失败")
    #expect(!app.isManaging)
}

@MainActor @Test
func oldModelTestSnapshotCannotCallAnEditedInterface() async throws {
    var profile = try ProviderPresets.profile(kind: .volcengineArk, name: "Account", alias: "account", workspaceID: nil)
    let record = ModelRecord.seedreamFixture
    profile.models = [record]
    let config = InMemoryConfigurationStore(.init(profiles: [profile]))
    let caller = RecordingModelCaller()
    let app = AppModel(configurationStore: config, credentialStore: InMemoryCredentialStore(), importer: LegacyImporter(), modelCaller: caller)
    var updated = profile; updated.endpoints[0].baseURL = URL(string: "https://changed.example.invalid")!
    try await config.save(.init(profiles: [updated]))
    app.confirmBillableTest(modelID: record.id)
    await expectThrowsAsync { try await app.testModel(profileAlias: profile.alias, model: record, body: Data("{}".utf8), expectedProfile: profile) }
    #expect(await caller.callCount == 0)
    #expect(!app.canStartBillableTest)
    #expect(app.testingModelID == nil)
}

@MainActor @Test
func deletingAChangedModelDoesNotRemoveTheNewRecord() async throws {
    var profile = try ProviderPresets.profile(kind: .volcengineArk, name: "Account", alias: "account", workspaceID: nil)
    let old = ModelRecord.seedreamFixture
    var changed = old; changed.name = "Changed elsewhere"
    profile.models = [changed]
    let config = InMemoryConfigurationStore(.init(profiles: [profile]))
    let app = AppModel(configurationStore: config, credentialStore: InMemoryCredentialStore(), importer: LegacyImporter())
    try await app.reload()
    await expectThrowsAsync { try await app.deleteModel(old, profileID: profile.id) }
    #expect(app.configuration.profiles[0].models == [changed])
    #expect(!app.isManaging)
}

private struct DeniedManagementCredentials: CredentialStoring {
    func load(for profileID: UUID) async throws -> String { throw KeymanError.keychainDenied }
    func save(_ secret: String, for profileID: UUID) async throws { throw KeymanError.keychainDenied }
    func delete(for profileID: UUID) async throws { throw KeymanError.keychainDenied }
    func maskedSuffix(for profileID: UUID) async throws -> String { throw KeymanError.keychainDenied }
}
