import Foundation
import Testing
@testable import KeymanCore
@testable import KeymanAppSupport

@MainActor
@Test
func outputPreferencePersistsWithoutOverwritingProfilesAddedElsewhere() async throws {
    let store = InMemoryConfigurationStore()
    let app = AppModel(configurationStore: store, credentialStore: InMemoryCredentialStore(), importer: LegacyImporter())
    let profile = try ProviderPresets.profile(kind: .volcengineArk, name: "Later", alias: "later", workspaceID: nil)
    try await store.save(.init(profiles: [profile]))
    try await app.setOutputPolicy(.providerDefault)
    #expect(try await store.load().profiles.count == 1)
    #expect(try await store.load().outputPolicy == .providerDefault)
    try await app.setOutputPolicy(.noVisibleWatermark)
    #expect(try await store.load().outputPolicy == .noVisibleWatermark)
}

@MainActor
@Test
func testSaveProfileWritesSecretToCredentialStoreAndNotConfiguration() async throws {
    let configurationStore = InMemoryConfigurationStore()
    let credentialStore = InMemoryCredentialStore()
    let model = AppModel(
        configurationStore: configurationStore,
        credentialStore: credentialStore,
        importer: LegacyImporter()
    )
    let profile = try ProviderPresets.profile(
        kind: .volcengineArk,
        name: "Example-Ark",
        alias: "example-ark",
        workspaceID: nil
    )

    try await model.saveProfile(profile, secret: "unit-test-credential")

    let saved = try await configurationStore.load()
    let encoded = try JSONEncoder().encode(saved)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("unit-test-credential"))
    #expect(try await credentialStore.load(for: profile.id) == "unit-test-credential")
}

@MainActor
@Test
func testDeleteProfileRemovesConfigAndCredential() async throws {
    let profile = try ProviderPresets.profile(
        kind: .volcengineArk,
        name: "Example-Ark",
        alias: "example-ark",
        workspaceID: nil
    )
    let configuration = InMemoryConfigurationStore(.init(profiles: [profile]))
    let credentials = InMemoryCredentialStore()
    await credentials.save("unit-test-credential", for: profile.id)
    let model = AppModel(
        configurationStore: configuration,
        credentialStore: credentials,
        importer: LegacyImporter()
    )
    try await model.reload()

    try await model.deleteProfile(profile.id)

    #expect(model.configuration.profiles.isEmpty)
    await expectThrowsAsync {
        _ = try await credentials.load(for: profile.id)
    }
}

@MainActor
@Test
func testModelTestRequiresExplicitConfirmation() async throws {
    let caller = RecordingModelCaller()
    let model = AppModel(
        configurationStore: InMemoryConfigurationStore(),
        credentialStore: InMemoryCredentialStore(),
        importer: LegacyImporter(),
        modelCaller: caller
    )
    let seedream = ModelRecord.seedreamFixture

    #expect(model.requiresBillingConfirmation(for: seedream))
    #expect(!model.canStartBillableTest)

    model.confirmBillableTest(modelID: seedream.id)
    #expect(model.canStartBillableTest)

    _ = try await model.testModel(
        profileAlias: "example-ark",
        model: seedream,
        body: Data(#"{"prompt":"Keyman connection test","size":"2K","watermark":true}"#.utf8)
    )
    let callCount = await caller.callCount
    #expect(callCount == 1)
}

@MainActor
@Test
func testModelTestThrowsWithoutConfirmationAndFiresNoBillableCall() async {
    let caller = RecordingModelCaller()
    let model = AppModel(
        configurationStore: InMemoryConfigurationStore(),
        credentialStore: InMemoryCredentialStore(),
        importer: LegacyImporter(),
        modelCaller: caller
    )
    let seedream = ModelRecord.seedreamFixture

    #expect(!model.canStartBillableTest)

    await expectThrowsAsync {
        _ = try await model.testModel(
            profileAlias: "example-ark",
            model: seedream,
            body: Data(#"{"prompt":"Keyman connection test","size":"2K","watermark":true}"#.utf8)
        )
    }
    let callCount = await caller.callCount
    #expect(callCount == 0)
}

@MainActor
@Test
func testSavingFromAnOlderViewPreservesProfilesAddedElsewhere() async throws {
    let store = InMemoryConfigurationStore()
    let model = AppModel(configurationStore: store, credentialStore: InMemoryCredentialStore(), importer: LegacyImporter())
    try await model.reload()
    let external = try ProviderPresets.profile(kind: .volcengineArk, name: "External", alias: "external", workspaceID: nil)
    try await store.save(.init(profiles: [external]))
    let added = try ProviderPresets.profile(kind: .volcengineArk, name: "New", alias: "new", workspaceID: nil)

    try await model.saveProfile(added, secret: "unit-test-new")

    #expect(try await store.load().profiles.map(\.alias) == ["external", "new"])
}

@MainActor
@Test
func testSuccessfulModelTestShowsResultAndConsumesConfirmation() async throws {
    let model = AppModel(
        configurationStore: InMemoryConfigurationStore(), credentialStore: InMemoryCredentialStore(),
        importer: LegacyImporter(), modelCaller: RecordingModelCaller()
    )
    let fixture = ModelRecord.seedreamFixture
    model.confirmBillableTest(modelID: fixture.id)
    _ = try await model.testModel(profileAlias: "example", model: fixture, body: Data("{}".utf8))

    #expect(model.modelTestResults[fixture.id]?.contains("200") == true)
    #expect(!model.canStartBillableTest)
    #expect(model.testingModelID == nil)
}
