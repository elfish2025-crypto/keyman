import Foundation
import Testing
@testable import KeymanCore

@Suite
struct CredentialStoreTests {
    @Test
    func backgroundMaskReadCannotStartInteractiveAuthentication() async throws {
        let backend = NoninteractiveTestBackend()
        let store = KeychainCredentialStore(backend: backend)
        do {
            _ = try await store.maskedSuffix(for: UUID())
            Issue.record("An unauthorized background read must fail without an authorization dialog")
        } catch KeymanError.keychainDenied {}
        let profile = ProviderProfile.fixture(alias: "account")
        let manager = KeymanManager(configurationStore: InMemoryConfigurationStore(.init(profiles: [profile])), credentialStore: store)
        do {
            _ = try await manager.credentialStatus(profile.alias)
            Issue.record("Agent status queries must not start interactive authentication either")
        } catch KeymanError.keychainDenied {}
        #expect(try await store.load(for: UUID()) == "synthetic-authorized-secret")
    }
    @Test
    func credentialStoreUsesOneVaultAndRetainsProfileIdentityInsideIt() async throws {
        let backend = RecordingKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let profileID = UUID()

        try await store.save("unit-test-credential", for: profileID)
        let loaded = try await store.load(for: profileID)

        #expect(loaded == "unit-test-credential")
        #expect(backend.lastAccount == KeychainCredentialStore.vaultAccount)
        #expect(backend.lastService == KeychainCredentialStore.vaultService)
        let listing = try await store.vaultStatus(profileIDs: [profileID])
        #expect(listing.profiles.first?.profileID == profileID)
        #expect(!String(decoding: try JSONEncoder().encode(listing), as: UTF8.self).contains("unit-test-credential"))
    }

    @Test
    func missingCredentialMapsToKeyMissing() async {
        let store = KeychainCredentialStore(backend: RecordingKeychainBackend())
        await expectThrowsAsync {
            _ = try await store.load(for: UUID())
        }
    }
}

private struct NoninteractiveTestBackend: KeychainBackend {
    func write(service: String, account: String, data: Data) {}
    func read(service: String, account: String) -> Data? {
        service == KeychainCredentialStore.vaultService ? nil : Data("synthetic-authorized-secret".utf8)
    }
    func readWithoutInteraction(service: String, account: String) throws -> Data? { throw KeymanError.keychainDenied }
    func delete(service: String, account: String) {}
}
