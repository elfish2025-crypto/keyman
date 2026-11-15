import Foundation
import Testing
@testable import KeymanCore

struct ModelGuideTests {
    @Test func catalogProvidesPurposeExampleAndHonestReadinessWithoutCredentials() throws {
        let original = KeymanConfiguration(profiles: [.fixture(alias: "images", models: [.seedreamFixture])])
        let updated = BuiltinModelGuides.addMissing(to: original)
        let entry = try #require(ModelCatalog.entries(updated, query: "分镜").first?.models.first)
        #expect(entry.requestReady)
        #expect(!entry.credentialRead && !entry.networkRequest && !entry.providerAccessVerified)
        #expect(entry.guide?.requestExample?["prompt"] != nil)
        #expect(entry.guide?.requestExample?["watermark"] == nil)
        #expect(ModelCatalog.entries(updated, query: "不相关用途").isEmpty)
        #expect(BuiltinModelGuides.addMissing(to: updated) == updated)
        #expect(original.profiles[0].models[0].usageGuide == nil)
    }

    @Test func incompleteFamilyNotesNeverInventCallableModels() throws {
        var speech = ModelRecord.fixture(alias: "qwen3-tts", modelID: nil, status: .candidate, callTemplate: nil)
        speech.modality = .speech
        var profile = ProviderProfile.bailianFixture; profile.models = [speech]
        let updated = BuiltinModelGuides.addMissing(to: .init(profiles: [profile]))
        let entry = try #require(ModelCatalog.entries(updated).first?.models.first)
        #expect(entry.guide?.summary.isEmpty == false)
        #expect(!entry.requestReady)
        #expect(entry.blockers.contains { $0.contains("Model ID") })
        #expect(entry.guide?.requestExample == nil)
        #expect(updated.profiles[0].models[0].status == .candidate)
    }

    @Test func unknownProviderCannotInheritASeedreamContractThroughItsName() {
        var profile = ProviderProfile.fixture(alias: "custom", models: [.seedreamFixture])
        profile.provider = .customREST
        #expect(BuiltinModelGuides.guide(profile: profile, model: profile.models[0]) == nil)
    }

    @Test func changedContractBlocksOldExampleUntilExplicitlyReconfirmed() async throws {
        let config = BuiltinModelGuides.addMissing(to: .init(profiles: [.fixture(alias: "p", models: [.seedreamFixture])]))
        let storage = InMemoryConfigurationStore(config)
        let manager = KeymanManager(configurationStore: storage, credentialStore: InMemoryCredentialStore())
        let original = config.profiles[0].models[0]
        var changed = original; changed.callTemplate?.path = "/new-images"
        _ = try await manager.saveModel(changed, profileAlias: "p", original: original)
        var profile = try await manager.profile("p")
        expectThrows { try ModelCatalog.example(profile: profile, model: profile.models[0]) }
        var described = profile.models[0]; described.usageGuide?.summary = "Updated description"
        _ = try await manager.saveModel(described, profileAlias: "p", original: profile.models[0])
        profile = try await manager.profile("p")
        expectThrows { try ModelCatalog.example(profile: profile, model: profile.models[0]) }
        _ = try await manager.saveModel(profile.models[0], profileAlias: "p", original: profile.models[0], confirmUsageExample: true)
        profile = try await manager.profile("p")
        #expect(try ModelCatalog.example(profile: profile, model: profile.models[0])["prompt"] != nil)
        // Watermark approval is separate and remains invalidated by the contract change.
        #expect(!ModelCatalog.packet(profile: profile, model: profile.models[0], policy: .noVisibleWatermark).requestReady)
    }

    @Test func guidePatchSupportsPartialEditsAndRejectsSecrets() throws {
        let data = Data(#"{"usageGuide":{"summary":"Generate images","requestExample":{"prompt":"cup","options":{"count":1}}}}"#.utf8)
        let model = try ManagementDocuments.model(data, existing: .seedreamFixture)
        #expect(model.usageGuide?.summary == "Generate images")
        #expect(model.usageGuide?.inputs == "")
        let replaced = try ManagementDocuments.model(Data(#"{"usageGuide":{"requestExample":{"prompt":"plate"}}}"#.utf8), existing: model)
        #expect(replaced.usageGuide?.requestExample?["options"] == nil)
        let secretExample = ModelUsageGuide(summary: "test", requestExample: ["nested": .object(["api_key": .string("synthetic")])])
        expectThrows { try ModelUsageGuide.validate(secretExample) }
        expectThrows { try JSONValue.object(from: Data("[]".utf8)) }
    }
}
