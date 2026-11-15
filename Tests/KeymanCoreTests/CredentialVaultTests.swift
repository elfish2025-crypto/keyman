import Foundation
import Testing
@testable import KeymanCore

struct CredentialVaultTests {
    @Test func aMissingVaultCannotResurrectBackupsForMigratedAccounts() async throws {
        var profile = ProviderProfile.fixture(alias: "migrated"); profile.usesCredentialVault = true
        let config = InMemoryConfigurationStore(.init(profiles: [profile]))
        let backend = VaultTestBackend()
        backend.values["\(KeychainCredentialStore.service)|\(profile.id.uuidString)"] = Data("outdated-synthetic-key".utf8)
        let store = KeychainCredentialStore(backend: backend, configurationStore: config)
        do { _ = try await store.load(for: profile.id); Issue.record("Must not revive backup") } catch KeymanError.keyMissing {}
        #expect(!backend.readServices.contains(KeychainCredentialStore.service))
    }
    @Test func oneItemUnlockCoversAllMigratedProfilesAndNeverReadsLegacy() async throws {
        let backend = VaultTestBackend()
        let store = KeychainCredentialStore(backend: backend)
        let ids = (0..<8).map { _ in UUID() }
        let migration = try await store.prepareMigration(profileIDs: ids, source: Dictionary(uniqueKeysWithValues: ids.map { ($0, "synthetic-\($0.uuidString)") }))
        try await store.commitMigration(migration)
        backend.resetReads()
        let status = try await store.vaultStatus(profileIDs: ids, interactive: true)
        #expect(status.profiles.filter { $0.state == .stored }.count == 8)
        #expect(backend.readServices == [KeychainCredentialStore.vaultService])
        backend.resetReads()
        for id in ids { #expect(try await store.load(for: id) == "synthetic-\(id.uuidString)") }
        #expect(!backend.readServices.contains(KeychainCredentialStore.service))
    }

    @Test func deletionClearsBackupAndNeverResurrectsAFormerKey() async throws {
        let backend = VaultTestBackend(); let id = UUID()
        backend.values["\(KeychainCredentialStore.service)|\(id.uuidString)"] = Data("old-synthetic-key".utf8)
        let store = KeychainCredentialStore(backend: backend)
        #expect(try await store.load(for: id) == "old-synthetic-key")
        try await store.save("new-synthetic-key", for: id)
        try await store.delete(for: id)
        #expect(backend.values["\(KeychainCredentialStore.service)|\(id.uuidString)"] == nil)
        // Simulate an old backup restored outside Keyman.
        backend.values["\(KeychainCredentialStore.service)|\(id.uuidString)"] = Data("old-synthetic-key".utf8)
        do { _ = try await store.load(for: id); Issue.record("Cleared accounts must not fall back") } catch KeymanError.keyMissing {}
        let migration = try await store.prepareMigration(profileIDs: [id], source: [id: "old-synthetic-key"])
        #expect(migration.migratedIDs.isEmpty)
    }

    @Test func corruptOrDeniedVaultNeverFallsBackToLegacy() async throws {
        let backend = VaultTestBackend(); let id = UUID()
        backend.values["\(KeychainCredentialStore.service)|\(id.uuidString)"] = Data("old-synthetic-key".utf8)
        backend.values["\(KeychainCredentialStore.vaultService)|\(KeychainCredentialStore.vaultAccount)"] = Data("malformed".utf8)
        let store = KeychainCredentialStore(backend: backend)
        await expectThrowsAsync { _ = try await store.load(for: id) }
        #expect(!backend.readServices.contains(KeychainCredentialStore.service))
        backend.denyVault = true
        do { _ = try await store.load(for: id); Issue.record("Denied vault must fail") } catch KeymanError.keychainDenied {}
        #expect(!backend.readServices.contains(KeychainCredentialStore.service))
    }

    @Test func changedSourceStopsBeforeWritingAndKeepsExistingVault() async throws {
        let backend = VaultTestBackend(); let id = UUID(); let store = KeychainCredentialStore(backend: backend)
        try await store.save("current-synthetic-key", for: id)
        let before = backend.values
        await expectThrowsAsync { _ = try await store.prepareMigration(profileIDs: [id], source: [id: "outdated-synthetic-key"]) }
        #expect(backend.values == before)
        #expect(try await store.load(for: id) == "current-synthetic-key")
    }

    @Test func migrationRollbackKeepsExistingVaultAndOriginalLegacyItems() async throws {
        let backend = VaultTestBackend(); let existing = UUID(); let moving = UUID()
        let store = KeychainCredentialStore(backend: backend)
        try await store.save("kept-synthetic-key", for: existing)
        backend.values["\(KeychainCredentialStore.service)|\(moving.uuidString)"] = Data("moving-synthetic-key".utf8)
        let before = backend.values
        let migration = try await store.prepareMigration(profileIDs: [moving], source: nil)
        try await store.commitMigration(migration)
        try await store.rollbackMigration(migration)
        #expect(backend.values.keys.sorted() == before.keys.sorted())
        let vaultKey = "\(KeychainCredentialStore.vaultService)|\(KeychainCredentialStore.vaultAccount)"
        #expect(try JSONSerialization.jsonObject(with: backend.values[vaultKey]!) as? NSDictionary == JSONSerialization.jsonObject(with: before[vaultKey]!) as? NSDictionary)
        #expect(try await store.load(for: moving) == "moving-synthetic-key")
    }

    @Test func sourceMigrationDryRunAndConfigurationFailureDoNotLeaveSecretsBehind() async throws {
        let profile = ProviderProfile.fixture(alias: "p")
        let backend = VaultTestBackend(); let store = KeychainCredentialStore(backend: backend)
        let config = VaultFailingConfiguration(.init(profiles: [profile]))
        let coordinator = CredentialVaultCoordinator(configurationStore: config, credentialStore: store)
        let source = ImportPreview(profiles: [.init(profile: profile, secret: "source-synthetic-key", secretSuffix: "-key")])
        let preview = try await coordinator.migrate(source: source, dryRun: true)
        #expect(!preview.keychainRead && preview.sourceCredentialsRead && backend.readServices.isEmpty && backend.values.isEmpty)
        await expectThrowsAsync { _ = try await coordinator.migrate(source: source) }
        #expect(backend.values.isEmpty)
        #expect(!backend.readServices.contains(KeychainCredentialStore.service))
    }

    @Test func separateClientsPreserveOtherAccountsWhenReplacingKeys() async throws {
        let backend = VaultTestBackend()
        let first = KeychainCredentialStore(backend: backend); let second = KeychainCredentialStore(backend: backend)
        let a = UUID(); let b = UUID()
        try await first.save("first-synthetic-key", for: a)
        try await second.save("second-synthetic-key", for: b)
        try await first.save("replacement-synthetic-key", for: a)
        #expect(try await second.load(for: a) == "replacement-synthetic-key")
        #expect(try await first.load(for: b) == "second-synthetic-key")
    }
}

private actor VaultFailingConfiguration: ConfigurationStoring {
    let value: KeymanConfiguration
    init(_ value: KeymanConfiguration) { self.value = value }
    func load() -> KeymanConfiguration { value }
    func save(_ configuration: KeymanConfiguration) throws { throw KeymanError.configurationChanged }
}

private final class VaultTestBackend: KeychainBackend, @unchecked Sendable {
    var values: [String: Data] = [:]
    var readServices: [String] = []
    var denyVault = false
    func resetReads() { readServices = [] }
    func write(service: String, account: String, data: Data) { values["\(service)|\(account)"] = data }
    func read(service: String, account: String) throws -> Data? {
        readServices.append(service)
        if denyVault && service == KeychainCredentialStore.vaultService { throw KeymanError.keychainDenied }
        return values["\(service)|\(account)"]
    }
    func delete(service: String, account: String) { values["\(service)|\(account)"] = nil }
}
