import Foundation
import Testing
@testable import KeymanCore

@Suite
struct ConfigurationValidatorTests {
    @Test
    func rejectsDuplicateProfileAliases() {
        let profile = ProviderProfile.fixture(alias: "example-ark")
        let config = KeymanConfiguration(profiles: [profile, profile.withNewID()])

        do {
            try ConfigurationValidator.validate(config)
            Issue.record("Expected duplicateProfileAlias")
        } catch {
            #expect(error as? KeymanError == .duplicateProfileAlias("example-ark"))
        }
    }

    @Test
    func acceptsDeclaredModelWithoutCallDetailsForDisplay() throws {
        let model = ModelRecord.fixture(
            alias: "seedream-5-pro",
            modelID: nil,
            status: .declared,
            callTemplate: nil
        )
        let config = KeymanConfiguration(
            profiles: [.fixture(alias: "example-ark", models: [model])]
        )

        try ConfigurationValidator.validate(config)
    }

    @Test
    func acceptsDeclaredHTTPModelWithIDAndTemplate() throws {
        let config = KeymanConfiguration(
            profiles: [.fixture(alias: "example-ark", models: [.seedreamFixture])]
        )
        try ConfigurationValidator.validate(config)
    }
}
