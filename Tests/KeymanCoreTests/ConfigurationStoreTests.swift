import Foundation
import Testing
@testable import KeymanCore

@Suite
struct ConfigurationStoreTests {
    @Test
    func saveCreatesMode0600FileAndRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = root.appendingPathComponent("config.json")
        let store = FileConfigurationStore(fileURL: file)
        let expected = KeymanConfiguration(
            profiles: [.fixture(alias: "example-ark", models: [.seedreamFixture])]
        )

        try await store.save(expected)
        let actual = try await store.load()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)

        #expect(actual == expected)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func saveRejectsInvalidConfigurationBeforeWriting() async {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("config.json")
        let store = FileConfigurationStore(fileURL: file)
        let duplicate = ProviderProfile.fixture(alias: "same")

        await expectThrowsAsync {
            try await store.save(.init(profiles: [duplicate, duplicate.withNewID()]))
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
